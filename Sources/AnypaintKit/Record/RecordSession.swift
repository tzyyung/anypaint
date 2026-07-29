import AppKit

/// 動畫截圖協調者（設計文件 §2 狀態機）。組裝 overlay/HUD/frameSource/clickRing，
/// 自己不做編碼，只管「誰在什麼時候呼叫誰」＋逃生路徑。整體對照 `ScrollCaptureSession`
/// （同為 @MainActor 狀態機；進場/Esc monitor/看門狗/teardown 冪等），但簡單得多——
/// 沒有 engine/matcher/滾輪，收檔交給 `RecordFrameSource`／`WriterBox` 自己序列化。
@MainActor
public final class RecordSession {
    public enum State { case idle, selecting, armed, recording, finishing }
    public private(set) var state: State = .idle
    public var isActive: Bool { state != .idle }
    /// 收尾回呼。母帶 URL；nil＝取消或失敗。第二參數＝擷取螢幕 backingScaleFactor
    /// （語意同 `ScrollCaptureSession.onFinished`：呼叫端換算預覽/裁切要用它，不能自己問
    /// `NSScreen.main`——混合 DPI 多螢幕下會用錯 scale）。
    public var onFinished: ((URL?, CGFloat) -> Void)?

    /// 不限時錄製的看門狗上限：10 分鐘自動走正常停止（防忘記停吃磁碟，設計文件 §2）。
    static let maxRecordingSeconds: Double = 600
    /// 最小選區邊長（**點**——CLAUDE.md 單位教訓；錄製無匹配需求，64pt 足夠）。
    static let minSelectionEdgePt: CGFloat = 64

    private let overlay = ScrollSelectionOverlayController()   // 選區框選直接重用（公開、無滾動耦合）
    private let hud = RecordHUDController()
    private let frameSource = RecordFrameSource()
    private let clickRing = ClickRingOverlay()
    private let output: RecordOutputService
    private var screen: NSScreen?
    private var eventMonitors: [Any] = []
    private var clock: Timer?
    private var recordingStartedAt: TimeInterval = 0   // wall-clock（systemUptime）；時鐘不可用影格 PTS
    private var durationLimit: Double?
    private var watchdog: DispatchWorkItem?

    public init(output: RecordOutputService) { self.output = output }

    // MARK: 進入/取消

    public func begin() {
        guard state == .idle, let screen = ScrollCaptureSession.screenUnderMouse() else { return }
        self.screen = screen
        state = .selecting
        overlay.onSelectionLocked = { [weak self] sel, scr in self?.enterArmed(sel, scr) }
        // 調框時重新判定：選區太小被擋住後，拉大就能進 armed（enterArmed 對「已 armed」冪等，
        // 只更新 HUD 位置，同 ScrollCaptureSession 的理由）。
        overlay.onSelectionChanged = { [weak self] sel in
            guard let self, let scr = self.screen else { return }
            self.enterArmed(sel, scr)
        }
        overlay.onCancelRequested = { [weak self] in self?.cancel() }
        overlay.present(on: screen)
        installEscMonitor()   // 逐行對照 ScrollCaptureSession.installEscMonitor（含註解理由）
        armWatchdog(seconds: AppSettings.overlayWatchdogSeconds)
    }

    /// 再按快鍵的語意：recording 中＝停止收檔（不是丟棄——使用者按快鍵最可能想結束並拿結果）；
    /// 其餘 active 狀態（selecting/armed/finishing）＝取消。finishing 由 `cancel()` 自己擋掉
    /// （不接受取消，見該方法），這裡不必特判。
    public func cancelIfActive() {
        if state == .recording { stopRecording(); return }
        if isActive { cancel() }
    }

    private func enterArmed(_ selection: CGRect, _ scr: NSScreen) {
        // 兩個分支都要先掛好取消：太小選區的死路訊息也要有一顆按得下去的「取消」按鈕。
        hud.onCancel = { [weak self] in self?.cancel() }
        guard selection.width >= Self.minSelectionEdgePt,
              selection.height >= Self.minSelectionEdgePt else {
            hud.show(near: selection, on: scr, mode: .armed)
            hud.showMessage("選區太小，拉大一點才能開始")
            return
        }
        // 已 armed（使用者在調框）→ 只跟著更新 HUD 位置，不可重跑進場流程。
        if state != .armed {
            state = .armed
            hud.onStart = { [weak self] in self?.startRecording() }
        }
        hud.show(near: selection, on: scr, mode: .armed)   // 冪等：調框只更新位置（也順便清掉太小訊息）
    }

    // MARK: 錄製

    private func startRecording() {
        guard state == .armed, let screen else { return }
        state = .recording
        durationLimit = hud.durationSeconds
        overlay.enterCapturing()          // 框線保留、事件穿透（app 已整體排除，不會被拍入）
        NSCursor.arrow.set()
        hud.show(near: overlay.selectionGlobal, on: screen, mode: .recording)
        hud.onStop = { [weak self] in self?.stopRecording() }

        // 點擊圈：**建 filter 前先 prepare**（exceptingWindows 是靜態快照——設計文件 §3）。
        var ringNumber: Int?
        if AppSettings.recordClickRing, AppSettings.recordShowsCursor {
            ringNumber = clickRing.prepare()
            clickRing.startMonitoring()
        }
        // 可能遲到或不只一次——guard state == .recording 讓重覆/遲到呼叫變 no-op（契約要求冪等）。
        frameSource.onStreamError = { [weak self] _ in self?.stopRecording() }
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        startClock()
        let selectionGlobal = overlay.selectionGlobal
        let url = output.tempMovieURL()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.frameSource.start(selectionGlobal: selectionGlobal, screen: screen,
                                                 showsCursor: AppSettings.recordShowsCursor,
                                                 ringWindowNumber: ringNumber, outputURL: url)
            } catch {
                // state != .recording 代表 await 期間已經被 cancel()／stopRecording() 处理過
                // （各自的路徑已經 teardown＋發過 onFinished，不能在這裡重發第二次）。
                if self.state == .recording {
                    self.teardown()
                    self.onFinished?(nil, screen.backingScaleFactor)
                    NSLog("anypaint: 動畫截圖 stream 啟動失敗 %@", String(describing: error))
                }
                return
            }
            // start 成功返回，但 await 期間 state 已經被改掉（例如很快就按了停止/取消）：
            // frameSource 內部已經在 pendingStop 分支自我清理過，這裡的 abort() 只是確保
            // 兩邊帳目一致（abort() 對「其實沒有活 stream」的情況本身是 no-op，見其註解）。
            if self.state != .recording { await self.frameSource.abort() }
        }
        armWatchdog(seconds: durationLimit ?? Self.maxRecordingSeconds)  // 限時或 10 分鐘上限
    }

    /// 時鐘：wall-clock Timer（.common mode——tracking loop 期間也要跳，ScrollCaptureSession 同款）。
    /// 不可從影格 PTS 推（靜止時 SCK 不供格，PTS 時鐘會凍結——設計文件 §5）。
    private func startClock() {
        clock?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clockTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func clockTick() {
        guard state == .recording else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStartedAt
        hud.updateClock(elapsed: elapsed, limit: durationLimit)
        if let limit = durationLimit, elapsed >= limit { stopRecording() }  // 倒數到＝正常停止
    }

    /// 停止（手動鈕／倒數到／看門狗／stream error 共用同一條，設計文件 §2）。
    private func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        watchdog?.cancel(); watchdog = nil
        clock?.invalidate(); clock = nil
        clickRing.teardown()
        let scale = screen?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.frameSource.stopAndFinish()
                guard self.state == .finishing else { return }   // 期間被 cancel（防二次 onFinished）
                self.teardown()
                self.onFinished?(url, scale)
            } catch {
                guard self.state == .finishing else { return }
                self.teardown()
                self.onFinished?(nil, scale)
                if case RecordError.noFrames = error { NSSound.beep() }   // 一格都沒錄到
                else { NSLog("anypaint: 動畫截圖收檔失敗 %@", String(describing: error)) }
            }
        }
    }

    private func cancel() {
        guard state != .idle, state != .finishing else { return }   // finishing 不接受取消（同 scroll 理由）
        let wasRecording = state == .recording
        teardown()
        if wasRecording { Task { await frameSource.abort() } }      // 丟母帶＋刪暫存
        onFinished?(nil, screen?.backingScaleFactor ?? 2)
    }

    // MARK: 看門狗／Esc／teardown

    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        guard seconds > 0 else { watchdog = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.state == .recording { self.stopRecording() }    // 錄製逾時＝收檔保留
            else { self.cancel() }                                  // selecting/armed 逾時＝取消
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func installEscMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.state == .selecting || self.state == .armed {
                self.cancel()
                return nil
            }
            return event
        }
        if let monitor { eventMonitors.append(monitor) }
    }

    private func teardown() {
        clock?.invalidate(); clock = nil
        watchdog?.cancel(); watchdog = nil
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()
        clickRing.teardown()
        overlay.dismiss()
        hud.dismiss()
        durationLimit = nil
        state = .idle
    }
}
