import AppKit
import AVFoundation

/// 動畫截圖協調者（設計文件 §2 狀態機）。組裝 overlay/HUD/frameSource/clickRing，
/// 自己不做編碼，只管「誰在什麼時候呼叫誰」＋逃生路徑。整體對照 `ScrollCaptureSession`
/// （同為 @MainActor 狀態機；進場/Esc monitor/看門狗/teardown 冪等），但簡單得多——
/// 沒有 engine/matcher/滾輪，收檔交給 `RecordFrameSource`／`WriterBox` 自己序列化。
@MainActor
public final class RecordSession {
    public enum State { case idle, selecting, armed, recording, finishing }
    public private(set) var state: State = .idle
    public var isActive: Bool { state != .idle }

    /// 收尾結果（對抗式審查 #1/#3：單一終結回呼帶結果，不拆兩條 callback）。
    /// `.saved`＝母帶暫存 URL（呼叫端負責搬到最終位置後才 `presentDone`）；`.failed`＝可讀原因；
    /// `.cancelled`＝使用者丟棄（HUD 已完整 dismiss，不顯示完成面板）。
    public enum Outcome: Equatable {
        case saved(tempURL: URL)
        case failed(reason: String)
        case cancelled
    }
    /// 收尾回呼。第二參數＝擷取螢幕 backingScaleFactor（語意同 `ScrollCaptureSession.onFinished`：
    /// 呼叫端換算預覽/裁切要用它，不能自己問 `NSScreen.main`——混合 DPI 多螢幕下會用錯 scale）。
    /// **單一還原出口**：呼叫端不論成功失敗都要在此開頭恢復快鍵/選單（對抗式審查 #1）。
    public var onFinished: ((Outcome, CGFloat) -> Void)?
    /// 完成面板 ↺ 重錄請求（AppDelegate 用存下的 `lastRecordRegion` 走 `.reArm` 重入，不重用自動化入口）。
    public var onReRecord: (() -> Void)?
    /// 錄影框選中按 R：把當下畫面（含工具）轉交截圖流程。AppDelegate 擷取快照後中止本 session、起截圖。
    public var onReshootToScreenshot: (() -> Void)?
    /// 最近一次錄製的選區（全域點座標）：完成面板定位／重錄沿用（在 overlay dismiss 前存下——對抗式審查 #8）。
    public private(set) var lastRecordRegion: CGRect = .zero
    /// 最近一次錄製時長（秒）：完成面板中繼資訊用（stop 當下由 recordingStartedAt 算）。
    private var lastElapsed: Double = 0

    /// 不限時錄製的看門狗上限：10 分鐘自動走正常停止（防忘記停吃磁碟，設計文件 §2）。
    static let maxRecordingSeconds: Double = 600
    /// 最小選區邊長（**點**——CLAUDE.md 單位教訓；錄製無匹配需求，64pt 足夠）。
    static let minSelectionEdgePt: CGFloat = 64
    /// `.finishing` 的逃生繩：`stopAndFinish()` 鏈（`finishWriting` 不回呼／`stopCapture` 卡住
    /// SCK）萬一卡死，這是唯一救得回來的看門狗（review fix round 1 Important 1——`.finishing`
    /// 原本是狀態機裡唯一沒有看門狗的狀態，卡住就永久卡死：`cancelIfActive` 被 guard 擋死、
    /// 再按快鍵沒反應，只能重啟 app）。30 秒遠大於正常 `finishWriting` 所需時間。
    static let finishingWatchdogSeconds: Double = 30

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
    /// 待命階段的麥克風試音錶（Task B2）：armed 時掛在錄影裝置上,錄製開始時 stop 讓位給 RecordMicSource。
    private let micProbe = MicLevelMonitor()
    /// 無訊號防呆的純狀態機（連續靜音達門檻才警告）。待命/錄製各重置一次。
    private var silenceTracker = MicSilenceTracker()

    public init(output: RecordOutputService) { self.output = output }

    // MARK: 進入/取消

    public func begin() {
        guard state == .idle, let screen = ScrollCaptureSession.screenUnderMouse() else { return }
        enterSelecting(on: screen) { overlay.present(on: screen) }
    }

    /// RPC 自動化入口（`UITestServer` `startRecord` 命令消費）：跳過拉框互動，直接以給定
    /// 全域矩形進入 armed 並開始錄製——與熱鍵入口 `begin()` 共用 `enterSelecting`／
    /// `enterArmed`／`startRecording` 這幾段既有程式碼（不複製邏輯），差別只在選區來源是
    /// 參數而不是滑鼠拖曳：`ScrollSelectionOverlayController.presentLocked` 觸發與滑鼠
    /// `mouseUp` 鎖定完全相同的 `onSelectionLocked` 回呼，進而呼叫 `enterArmed`。
    ///
    /// 矩形寬或高超出目標螢幕時 `presentLocked` 回 `false`（不建視窗）：`lockProgrammatically`
    /// 底下的 `clampToBounds` 對這種輸入會算出負 origin，`presentLocked` 已經在呼叫它之前擋掉
    /// （review fix round 1 Important 6）。這裡收到 false 就 `teardown()` 收乾淨、退回 `.idle`——
    /// `enterSelecting` 已經把 state 撥到 `.selecting`／掛好 Esc monitor／看門狗，沒建成視窗
    /// 不能留著這些半吊子狀態。
    /// - Parameter rect: AppKit 全域座標（點，左下原點）。
    public func startProgrammatically(rect: CGRect) {
        guard state == .idle, let screen = Self.screen(containing: rect) else { return }
        var locked = false
        enterSelecting(on: screen) { locked = overlay.presentLocked(rect, on: screen) }
        guard locked else { teardown(); return }
        // 自動化沒有滑鼠可按「開始」鍵：選區夠大時直接接著走完 armed → recording。
        // 選區太小時 enterArmed 早退，state 停在 enterSelecting 剛設的 .selecting（不是
        // .armed——早退分支完全沒碰 state），只顯示訊息；這裡不強行往下推，行為與互動路徑一致。
        if state == .armed {
            startRecording()
            if state == .recording {
                // 「RPC 錄影＝不限時直到 stopRecord」（docs/automation.md）：`startRecording()`
                // 剛剛已經把 `durationLimit` 設成 `hud.durationSeconds`——那個秒數欄是跨 session
                // 重用的同一個 HUD 面板（`dismiss()` 不會把 panel 設 nil），殘留上次互動錄製打進去
                // 的秒數會原封不動沿用，讓這次 RPC 錄影被一個使用者根本沒設過的幽靈時限提早停掉。
                // 這裡明確蓋掉並重新 arm 看門狗（`startRecording()` 結尾那顆已經用了舊值 arm 過）。
                durationLimit = nil
                armWatchdog(seconds: Self.maxRecordingSeconds)
                hud.showTransientNotice("🤖 遠端自動化錄影")   // 混淆代理人對策 b：遠端觸發要有可見標示
            }
        }
    }

    /// ↺ 重錄專用（對抗式審查 #5）：用鎖定選區重入 **armed**——不 auto-start、不掛「🤖遠端自動化」
    /// 標籤、保留使用者的秒數/裝置設定（讓他再按開始）。與 `startProgrammatically` 的差別正是不往下推到
    /// recording，避免把本地使用者點擊誤標成遠端自動化並吞掉時限。
    /// - Parameter rect: AppKit 全域座標（點，左下原點）。
    public func startArmed(rect: CGRect) {
        guard state == .idle, let screen = Self.screen(containing: rect) else { return }
        var locked = false
        enterSelecting(on: screen) { locked = overlay.presentLocked(rect, on: screen) }
        guard locked else { teardown(); return }
        // presentLocked 觸發 onSelectionLocked → enterArmed；選區太小時停在訊息態，與互動路徑一致。
    }

    /// selecting 進場共用碼（`begin()`／`startProgrammatically(rect:)` 唯一差異只在怎麼把選區
    /// 餵給 overlay，回呼接線／Esc monitor／看門狗完全相同——抽出來避免兩份逐字複製隨時間漂移）。
    /// - Parameter present: 建視窗＋（可能）鎖定選區的那一步，各自傳對應的 overlay 呼叫。
    private func enterSelecting(on screen: NSScreen, present: () -> Void) {
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
        overlay.onReshootRequested = { [weak self] in self?.onReshootToScreenshot?() }
        present()
        installEscMonitor()   // 逐行對照 ScrollCaptureSession.installEscMonitor（含註解理由）
        armWatchdog(seconds: AppSettings.overlayWatchdogSeconds)
    }

    /// `rect` 中心點命中的螢幕；命中不到（跨螢幕邊界外、螢幕熱插拔瞬間）退回滑鼠所在螢幕
    /// （與 `screenUnderMouse()` 同一套退路，不重複實作）。
    private static func screen(containing rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let i = ScrollCoords.screenIndex(containing: center, screenFrames: screens.map(\.frame)) {
            return screens[i]
        }
        return ScrollCaptureSession.screenUnderMouse()
    }

    /// 再按快鍵的語意：recording 中＝停止收檔（不是丟棄——使用者按快鍵最可能想結束並拿結果）；
    /// 其餘 active 狀態（selecting/armed/finishing）＝取消。finishing 由 `cancel()` 自己擋掉
    /// （不接受取消，見該方法），這裡不必特判。
    /// 取消請求在各狀態下的動作（純路由,可測）：錄影中＝正常停止收檔;其餘進行中＝丟棄取消;閒置＝不動。
    public enum CancelAction: Equatable { case stop, cancel, none }
    public nonisolated static func cancelAction(for state: State) -> CancelAction {
        if state == .recording { return .stop }
        return state == .idle ? .none : .cancel
    }

    public func cancelIfActive() {
        switch Self.cancelAction(for: state) {
        case .stop: stopRecording()
        case .cancel: cancel()
        case .none: break
        }
    }

    /// RPC `abortRecord`：不論目前處於哪個 active 狀態都強制取消並丟棄母帶（同 Esc／取消鈕）。
    /// 與 `cancelIfActive()` 不同——後者在 `.recording` 中視為「停止並保留」（熱鍵語意）；
    /// 這裡不管有沒有在錄，一律丟棄，供自動化明確表達「不要這次結果」。
    public func abortIfActive() {
        guard isActive else { return }
        cancel()
    }

    private func enterArmed(_ selection: CGRect, _ scr: NSScreen) {
        // 兩個分支都要先掛好取消：太小選區的死路訊息也要有一顆按得下去的「取消」按鈕。
        hud.onCancel = { [weak self] in self?.cancel() }
        guard SelectionGeometry.meetsMinEdge(selection.size, min: Self.minSelectionEdgePt) else {
            hud.show(near: selection, on: scr, mode: .armed)
            hud.showMessage("選區太小，拉大一點才能開始")
            return
        }
        // 選區像素尺寸給 HUD 資訊列（點×scale）。調框時每次更新。
        let scale = scr.backingScaleFactor
        hud.setRegion(widthPx: Int((selection.width * scale).rounded()),
                      heightPx: Int((selection.height * scale).rounded()))
        // 已 armed（使用者在調框）→ 只跟著更新 HUD 位置，不可重跑進場流程。
        if state != .armed {
            state = .armed
            hud.onStart = { [weak self] in self?.startRecording() }
            // 使用者在 HUD 改錄音裝置/開關 → 重掛待命試音錶（讀新設定）。
            hud.onOptionsChanged = { [weak self] in self?.startStandbyMic() }
            startStandbyMic()   // 待命試音錶：先讓使用者看到麥克風有沒有聲音再決定開始
        }
        hud.show(near: selection, on: scr, mode: .armed)   // 冪等：調框只更新位置（也順便清掉太小訊息）
    }

    /// 待命麥克風試音錶（Task B2）：依設定的錄影麥克風裝置掛 MicLevelMonitor,餵 HUD 電平表＋無訊號警告。
    /// 未開麥克風＝隱藏電平表。
    private func startStandbyMic() {
        let opts = RecordOptions.fromSettings()
        guard opts.captureMicrophone else { hud.setMicEnabled(false); return }
        silenceTracker = MicSilenceTracker()
        let deviceName = opts.microphoneDeviceID.flatMap { id in
            AudioInputDeviceList.all().first { $0.uniqueID == id }?.name
        }
        hud.setMicEnabled(true, deviceName: deviceName)
        micProbe.onLevel = { [weak self] level in
            guard let self else { return }
            self.hud.setMicLevel(level)
            self.hud.setNoSignal(self.silenceTracker.update(rms: level, now: ProcessInfo.processInfo.systemUptime))
        }
        micProbe.start(deviceID: opts.microphoneDeviceID)
    }
    private func stopStandbyMic() { micProbe.stop(); micProbe.onLevel = nil }

    /// 錄製中電平回呼（RecordMicSource → 這裡 → HUD）：更新電平表＋無訊號警告。
    private func feedRecordingMicLevel(_ level: Float) {
        hud.setMicLevel(level)
        hud.setNoSignal(silenceTracker.update(rms: level, now: ProcessInfo.processInfo.systemUptime))
    }

    // MARK: 錄製

    private func startRecording() {
        guard state == .armed, let screen else { return }
        state = .recording
        stopStandbyMic()                       // 待命試音錶讓位給 RecordMicSource（同一顆裝置不重複開）
        silenceTracker = MicSilenceTracker()   // 錄製階段重新計無訊號
        durationLimit = hud.durationSeconds
        // 錄製中電平回呼（RecordMicSource→這裡→HUD）。無條件設定：mic 關閉時 micSource 為 nil,回呼自然不觸發。
        // 在 Task 外、MainActor 上設屬性,避開把 @MainActor 閉包穿過 async 的型別推斷歧義。
        frameSource.onMicLevel = { [weak self] level in self?.feedRecordingMicLevel(level) }
        overlay.enterCapturing()          // 框線保留、事件穿透（app 已整體排除，不會被拍入）
        NSCursor.arrow.set()
        hud.show(near: overlay.selectionGlobal, on: screen, mode: .recording)
        hud.onStop = { [weak self] in self?.stopRecording() }

        // 點擊圈：**建 filter 前先 prepare**（exceptingWindows 是靜態快照——設計文件 §3）。
        var ringNumber: Int?
        if AppSettings.recordClickRing, AppSettings.recordShowsCursor {
            // near: 選區中心——必須落在實際螢幕內，見 ClickRingOverlay.prepare(near:) 的註解
            // （review 判定為真缺陷：螢幕外＋alpha 0 的視窗可能不被 SCShareableContent 列到）。
            ringNumber = clickRing.prepare(near: CGPoint(x: overlay.selectionGlobal.midX,
                                                          y: overlay.selectionGlobal.midY))
            clickRing.startMonitoring()
        }
        // 可能遲到或不只一次——guard state == .recording 讓重覆/遲到呼叫變 no-op（契約要求冪等）。
        frameSource.onStreamError = { [weak self] _ in self?.stopRecording() }
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        startClock()
        let selectionGlobal = overlay.selectionGlobal
        lastRecordRegion = selectionGlobal   // 對抗式審查 #8：在 overlay dismiss 前存下,供完成面板定位／重錄
        let url = output.tempMovieURL()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var options = RecordOptions.fromSettings()
                if options.captureMicrophone,
                   AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    options.captureMicrophone = false   // 降級續錄，不中斷（spec §3）
                    self.hud.showTransientNotice("🎙 麥克風權限未授予，本次未錄麥克風")
                }
                // 錄製真正開始處：用降級後的 options 設定 HUD 徽章，與實際錄到的音軌一致。
                self.hud.micActive = options.captureMicrophone
                self.hud.setMicEnabled(options.captureMicrophone)   // 錄製中維持電平表可見（若有麥克風）
                try await self.frameSource.start(selectionGlobal: selectionGlobal, screen: screen,
                                                 ringWindowNumber: ringNumber, outputURL: url,
                                                 options: options)
            } catch {
                // state != .recording 代表 await 期間已經被 cancel()／stopRecording() 处理過
                // （各自的路徑已經 teardown＋發過 onFinished，不能在這裡重發第二次）。
                if self.state == .recording {
                    // 最可能撞到的實機失敗是 TCC 拒絕（使用者第一次用）——此時框與 HUD 會憑空
                    // 消失，但 NSLog 在未公證自簽 app 撈不到（CLAUDE.md 診斷原則），使用者拿不到
                    // 任何回饋。至少給一聲 beep（TCC 權限 alert 的完整流程屬 AppDelegate 層，
                    // 不在這裡做）。
                    NSSound.beep()
                    self.teardownKeepingHUD()   // 留 HUD 讓呼叫端 morph 成失敗態（或 dismiss）
                    self.onFinished?(.failed(reason: "startFailed"), screen.backingScaleFactor)
                    UITestServer.shared?.emit("recordingFailed", ["reason": "startFailed: \(error)"])
                    NSLog("anypaint: 動畫截圖 stream 啟動失敗 %@", String(describing: error))
                }
                return
            }
            // start 成功返回，但 await 期間 state 已經被改掉（例如很快就按了停止/取消）：
            // frameSource 內部已經在 pendingStop 分支自我清理過，這裡的 abort() 只是確保
            // 兩邊帳目一致（abort() 對「其實沒有活 stream」的情況本身是 no-op，見其註解）。
            // 同一個判斷也決定要不要發 recordingStarted：state 已經被改掉代表 await 期間搶跑了
            // cancel()／stopRecording()，那兩條路徑各自已經發過 recordingAborted／後面會發
            // recordingStopped，這裡再發 recordingStarted 就是「已經結束的錄製又冒出開始事件」
            // 的假陽性（review fix round 1 Important 1）。
            if self.state != .recording {
                await self.frameSource.abort()
            } else {
                UITestServer.shared?.emit("recordingStarted", [:])   // 錄製真正開始（stream 已起）
            }
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
        clock?.invalidate(); clock = nil
        clickRing.teardown()
        // 不是單純取消看門狗——重新 arm 一顆 finishing 專用的（見 armWatchdog 的 .finishing
        // 分支與 Self.finishingWatchdogSeconds 的註解）。
        armWatchdog(seconds: Self.finishingWatchdogSeconds)
        let scale = screen?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.frameSource.stopAndFinish()
                guard self.state == .finishing else { return }   // 期間被 cancel（防二次 onFinished）
                self.lastElapsed = ProcessInfo.processInfo.systemUptime - self.recordingStartedAt
                self.teardownKeepingHUD()   // 留 HUD 原地 morph 成 done（呼叫端 save 完才 showDone）
                self.onFinished?(.saved(tempURL: url), scale)
                UITestServer.shared?.emit("recordingStopped", ["outputURL": url.path])
            } catch {
                guard self.state == .finishing else { return }
                self.teardownKeepingHUD()
                self.onFinished?(.failed(reason: "finishFailed"), scale)
                UITestServer.shared?.emit("recordingFailed", ["reason": "finishFailed: \(error)"])
                // NSLog 在未公證自簽 app 撈不到（CLAUDE.md 診斷原則）——不論哪種失敗都要有
                // 使用者感知得到的回饋，否則整段錄製「憑空消失」使用者卻毫無所覺。
                if case RecordError.noFrames = error { NSSound.beep() }   // 一格都沒錄到
                else {
                    NSSound.beep()
                    NSLog("anypaint: 動畫截圖收檔失敗 %@", String(describing: error))
                }
            }
        }
    }

    private func cancel() {
        guard state != .idle, state != .finishing else { return }   // finishing 不接受取消（同 scroll 理由）
        let wasRecording = state == .recording
        teardown()                                                  // 取消＝完整 teardown（含 dismiss HUD，不留 done 面板）
        if wasRecording { Task { await frameSource.abort() } }      // 丟母帶＋刪暫存
        onFinished?(.cancelled, screen?.backingScaleFactor ?? 2)
        UITestServer.shared?.emit("recordingAborted", [:])
    }

    // MARK: 看門狗／Esc／teardown

    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        guard seconds > 0 else { watchdog = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.state {
            case .recording:
                self.stopRecording()             // 錄製逾時＝收檔保留
            case .finishing:
                // stopAndFinish() 卡死時的最後防線（review fix round 1 Important 1）。
                // teardown() 把 state 設回 idle：稍後 stopRecording() 裡那個 Task 若真的等到
                // stopAndFinish() 回來（成功或失敗），各自的 `guard self.state == .finishing`
                // 會擋下，不會二次觸發 onFinished——與現有守衛完全相容，不必額外加旗標。
                // 若母帶其實已經寫完只是回呼卡住，半成品/完成檔留在暫存目錄，交給下次啟動的
                // `RecordOutputService.cleanupStaleTempFiles()` 掃掉，這裡不等也不主動刪
                // （沒有安全的方式在不確定 writer 是否還在寫的情況下去動那個檔案）。
                // 這條放生路徑原本零回饋（NSLog 在未公證自簽 app 撈不到——CLAUDE.md）——
                // 使用者只會看到框與 HUD 憑空消失，比照上面 writerFailed 的 beep 給個訊號。
                NSSound.beep()
                self.teardownKeepingHUD()
                self.onFinished?(.failed(reason: "finishingTimeout"), self.screen?.backingScaleFactor ?? 2)
                UITestServer.shared?.emit("recordingFailed", ["reason": "finishingTimeout"])
            default:
                self.cancel()                    // selecting/armed 逾時＝取消
            }
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

    /// 收乾淨但**保留 HUD 面板**（成功/失敗收尾用）：overlay dismiss、但不 `hud.dismiss()`，
    /// 讓呼叫端把 HUD 原地 morph 成 done/doneFailed（或動畫截圖路徑另行 `dismissHUD()`）。
    /// 對抗式審查 #8：`lastRecordRegion` 已在 startRecording 存好，這裡才 dismiss overlay。
    private func teardownKeepingHUD() {
        stopStandbyMic()
        clock?.invalidate(); clock = nil
        watchdog?.cancel(); watchdog = nil
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()
        clickRing.teardown()
        overlay.dismiss()
        durationLimit = nil
        state = .idle
        frameSource.onStreamError = nil
    }

    private func teardown() {
        teardownKeepingHUD()
        hud.dismiss()
    }

    // MARK: 完成面板出口（AppDelegate save 完後驅動；spec §3.2）

    /// 成功：把 HUD 原地 morph 成完成面板。`finalURL`＝已搬到最終位置的檔案；`sizeBytes`＝其大小。
    public func presentDone(finalURL: URL, sizeBytes: Int64, saveDirectory: URL?) {
        guard let screen = lastScreenForDone() else { hud.dismiss(); return }
        hud.onReRecord = { [weak self] in self?.onReRecord?() }
        hud.onDoneClosed = { [weak self] in self?.dismissHUD() }
        hud.showDone(near: lastRecordRegion, on: screen, url: finalURL,
                     durationSec: lastElapsed, sizeBytes: sizeBytes, saveDirectory: saveDirectory)
    }

    /// 失敗：把 HUD 原地 morph 成失敗態。
    public func presentDoneFailed(detail: String, saveDirectory: URL?) {
        guard let screen = lastScreenForDone() else { hud.dismiss(); return }
        hud.onReRecord = { [weak self] in self?.onReRecord?() }
        hud.onDoneClosed = { [weak self] in self?.dismissHUD() }
        hud.showDoneFailed(near: lastRecordRegion, on: screen, detail: detail, saveDirectory: saveDirectory)
    }

    /// 動畫截圖路徑（direct:false）或取消：直接收 HUD（不留完成面板）。
    public func dismissHUD() { hud.dismiss() }

    private func lastScreenForDone() -> NSScreen? {
        screen ?? Self.screen(containing: lastRecordRegion)
    }
}
