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
    private var guidance: ScrollGuidance?
    private var screen: NSScreen?
    /// 影格消化引擎。**只在 engineQueue 上被觸碰**——匹配鏈很重（debug build 單格可達 1.7 秒），
    /// 放主執行緒會把計時器／HUD／事件監聽全部餓死（實測：長圖完全不增長）。
    private var engine: ScrollStitchEngine?
    private let engineQueue = DispatchQueue(label: "anypaint.scroll.engine", qos: .userInitiated)
    private var engineBusy = false
    /// 背壓：engine 忙碌時只保留「最新」一格。丟掉中間格無害——匹配基準是固定的長圖尾端，
    /// 位移會累積到下一次匹配一併接上。
    private var pendingFrame: PixelBuffer?
    private var eventMonitors: [Any] = []        // 滾輪（local+global）＋ mouseMoved（global）監聽
    private var wheelAccumulator: CGFloat = 0    // 自上次接受後的滾輪累計（px 級 delta）
    private var recentWheelDirection = 0         // +1 下捲 / -1 上捲 / 0 無（bounce 豁免的閘門）
    private var bottomWatch: Timer?              // 到底判定的週期檢查
    private var wheelTicksSinceCheck = 0         // 兩次檢查之間收到的滾輪事件數
    private var watchdog: DispatchWorkItem?
    private var lastWatchdogResetUptimeNs: UInt64 = 0
    private var bottomProbeCount = 0

    // MARK: 進入/取消

    public func begin() {
        guard state == .idle, let screen = NSScreen.main else { return }
        self.screen = screen
        state = .selecting
        overlay.onSelectionLocked = { [weak self] sel, scr in self?.enterArmed(sel, scr) }
        // 調框時重新判定：選區太小被擋住後，拉大就能進 armed（否則是只能取消重來的死路）。
        // enterArmed 對「已 armed」是冪等的（只更新 HUD 位置，不重裝 monitor）。
        overlay.onSelectionChanged = { [weak self] sel in
            guard let self, let scr = self.screen else { return }
            self.enterArmed(sel, scr)
        }
        overlay.onCancelRequested = { [weak self] in self?.cancel() }
        overlay.present(on: screen)
        installEscMonitor()                                        // 逃生：local keyDown 攔 Esc（見方法註解）
        armWatchdog(seconds: AppSettings.overlayWatchdogSeconds)   // selecting/armed 沿用既有語意
        installGlobalMouseMovedWatchdogReset()                     // spec §9.3：滑鼠移動也算互動
    }

    /// 逃生路：local keyDown monitor 攔 Esc。不能只靠 ScrollSelectionView.keyDown——
    /// nonactivating panel「被點擊前收不到 responder 事件」（範本 SelectionOverlayController:100-102
    /// 的實測結論），view.keyDown 不可靠。local monitor 不依賴 responder chain、不需 AX 權限
    /// （與 global 不同），但需 app 為前景（present 的 NSApp.activate 已保證）。
    /// capturing 後使用者點過選區（穿透）→ app 失去前景 → local 收不到，此時取消靠 HUD／⌘⇧X／
    /// 看門狗（spec §6：Esc 於 capturing 是 bonus）。
    private func installEscMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.state == .selecting || self.state == .armed {
                self.cancel()
                return nil   // 吞掉，不再往下派發
            }
            return event
        }
        if let monitor { eventMonitors.append(monitor) }
    }

    public func cancelIfActive() { if isActive { cancel() } }

    private func enterArmed(_ selection: CGRect, _ scr: NSScreen) {
        // 兩個分支都要先掛好取消：太小選區的死路訊息也要有一顆按得下去的「取消」按鈕，
        // 不能只靠 Esc／看門狗（免按鍵保證退出＋多條取消路徑，逃生路徑守則）。
        hud.onCancel = { [weak self] in self?.cancel() }
        // spec §3 的最小選區高是 **320 像素**（matcher 的 probe/重疊幾何全以像素計）——
        // selection 是點座標，Retina 上 1pt=2px，直接拿點比 320 會把門檻抬成 640px、
        // 比設計嚴格一倍（實測：600px 的合格選區被誤擋）。一律換算成像素再比。
        let scale = scr.backingScaleFactor      // 同一顆螢幕上等同擷取端的 pointPixelScale
        let pixelHeight = Int((selection.height * scale).rounded())
        guard pixelHeight >= 320 else {
            hud.show(near: selection, on: scr, mode: .armed)
            hud.update(message: .selectionTooSmall)   // 明確告知原因（原本誤用 .hardToMatch 語意不符）
            return
        }
        // 已 armed（使用者在調框）→ 只跟著更新 HUD 位置，不可重跑進場流程（會重複裝滾輪 monitor）。
        guard state != .armed else {
            hud.show(near: selection, on: scr, mode: .armed)
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
            self.wheelTicksSinceCheck += 1
            self.resetWatchdogFromInteraction()
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
        engine = ScrollStitchEngine(maxHeightPx: AppSettings.scrollMaxHeightPx)
        startBottomWatch()
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

    // MARK: 影格消化（委派 engine，跑在背景佇列）

    private func consume(frame full: PixelBuffer) {
        guard state == .capturing else { return }   // T10：stop 後在途 sample 仍可能派發，guard 掉
        pendingFrame = full                          // 背壓：永遠只留最新一格
        pumpEngine()
    }

    private func pumpEngine() {
        guard state == .capturing, !engineBusy,
              let frame = pendingFrame, let engine else { return }
        pendingFrame = nil
        engineBusy = true
        let accumulated = wheelAccumulator
        let direction = recentWheelDirection
        engineQueue.async { [weak self] in
            let outcome = engine.consume(frame: frame,
                                         wheelAccumulatedPoints: accumulated,
                                         wheelDirection: direction)
            let height = engine.height
            let failures = engine.consecutiveFailures
            Task { @MainActor in
                guard let self else { return }
                self.engineBusy = false
                self.handle(outcome: outcome, height: height, failures: failures)
                self.pumpEngine()                    // 消化下一格（若期間又收到）
            }
        }
    }

    private func handle(outcome: ScrollStitchOutcome, height: Int, failures: Int) {
        guard state == .capturing else { return }
        switch outcome {
        case .baseCaptured, .waitingForMotion, .awaitingBandLock, .noMotion:
            break                                     // 皆非失敗，不需提示
        case .bandsLocked:
            wheelAccumulator = 0
        case let .appended(dy, total):
            wheelAccumulator = 0
            if var guidance {
                hud.update(message: guidance.frameAccepted(dy: dy, totalPx: total))
                self.guidance = guidance
            }
        case .trimmed:
            wheelAccumulator = 0
            if var guidance {
                hud.update(message: guidance.frameDroppedBackscroll())
                self.guidance = guidance
            }
        case .atOrigin:
            wheelAccumulator = 0
            if var guidance {
                hud.update(message: guidance.backscrollAtOrigin())
                self.guidance = guidance
            }
        case .rejected:
            if var guidance {
                if let m = guidance.frameDropped() { hud.update(message: m) }
                if let m = guidance.wheelAccumulated(sinceLastAccept: Int(wheelAccumulator)) {
                    hud.update(message: m)
                }
                self.guidance = guidance
            }
            if failures >= 10 { finish() }            // spec §3
        case .limitReached:
            finish()
        }
        _ = height
    }

    // MARK: 到底判定（自我重排的週期檢查，spec §5.3）

    /// 「使用者還在捲，但畫面已經不動」＝到底。畫面靜止時 SCStream 不供格，所以訊號是
    /// 「這段期間有滾輪事件、卻沒有新 .complete 影格」。必須用**週期性**計時器自我重排：
    /// 原本的一次性計時器由滾輪事件重排，使用者到底後停手就再也不會重排，永遠累積不到門檻。
    private func startBottomWatch() {
        bottomWatch?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.bottomTick() }
        }
        RunLoop.main.add(t, forMode: .common)   // tracking loop（拖捲軸）期間也要跳
        bottomWatch = t
    }

    private func bottomTick() {
        guard state == .capturing else { return }
        let framesStalled = ProcessInfo.processInfo.systemUptime - frameSource.lastFrameAt > 1.0
        defer { wheelTicksSinceCheck = 0 }
        guard wheelTicksSinceCheck > 0, framesStalled else {
            if !framesStalled { bottomProbeCount = 0 }   // 影格還在流＝沒到底
            return
        }
        bottomProbeCount += 1
        if var guidance {
            hud.update(message: guidance.bottomProbing())
            self.guidance = guidance
        } else {
            hud.update(message: .bottomProbing)
        }
        if bottomProbeCount >= 3 { finish() }            // 約 1.5 秒「捲了但畫面不動」
    }

    // MARK: 收尾／取消／看門狗

    public func requestDone() { if state == .capturing { finish() } }

    private func finish() {
        guard state == .capturing || state == .armed else { return }
        state = .finishing
        let image: CGImage?
        if let engine, engine.appendedFrameCount >= 1 { image = engine.finalize() } else { image = nil }
        teardown()
        onFinished?(image)   // 呼叫端（AppDelegate）決定 0/1 格降級與 preview（spec §3）
    }

    private func cancel() {
        guard state != .idle else { return }   // 冪等：teardown 已把 state 設回 idle，擋二次 onFinished（防未來新增呼叫源回歸）
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
        bottomWatch?.invalidate(); bottomWatch = nil
        watchdog?.cancel(); watchdog = nil
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()
        Task { await frameSource.stop() }
        overlay.dismiss()
        hud.dismiss()
        engine = nil; guidance = nil
        pendingFrame = nil; engineBusy = false
        wheelAccumulator = 0; recentWheelDirection = 0
        bottomProbeCount = 0; wheelTicksSinceCheck = 0
        state = .idle
    }
}
