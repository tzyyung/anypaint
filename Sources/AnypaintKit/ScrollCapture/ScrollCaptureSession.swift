import AppKit
import Vision

/// 滾動截圖協調者（spec §3 狀態機）。組裝 overlay/HUD/frameSource/matcher/stitcher/guidance，
/// 自己不做演算法，只管「誰在什麼時候呼叫誰」＋逃生路徑。
///
/// API 查證（研究後結論，動手前定案，配合全域規則第 4 條）：
/// - NSEvent local+global monitor（滾輪）：global monitor 收不到送給本行程視窗的事件（Apple
///   「Monitoring Events」文件明載＋開發者社群多筆已知案例），這正是雙掛的理由——游標在 HUD／
///   選區 overlay 上滾動只有 local 收得到，游標在底下活畫面上滾動只有 global 收得到，缺一必漏。
///   keyDown 不用 global monitor：全域鍵盤事件監聽需要輔助使用權限（Accessibility/AX），Esc
///   取消已由 overlay 的 SelectionView 本地 keyDown 處理，不需要也不該多要這個權限。
/// - Timer.scheduledTimer(withTimeInterval:repeats:)：預設把 timer 掛在呼叫執行緒目前 RunLoop 的
///   `.default` mode，已知在 modal/tracking loop 期間（例如使用者在被截圖的視窗裡拖曳捲軸）不會
///   觸發（Apple Developer Forums「NSTimer not firing in modal panel」等多筆案例）。到底判定計時器
///   在 capturing 全程都需要準時觸發，因此改用 `Timer(timeInterval:repeats:block:)` 顯式
///   `RunLoop.main.add(timer, forMode: .common)`，涵蓋 tracking loop。
/// - Task { @MainActor in ... }：本類別整體 @MainActor 隔離，await 期間（如 frameSource.start()
///   內的 SCShareableContent 非同步抓取）其他 MainActor 工作（如使用者按 Esc 觸發 cancel()）仍可能
///   插入執行——啟動流程對此顯式做了「啟動後若已非 capturing 就補收尾」的處理（見 startCapturing）。
@MainActor
public final class ScrollCaptureSession {
    public enum State { case idle, selecting, armed, capturing, finishing }
    public private(set) var state: State = .idle
    public var isActive: Bool { state != .idle }
    public var onFinished: ((CGImage?) -> Void)?

    private let overlay = ScrollSelectionOverlayController()
    private let hud = ScrollHUDController()
    private let frameSource = ScrollFrameSource()
    private var stitcher: ScrollStitcher?
    private var guidance: ScrollGuidance?
    private var insets: BandInsets?             // nil = 未鎖定
    private var screen: NSScreen?
    private var lastAcceptedFullFrame: PixelBuffer?   // 鎖帶前的 detect 素材／鎖帶後的上一格全幅
    private var priorDy: Int?
    private var eventMonitors: [Any] = []        // 滾輪（local+global）＋ mouseMoved（global）監聽
    private var wheelAccumulator: CGFloat = 0    // 自上次接受後的滾輪累計（px 級 delta）
    private var recentWheelDirection = 0         // +1 下捲 / -1 上捲 / 0 無（bounce 豁免的閘門）
    private var wheelIdleTimer: Timer?           // 到底判定：滾輪持續但 1.5s 無新格
    private var watchdog: DispatchWorkItem?
    private var lastWatchdogResetUptimeNs: UInt64 = 0
    private var consecutiveFailures = 0          // 三層匹配鏈連續失敗（≥10 → 收工，spec §3）
    private var bottomProbeCount = 0
    private var lockAttempts = 0                 // 鎖帶前累積的「已接受但未能鎖定」格數（T7 遞延重試）

    // MARK: 進入/取消

    public func begin() {
        guard state == .idle, let screen = NSScreen.main else { return }
        self.screen = screen
        state = .selecting
        overlay.onSelectionLocked = { [weak self] sel, scr in self?.enterArmed(sel, scr) }
        overlay.onCancelRequested = { [weak self] in self?.cancel() }
        overlay.present(on: screen)
        armWatchdog(seconds: AppSettings.overlayWatchdogSeconds)   // selecting/armed 沿用既有語意
        installGlobalMouseMovedWatchdogReset()                     // spec §9.3：滑鼠移動也算互動
    }

    public func cancelIfActive() { if isActive { cancel() } }

    private func enterArmed(_ selection: CGRect, _ scr: NSScreen) {
        // 兩個分支都要先掛好取消：太小選區的死路訊息也要有一顆按得下去的「取消」按鈕，
        // 不能只靠 Esc／看門狗（免按鍵保證退出＋多條取消路徑，逃生路徑守則）。
        hud.onCancel = { [weak self] in self?.cancel() }
        guard selection.height >= 320 else {    // spec §3 最小選區高
            hud.show(near: selection, on: scr, mode: .armed)
            hud.update(message: .hardToMatch)   // 文案沿用（未新增專屬訊息，記錄於報告）
            return
        }
        state = .armed
        hud.onStart = { [weak self] in self?.startCapturing() }
        hud.show(near: selection, on: scr, mode: .armed)
        installWheelMonitors()                  // armed 就裝：選區內第一個滾輪事件＝啟動（spec §5.2）
    }

    // MARK: 滾輪監聽（local+global 雙掛，spec §5.1）

    private func installWheelMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            let inSelection = self.overlay.selectionGlobal.contains(NSEvent.mouseLocation)
            if self.state == .armed, inSelection { self.startCapturing() }
            guard self.state == .capturing else { return }
            guard inSelection else {
                if var guidance = self.guidance {
                    self.hud.update(message: guidance.mouseLeftSelection())
                    self.guidance = guidance
                }
                return
            }
            self.wheelAccumulator += abs(e.scrollingDeltaY)
            if e.scrollingDeltaY != 0 { self.recentWheelDirection = e.scrollingDeltaY < 0 ? 1 : -1 }
            // AppKit 慣例：deltaY < 0 = 內容上移 = 頁面下捲（自然捲動）。實跑驗證後如相反，翻轉此行並註記。
            self.resetWatchdogFromInteraction()
            self.scheduleBottomProbe()
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { e in handler(e); return e }) {
            eventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) {
            eventMonitors.append(global)
        }
        // global 收不到自家事件（游標在 HUD／選區 overlay 上滾動走 local）——雙掛缺一必漏（spec §5.1）
    }

    /// spec §9.3：滑鼠移動也算互動，重置獨立看門狗（selecting/armed 用框選看門狗、capturing 用滾動看門狗）。
    private func installGlobalMouseMovedWatchdogReset() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isActive else { return }
            self.resetWatchdogFromInteraction()
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            eventMonitors.append(g)
        }
    }

    private func startCapturing() {
        guard state == .armed, let screen else { return }
        state = .capturing
        overlay.enterCapturing()
        NSCursor.arrow.set()   // T11 契約：enterCapturing 後補消 crosshair 殘留（overlay 本身不做）
        hud.show(near: overlay.selectionGlobal, on: screen, mode: .capturing)
        hud.onDone = { [weak self] in self?.finish() }
        guidance = ScrollGuidance(selectionHeight: Int(overlay.selectionGlobal.height))
        frameSource.onFrame = { [weak self] pb in self?.consume(frame: pb) }
        frameSource.onStreamError = { [weak self] _ in self?.finish() }   // stream 死亡 → 保留已拼（spec §3）
        let selectionGlobal = overlay.selectionGlobal
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.frameSource.start(selectionGlobal: selectionGlobal, screen: screen)
            } catch {
                if self.state == .capturing { self.streamStartFailed(error) }
                return
            }
            // 啟動期間（await 懸掛時）state 可能已被取消／收工（cancel()/finish() 已 teardown）——
            // 立刻停掉這條剛啟動的 stream，避免遺留一條活的 SCStream 沒人 stop。
            if self.state != .capturing {
                await self.frameSource.stop()
            }
        }
        armWatchdog(seconds: AppSettings.scrollWatchdogSeconds)
    }

    // MARK: 影格消化（spec §2 單格資料流）

    private func consume(frame full: PixelBuffer) {
        guard state == .capturing else { return }   // T10：stop 後在途 sample 仍可能派發，guard 掉
        bottomProbeCount = 0                        // 新 .complete 影格重置到底計數（spec §10）
        guard let stitcher else {                    // 第 1 張 = base
            stitcher = ScrollStitcher(firstFrame: full, maxHeightPx: AppSettings.scrollMaxHeightPx)
            lastAcceptedFullFrame = full
            return
        }
        let contentFrame: PixelBuffer
        if let insets {
            contentFrame = full.cropped(x: insets.left, y: insets.top,
                                        width: full.width - insets.left - insets.right,
                                        height: full.height - insets.top - insets.bottom)
        } else { contentFrame = full }
        let reference = stitcher.referenceTail(maxHeight: contentFrame.height)
        guard reference.height == contentFrame.height else { return }   // 起步未滿一屏的邊界，等下一格
        let outcome = ScrollMatcher.match(new: LumaPlane(contentFrame), reference: LumaPlane(reference),
                                          wheelDirection: recentWheelDirection, prior: priorDy)
        switch outcome {
        case let .accepted(dy, _) where dy > 0:
            handleAccepted(dy: dy, full: full, contentFrame: contentFrame)
        case let .accepted(dy, _) where dy < 0:
            // 回捲仍是 matcher 的「成功接受格」——重置連續失敗（回捲格不計失敗，guidance 同語意）。
            consecutiveFailures = 0
            let trimmed = stitcher.cropTail(-dy)     // 回捲裁尾（spec D6）
            if var guidance {
                hud.update(message: trimmed > 0 ? guidance.frameDroppedBackscroll()
                                                : guidance.backscrollAtOrigin())
                self.guidance = guidance
            }
            priorDy = nil
        case .accepted:                              // dy == 0：同樣是成功匹配，重置連續失敗
            consecutiveFailures = 0
        case .ambiguous, .lowConfidence, .noOverlap:
            handleRejected(contentFrame: contentFrame, reference: reference, full: full)
        }
    }

    private func handleAccepted(dy: Int, full: PixelBuffer, contentFrame: PixelBuffer) {
        guard let stitcher else { return }
        // 任一成功接受格重置「連續失敗」（含 Vision/PC 救援層走到這裡的情況；spec §10 計數器語意）。
        consecutiveFailures = 0

        guard insets != nil else {
            // 未鎖帶：T7 契約——鎖定必須在任何 append 之前。本格只當偵測素材／鎖定嘗試，絕不 append。
            attemptLockOrDeferredRetry(dy: dy, full: full)
            return
        }

        guard stitcher.append(contentFrame: contentFrame, dy: dy) else { finish(); return }  // 高度上限
        priorDy = dy
        wheelAccumulator = 0
        lastAcceptedFullFrame = full
        if var guidance {
            hud.update(message: guidance.frameAccepted(dy: dy, totalPx: stitcher.height))
            self.guidance = guidance
        }
    }

    /// 未鎖帶前的每一格：拿本格與上一張全幅做四向偵測嘗試鎖定（spec §7.2）。
    /// lockBands 契約（T7）可能拒絕（先拼後鎖／退化底帶／寬度不符）——遞延到下一格重試；
    /// 累積 5 次仍未能鎖定（含 detect 本身沒找到帶）→ fallback 用 zero insets 強制鎖定，
    /// 避免永遠鎖不上卡死（記一筆 log）。
    private func attemptLockOrDeferredRetry(dy: Int, full: PixelBuffer) {
        defer { lastAcceptedFullFrame = full }
        guard let stitcher else { return }
        guard let prev = lastAcceptedFullFrame,
              let detected = StaticBandDetector.detect(frameA: LumaPlane(full), frameB: LumaPlane(prev), dy: dy),
              stitcher.lockBands(detected, bottomBandFrom: full)
        else {
            lockAttempts += 1
            if lockAttempts >= 5 {
                let attempts = lockAttempts
                if stitcher.lockBands(.zero, bottomBandFrom: full) {
                    insets = .zero
                    lockAttempts = 0
                    NSLog("anypaint: 滾動截圖靜態帶連續 %d 次鎖定失敗，改用 zero insets 強制鎖定", attempts)
                }
            }
            return
        }
        insets = detected
        lockAttempts = 0
    }

    private func handleRejected(contentFrame: PixelBuffer, reference: PixelBuffer, full: PixelBuffer) {
        // 第二層：Vision 對帳／引導（spec §7.4）——Vision 全圖估計；同意閾值 max(18, dy/3)
        if let visionDy = visionEstimate(new: contentFrame, reference: reference),
           visionDy > 0, recentWheelDirection >= 0 {
            // Vision 引導重搜：以 visionDy 為 prior 再跑一次 matcher
            if case let .accepted(dy, _) = ScrollMatcher.match(
                new: LumaPlane(contentFrame), reference: LumaPlane(reference),
                wheelDirection: 1, prior: visionDy), abs(dy - visionDy) <= max(18, visionDy / 3) {
                handleAccepted(dy: dy, full: full, contentFrame: contentFrame); return
            }
        }
        // 第三層：1-D 相位相關救援（spec §7.4）。PC 本身不套 minDelta 閘（會回 3px 級微捲雜訊），
        // Session 端自套與 matcher 相同的 minDelta 閾值（T6 交付契約）。
        if let (dy, _) = PhaseCorrelation1D.estimateShift(new: LumaPlane(contentFrame),
                                                          reference: LumaPlane(reference)),
           dy >= ScrollMatcher.Config.default.minDelta, recentWheelDirection >= 0 {
            handleAccepted(dy: dy, full: full, contentFrame: contentFrame); return
        }
        // TODO(spec §7.5 dead-reckoning)：三層全敗時，若 wheelAccumulator > 0 可用其當 dy 走
        // handleAccepted 並發 .deadReckoning 提示——v1 不自動啟用（滾輪 delta→px 換算因 app 而異，
        // spec §13 已列為已接受風險）。待量測到可靠換算係數後的版本再開，此處故意不留死碼。
        consecutiveFailures += 1
        if var guidance {
            if let m = guidance.frameDropped() { hud.update(message: m) }
            if let m = guidance.wheelAccumulated(sinceLastAccept: Int(wheelAccumulator)) { hud.update(message: m) }
            self.guidance = guidance
        }
        if consecutiveFailures >= 10 { finish() }    // spec §3
    }

    /// Vision 全圖位移估計。ty 單位／正負號依 Task 2 實測結論（visionTyIsInPixels，
    /// ScrollCaptureTests.visionTyUnitTest 鎖死）：targeted=new、handler=reference 時，
    /// 頁面向下捲 ty 為負；換算成本 session「正值＝下捲」的慣例＝ -ty（不可用 abs，否則上捲
    /// 誤判也會回正值）。
    private func visionEstimate(new: PixelBuffer, reference: PixelBuffer) -> Int? {
        guard new.height > 80, let cgNew = new.makeCGImage(), let cgRef = reference.makeCGImage() else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: cgNew)
        let handler = VNImageRequestHandler(cgImage: cgRef, options: [:])
        try? handler.perform([request])
        guard let ty = (request.results?.first)?.alignmentTransform.ty else { return nil }
        return Int((-ty).rounded())   // scrollDownPixels = -ty（Task 2 結論；勿用 abs）
    }

    // MARK: 到底判定（計時器驅動，spec §5.3）

    private func scheduleBottomProbe() {
        wheelIdleTimer?.invalidate()
        // Timer(timeInterval:repeats:block:) + RunLoop.common（非 .scheduledTimer 的 .default
        // mode）：到底判定在使用者於目標視窗內拖曳捲軸等 tracking loop 期間也必須準時觸發
        // （API 查證：scheduledTimer 預設掛在 .default mode，tracking/modal loop 期間已知不觸發）。
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .capturing else { return }
                // 1.5s 內滾輪有動但沒有任何新 .complete 影格 → 到底候選
                if ProcessInfo.processInfo.systemUptime - self.frameSource.lastFrameAt >= 1.4 {
                    self.bottomProbeCount += 1
                    if var guidance = self.guidance {
                        self.hud.update(message: guidance.bottomProbing())
                        self.guidance = guidance
                    } else {
                        self.hud.update(message: .bottomProbing)
                    }
                    if self.bottomProbeCount >= 2 { self.finish() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wheelIdleTimer = timer
    }

    // MARK: 收尾／取消／看門狗

    public func requestDone() { if state == .capturing { finish() } }

    private func finish() {
        guard state == .capturing || state == .armed else { return }
        state = .finishing
        let image: CGImage?
        if let stitcher, stitcher.appendedFrameCount >= 1 { image = stitcher.finalize() } else { image = nil }
        teardown()
        onFinished?(image)   // 呼叫端（AppDelegate）決定 0/1 格降級與 preview（spec §3）
    }

    private func cancel() {
        teardown()
        onFinished?(nil)
    }

    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        guard seconds > 0 else { watchdog = nil; return }   // 0=關閉：上限＋連續失敗保底（spec §9.3）
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // capturing 逾時 = 搶救收工（保留已拼）；selecting/armed 逾時 = 取消（spec §9.3）
            if self.state == .capturing { self.finish() } else { self.cancel() }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 高頻互動（滾輪／滑鼠移動）觸發的看門狗重置：0.5s 節流，避免每個事件都重排一個新
    /// DispatchWorkItem（比照 SelectionOverlayController.armWatchdog 的防抖同一顧慮）。
    /// 狀態機轉場（begin/startCapturing）一律走 armWatchdog(seconds:) 直接重排，不節流。
    private func resetWatchdogFromInteraction() {
        guard isActive else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if watchdog != nil, now &- lastWatchdogResetUptimeNs < 500_000_000 { return }
        lastWatchdogResetUptimeNs = now
        armWatchdog(seconds: state == .capturing ? AppSettings.scrollWatchdogSeconds : AppSettings.overlayWatchdogSeconds)
    }

    private func streamStartFailed(_ error: Error) {
        teardown()
        onFinished?(nil)
        // 權限被撤等情況——提示交給 AppDelegate 的既有 showPermissionAlert 流程
        NSLog("anypaint: 滾動截圖 stream 啟動失敗 %@", String(describing: error))
    }

    private func teardown() {
        wheelIdleTimer?.invalidate(); wheelIdleTimer = nil
        watchdog?.cancel(); watchdog = nil
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()
        Task { await frameSource.stop() }
        overlay.dismiss()
        hud.dismiss()
        stitcher = nil; guidance = nil; insets = nil
        lastAcceptedFullFrame = nil; priorDy = nil
        wheelAccumulator = 0; recentWheelDirection = 0
        consecutiveFailures = 0; bottomProbeCount = 0
        lockAttempts = 0
        state = .idle
    }
}
