import AppKit
import AVFoundation
import KeyboardShortcuts
import UniformTypeIdentifiers

/// 目前作用中的模式（互斥,優先序：freeze > scroll > record）。純值＋純解析,供 selftest 測。
public enum AppActiveMode: Equatable {
    case none, freeze, scroll, record
    /// 優先序解析：框選/擷取進行中＝freeze 最優先,其次滾動、錄影,皆無＝none。
    public static func resolve(freeze: Bool, scroll: Bool, record: Bool) -> AppActiveMode {
        if freeze { return .freeze }
        if scroll { return .scroll }
        if record { return .record }
        return .none
    }
}

/// 應用協調者：組裝各模組、註冊快鍵、串起截圖與貼圖流程。
/// 自己不做底層細節，只負責「誰在什麼時候呼叫誰」。
/// @MainActor：ScrollCaptureSession（Task 12）與 ScrollPreviewWindowController（Task 13）都是
/// @MainActor-isolated 型別，這裡的 stored property 初始化與呼叫都需要在 MainActor context 下
/// 執行——AppDelegate 本就全程跑在主執行緒（NSApplicationDelegate），標註只是讓編譯器認可既有事實。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let capturer = ScreenCapturer()
    private let pinboard = PinboardService()
    private let pinController = PinWindowController()
    private let output = CaptureOutputService()

    // 單一持久的 overlay 協調者（不再每次 new，避免造出沒人管的孤兒視窗）。
    private let overlayController = SelectionOverlayController()
    // 同步防重入旗標：擷取是 async，這個旗標在按下當下就設，擋住連按空窗期。
    private var captureInFlight = false

    private let scrollSession = ScrollCaptureSession()
    private var previewController: ScrollPreviewWindowController?

    private let recordOutput = RecordOutputService()
    private lazy var recordSession = RecordSession(output: recordOutput)
    private var recordPreviewController: RecordPreviewWindowController?

    /// 框選 OCR 的結果窗（lazy、重用）與辨識中旗標（不疊請求，比照 PinWindowController）。
    private var ocrController: OCRResultWindowController?
    private var ocrInFlight = false

    private var settingsWindowController: SettingsWindowController?

    /// RPC 專用試音錶（`micProbeStart`/`micLevel`/`micProbeStop`）：與設定頁
    /// `CaptureSettingsViewController` 自己持有的 `MicLevelMonitor` 是**兩個獨立實例**——取簡
    /// （A7 brief 明確二選一，記錄選擇）。`MicLevelMonitor` 沒有 singleton 防同裝置多 session
    /// （A6 審查已指出的已知限制）：若設定頁同時開著同一顆裝置，會有兩條 `AVCaptureSession`
    /// 各自對同一裝置起 `AVCaptureDeviceInput`——實測（見 task-A7-report）沒有導致 crash，
    /// 兩者各自拿到獨立的樣本流；正常自動化情境設定頁通常沒開，可接受。
    private lazy var micProbeMonitor = MicLevelMonitor()

    /// 四入口互斥（spec §9.1）：任一 capture mode active 時其他入口 guard-return。
    /// preview 不佔 mode（session 已結束，開著可以再截）。
    typealias ActiveMode = AppActiveMode
    private var activeMode: ActiveMode {
        AppActiveMode.resolve(freeze: overlayController.isActive || captureInFlight,
                              scroll: scrollSession.isActive, record: recordSession.isActive)
    }

    public override init() { super.init() }

    /// 內建自檢（ANYPAINT_SCROLL_SELFCHECK=1）：不進正常啟動流程，跑完寫檔即結束。
    private var scrollSelfCheck: ScrollCaptureSelfCheck?
    /// 動畫截圖內建自檢（--record-selfcheck）：同上，跑完寫檔即結束。
    private var recordSelfCheck: RecordSelfCheck?
    /// 音訊自檢（--audio-selfcheck）：同上，跑完寫檔即結束。
    private var audioSelfCheck: RecordAudioSelfCheck?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 必須用啟動參數（不是環境變數）：從終端直跑 binary 時 TCC 把螢幕錄製的責任歸給終端機
        // 而非 app（實測 -3801 拒絕）；走 `open -a … --args --scroll-selfcheck` 由 launchd 啟動，
        // 才會套用 app 自己已授權的身分。
        if CommandLine.arguments.contains("--scroll-selfcheck")
            || ProcessInfo.processInfo.environment["ANYPAINT_SCROLL_SELFCHECK"] == "1" {
            let check = ScrollCaptureSelfCheck()
            scrollSelfCheck = check
            check.run()
            return
        }
        if CommandLine.arguments.contains("--record-selfcheck") {
            let check = RecordSelfCheck()
            recordSelfCheck = check
            check.run()
            return
        }
        if CommandLine.arguments.contains("--audio-selfcheck") {
            let check = RecordAudioSelfCheck()
            audioSelfCheck = check
            check.run()
            return
        }
        UITestServer.startIfRequested()
        UITestServer.shared?.commandHandler = { [weak self] command in self?.handleUITestCommand(command) }
        // app 啟動時清一次殘留暫存母帶（上次 crash/強退遺留）。只能在真正的啟動路徑呼叫一次：
        // 若放進上面 selfcheck 分支或任何其他路徑，`open -n` 開的第二個實例可能在另一個實例
        // 錄製中途把它的暫存母帶當「殘留」刪掉。
        recordOutput.cleanupStaleTempFiles()

        // 選單列動作
        menuBar.onCapture = { [weak self] in self?.beginCapture() }
        menuBar.onPin = { [weak self] in self?.pinFromClipboard() }
        menuBar.onScrollCapture = { [weak self] in self?.beginScrollCapture() }
        menuBar.onAnimatedCapture = { [weak self] in self?.beginAnimatedCapture() }
        menuBar.onRecord = { [weak self] in self?.beginRecordDirect() }
        menuBar.onCloseAllPins = { [weak self] in self?.pinController.closeAll() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }

        // 重拍（overlay 中按 R）：對現在的實況畫面重新凍結（含工具本身），換掉舊 overlay。
        // 沿用 present() 已存的處理器閉包（含原始 vars），故這裡只需擷取＋換場。
        overlayController.onReshoot = { [weak self] in self?.reshootOverlay() }

        // ↺ 重錄（完成面板）：用最近選區走 .reArm 重入 armed（不 auto-start／不掛自動化標籤，
        // 對抗式審查 #5）。經 beginRecord 重跑完整 disable/menu/onFinished 設定，不漏互斥。
        recordSession.onReRecord = { [weak self] in
            guard let self else { return }
            self.beginRecord(direct: true, rect: self.recordSession.lastRecordRegion, autoStart: false)
        }
        // 錄影框選中按 R：把當下畫面（含工具）轉成截圖，之後截圖與錄影都解除。
        recordSession.onReshootToScreenshot = { [weak self] in self?.reshootRecordToScreenshot() }

        // 全域快鍵（可在設定頁更改；底層為 Carbon，免輔助使用權限）
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in self?.beginCapture() }
        KeyboardShortcuts.onKeyDown(for: .pin) { [weak self] in self?.pinFromClipboard() }
        KeyboardShortcuts.onKeyDown(for: .scrollCapture) { [weak self] in self?.beginScrollCapture() }
        KeyboardShortcuts.onKeyDown(for: .animatedCapture) { [weak self] in self?.beginAnimatedCapture() }
        KeyboardShortcuts.onKeyDown(for: .record) { [weak self] in self?.beginRecordDirect() }
    }

    // MARK: - 截圖：凍結 → 框選 → 複製到剪貼簿

    private func beginCapture() {
        guard !scrollSession.isActive else { return }   // 滾動中不疊凍結（spec §9.1）
        guard !recordSession.isActive else { return }   // 動畫截圖中不疊凍結（spec §9.1）
        // 已在框選中 → 再按一次截圖快鍵視為「取消/逃生」。
        if overlayController.isActive {
            overlayController.cancelIfActive()
            return
        }
        // 擷取進行中（async 空窗期）→ 不重複啟動，杜絕疊加。
        guard !captureInFlight else { return }
        captureInFlight = true

        // %title% 於按下快鍵當下凍結（spec）：此刻最前景視窗才是使用者要記的那個。
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())

        Task { @MainActor in
            defer { self.captureInFlight = false }
            do {
                let snapshots = try await capturer.captureAllDisplays()
                presentCaptureOverlay(snapshots: snapshots, vars: vars)
            } catch CaptureError.noPermission {
                showPermissionAlert()
            } catch {
                NSLog("anypaint: 擷取失敗 \(error)")
                NSSound.beep()
            }
        }
    }

    /// 用一組快照起截圖框選 overlay＋接好所有結果處理器（`beginCapture` 與「錄影框選按 R 轉截圖」共用，
    /// 不複製兩份 handler）。
    private func presentCaptureOverlay(snapshots: [DisplaySnapshot], vars: [String: String]) {
        overlayController.present(
            snapshots: snapshots,
            onSelect: { [weak self] image in
                self?.pinboard.copy(image: image)
                self?.output.autoSaveIfEnabled(image: image, vars: vars)
            },
            onSave: { [weak self] image in
                self?.pinboard.copy(image: image)   // 剪貼簿先有——寫檔失敗也不白截（spec）
                self?.output.saveExpanding(template: AppSettings.quickSavePathTemplate,
                                            image: image, vars: vars, quiet: false)
                self?.output.autoSaveIfEnabled(image: image, vars: vars)
            },
            onSaveAs: { [weak self] image in
                self?.pinboard.copy(image: image)   // 對話框取消也不白截（spec）
                self?.output.saveWithPanel(image: image, vars: vars)
                self?.output.autoSaveIfEnabled(image: image, vars: vars)
            },
            onOpen: { [weak self] image in
                self?.pinboard.copy(image: image)   // 剪貼簿先有——寫檔或開啟失敗也不白截
                self?.output.saveAndOpen(image: image, vars: vars)
                self?.output.autoSaveIfEnabled(image: image, vars: vars)
            },
            onRecognizeText: { [weak self] image, frame in
                self?.recognizeText(in: image, near: frame)
            },
            onPin: { [weak self] image, frame in
                self?.pinboard.copy(image: image)                    // 決策：貼＝同時複製
                self?.pinController.pin(image: image, frame: frame)
                self?.output.autoSaveIfEnabled(image: image, vars: vars)
            },
            onCancel: { }
        )
    }

    /// 錄影框選中按 R：把**當下畫面（含錄影框選工具本身）**凍結成快照，中止錄影 session，
    /// 用那張快照起正常截圖流程。順序關鍵：先擷取（此時錄影 overlay/HUD 還在畫面上→入鏡），
    /// 再中止錄影，最後起截圖。截圖流程結束後兩者都已解除（截圖自行收尾、錄影已中止）。
    private func reshootRecordToScreenshot() {
        guard recordSession.isActive, !captureInFlight else { return }
        captureInFlight = true
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
        Task { @MainActor in
            defer { self.captureInFlight = false }
            do {
                let snapshots = try await capturer.captureAllDisplays(showsCursor: true)   // 含工具
                recordSession.abortIfActive()          // 中止錄影（dismiss overlay+HUD、還原快鍵走 onFinished .cancelled）
                presentCaptureOverlay(snapshots: snapshots, vars: vars)
            } catch CaptureError.noPermission {
                recordSession.abortIfActive()
                showPermissionAlert()
            } catch {
                recordSession.abortIfActive()
                NSLog("anypaint: 錄影轉截圖擷取失敗 \(error)")
                NSSound.beep()
            }
        }
    }

    /// 重拍：對現在的實況畫面（overlay 正顯示中）重新凍結，把截圖工具本身也拍進去，
    /// 再用新快照換掉舊 overlay。showsCursor: true 讓十字游標也入鏡。
    private func reshootOverlay() {
        guard overlayController.isActive else { return }
        Task { @MainActor in
            do {
                let snapshots = try await capturer.captureAllDisplays(showsCursor: true)
                overlayController.reshoot(with: snapshots)
            } catch {
                NSLog("anypaint: 重拍擷取失敗 \(error)")
                NSSound.beep()
                overlayController.reshootFailed()   // 解旗標，R 還能再按
            }
        }
    }

    // MARK: - 框選 OCR：辨識文字／QR → 複製 → 結果窗

    /// 一步到位（Shottr 同款）：辨識完**直接進剪貼簿**，同時開結果窗讓使用者檢視、
    /// 選取局部或重新複製。原本要 OCR 一段螢幕文字得走「截圖 → 貼成浮動圖 → ⇧右鍵」三步。
    ///
    /// 結果窗一個就好（重用）：overlay 已經 dismiss，不會有兩個框選同時在辨識。
    /// `ocrInFlight` 仍要擋——上一次的辨識可能還沒回來就又按了一次（比照 PinWindowController）。
    private func recognizeText(in image: NSImage, near anchor: CGRect) {
        guard !ocrInFlight else { return }
        let controller = ocrController ?? OCRResultWindowController()
        ocrController = controller
        controller.present(besideGlobalRect: anchor)
        controller.showText("辨識中…")

        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            controller.showText("無法讀取影像")
            return
        }
        ocrInFlight = true
        TextRecognizer.recognizeContent(cgImage: cg) { [weak self] result in
            self?.ocrInFlight = false
            switch result {
            case .success(.empty):
                controller.showText("未偵測到文字或 QR 碼")
            case .success(let recognition):
                let text = recognition.joined
                self?.pinboard.copy(text: text)
                controller.showText(text)
            case .failure(let error):
                controller.showText("辨識失敗：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 貼圖：讀剪貼簿 → 置頂浮動視窗

    private func pinFromClipboard() {
        guard !scrollSession.isActive else { return }   // 滾動中不疊貼圖（spec §9.1）
        guard !recordSession.isActive else { return }   // 動畫截圖中不疊貼圖（spec §9.1）
        guard let image = pinboard.imageFromPasteboard() else {
            NSSound.beep()
            return
        }
        pinController.pin(image: image, at: NSEvent.mouseLocation)
    }

    // MARK: - 滾動截圖：拉框 → 手捲拼接 → 預覽

    private func beginScrollCapture() {
        switch activeMode {
        case .scroll: scrollSession.cancelIfActive(); return   // 再按 = 取消（保證退出，spec §6）
        case .freeze: return                                    // 凍結框選中 → 不疊加
        case .record: return                                    // 動畫截圖中 → 不疊加（spec §9.1）
        case .none: break
        }
        KeyboardShortcuts.disable(.capture, .pin)               // 滾動中擋另外兩入口（spec §9.1）
        menuBar.setScrollCapturing(true)
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
        scrollSession.onFinished = { [weak self] image, captureScale in
            guard let self else { return }
            KeyboardShortcuts.enable(.capture, .pin)            // 恢復點集中在單一出口（spec §9.1）
            self.menuBar.setScrollCapturing(false)
            guard let image else { return }                     // 取消或 0 格 → 靜默（spec §3）
            if self.previewController == nil {
                self.previewController = ScrollPreviewWindowController(output: self.output, pinboard: self.pinboard)
            }
            // scale 必須用擷取端那顆螢幕的值（混合 DPI 多螢幕下與滑鼠所在螢幕可能不同）。
            self.previewController?.present(image: image, vars: vars, captureScale: captureScale)
        }
        scrollSession.begin()
        // begin() 在無主螢幕時會靜默 no-op（onFinished 永不 fire）——
        // 若沒真的進場就立刻把剛 disable 的快鍵/選單恢復，否則 .capture/.pin 永久失效需重啟。
        guard scrollSession.isActive else {
            KeyboardShortcuts.enable(.capture, .pin)
            menuBar.setScrollCapturing(false)
            return
        }
    }

    // MARK: - 動畫截圖：拉框 → 錄製 → 預覽

    /// - Parameter rect: 非 nil＝RPC 自動化路徑（`UITestServer` `startRecord` 命令），跳過拉框互動，
    ///   直接以此全域矩形進入 armed 並開始錄製（`RecordSession.startProgrammatically`）；
    ///   nil＝熱鍵／選單路徑，走既有拉框流程（`RecordSession.begin`）。除了選區來源，
    ///   權限預檢、快鍵互斥、`onFinished` 收尾全部共用同一段，不重複兩份。
    /// 動畫截圖（截圖式,停止後開預覽匯出）＝`beginRecord(direct: false)`。
    private func beginAnimatedCapture(rect: CGRect? = nil) { beginRecord(direct: false, rect: rect) }
    /// 錄影（直接落地存 MP4,停止後不開預覽）＝`beginRecord(direct: true)`。
    private func beginRecordDirect(rect: CGRect? = nil) { beginRecord(direct: true, rect: rect) }

    /// 錄影統一入口。`direct=false`＝動畫截圖(收尾開預覽)；`direct=true`＝錄影(收尾直接存 MP4)。
    /// 兩者共用 SCStream→WriterBox 底層,只在**收尾**分叉（spec §6：共用底層、收尾分叉）。
    /// - Parameter autoStart: 有 `rect` 時，`true`＝RPC 自動化（直接錄，`startProgrammatically`）；
    ///   `false`＝↺ 重錄（重入 armed 讓使用者再按開始，`startArmed`——對抗式審查 #5）。無 `rect` 時無意義。
    private func beginRecord(direct: Bool, rect: CGRect? = nil, autoStart: Bool = true) {
        switch activeMode {
        case .record: recordSession.cancelIfActive(); return   // 再按＝armed 取消／recording 停止收檔
        case .freeze, .scroll: return                            // 凍結／滾動中 → 不疊加
        case .none: break
        }
        // 螢幕錄製權限預檢（已查 header：preflight 不彈框；request 首次會彈系統框）。
        guard CGPreflightScreenCaptureAccess() else {
            if !CGRequestScreenCaptureAccess() { showPermissionAlert() }
            return
        }
        // 錄製中擋其他入口（spec §9.1）：連另一種錄影模式的快鍵也一起 disable,避免兩模式互撞。
        let others: [KeyboardShortcuts.Name] = direct
            ? [.capture, .pin, .scrollCapture, .animatedCapture]
            : [.capture, .pin, .scrollCapture, .record]
        KeyboardShortcuts.disable(others)
        setRecordingMenu(direct: direct, on: true)
        // %title% 於按下快鍵當下凍結（spec，同 beginScrollCapture 理由）。
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
        recordSession.onFinished = { [weak self] outcome, captureScale in
            guard let self else { return }
            KeyboardShortcuts.enable(others)                     // 對抗式審查 #1：單一還原出口（不分成敗）
            self.setRecordingMenu(direct: direct, on: false)
            // 分類＋（錄影成功時）先搬檔到最終位置——拿 finalURL 才 morph（對抗式審查 #2）。
            let category: RecordFinishRouter.Category
            var savedFinalURL: URL?      // 錄影成功搬檔後的最終路徑
            var previewURL: URL?         // 動畫截圖用的暫存母帶
            switch outcome {
            case .cancelled: category = .cancelled
            case .failed:    category = .failed
            case .saved(let tempURL):
                category = .saved
                if direct {
                    savedFinalURL = self.recordOutput.saveMovie(from: tempURL, vars: vars)
                    try? FileManager.default.removeItem(at: tempURL)   // 已複製到最終位置,清暫存
                } else {
                    previewURL = tempURL
                }
            }
            // 終端動作決策（純邏輯 RecordFinishRouter，可測）。
            switch RecordFinishRouter.action(category: category, direct: direct,
                                             saveSucceeded: savedFinalURL != nil) {
            case .none:
                break                                            // 取消：HUD 已完整 dismiss
            case .dismissOnly:
                self.recordSession.dismissHUD()                  // 動畫截圖失敗：收 HUD
            case .presentDoneFailed:
                let reason = (category == .saved) ? "存檔失敗，請檢查磁碟空間或存檔資料夾" : "錄製失敗，未產生檔案"
                self.recordSession.presentDoneFailed(detail: reason, saveDirectory: self.recordSaveDirectoryURL())
                UITestServer.shared?.emit("captureFailed", ["reason": category == .saved ? "recordSave" : "recordFinish"])
            case .presentDone:
                let saved = savedFinalURL!
                let bytes = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int64) ?? nil
                self.recordSession.presentDone(finalURL: saved, sizeBytes: bytes ?? 0,
                                               saveDirectory: saved.deletingLastPathComponent())
                UITestServer.shared?.emit("recordSaved", ["path": saved.path])   // 自動化可 wait-event
            case .openPreview:
                self.recordSession.dismissHUD()                  // 動畫截圖：收 HUD,改開預覽
                if self.recordPreviewController == nil {
                    self.recordPreviewController = RecordPreviewWindowController(output: self.recordOutput,
                                                                                  pinboard: self.pinboard)
                }
                let movieURL = previewURL!
                Task { @MainActor in
                    await self.recordPreviewController?.present(movieURL: movieURL, vars: vars, captureScale: captureScale)
                }
            }
        }
        if let rect {
            if autoStart { recordSession.startProgrammatically(rect: rect) }   // RPC 自動化
            else { recordSession.startArmed(rect: rect) }                      // ↺ 重錄
        } else { recordSession.begin() }
        // begin()／startProgrammatically() 在無主螢幕時會靜默 no-op（onFinished 永不 fire）——
        // 若沒真的進場就立刻把剛 disable 的快鍵/選單恢復，否則其餘入口永久失效需重啟。
        guard recordSession.isActive else {
            KeyboardShortcuts.enable(others)
            setRecordingMenu(direct: direct, on: false)
            return
        }
    }

    /// 目前設定的錄影存檔目錄 URL（完成面板失敗態「開啟存檔資料夾」用）。
    private func recordSaveDirectoryURL() -> URL {
        URL(fileURLWithPath: RecordOutputService.saveDirectoryPath(
            saveDirectory: AppSettings.recordSaveDirectory, home: NSHomeDirectory()), isDirectory: true)
    }

    /// 依模式切正確的選單項標題（動畫截圖／錄影 各自的「停止…」）。
    private func setRecordingMenu(direct: Bool, on: Bool) {
        if direct { menuBar.setRecordingDirect(on) } else { menuBar.setRecording(on) }
    }

    // MARK: - 設定

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - RPC 自動化（`--uitest`／`AppSettings.allowLocalAutomation` 才會有 `UITestServer.shared`；
    // 正常啟動這個方法永遠不會被呼叫——見 `UITestServer.startIfRequested()`）。

    /// `UITestServer.commandHandler` 的接線出口。回 `nil`＝「不是我認的命令」，讓
    /// `UITestServer.handle` 照原邏輯走 `unknownCommand`（見該檔案 default 分支）。
    private func handleUITestCommand(_ command: UITestChannel.Command) -> [String: Any]? {
        switch command.cmd {
        case "startRecord":
            // 不是 toggle：已有 session 在跑時 beginAnimatedCapture 會走 cancelIfActive 分支
            // （錄製中再按＝停止收檔），那不是「開始」語意——這裡要明確拒絕，不能讓呼叫端
            // 以為自己開了一個新錄製卻其實把舊的停掉了（review fix round 1 Important 3）。
            guard !recordSession.isActive else { return ["ok": false, "error": "busy"] }
            guard let rectStr = command.json["rect"] as? String,
                  let rect = CoordinateUtils.parseRect(rectStr) else {
                return ["ok": false, "error": "badRect"]
            }
            // RPC 路徑絕不能落進互動式權限流程：`beginAnimatedCapture` 首次無權限時會呼叫
            // `CGRequestScreenCaptureAccess()` 彈系統框，那個呼叫在 CFMessagePort callback
            // （主執行緒）上 runModal，會卡死整條 RPC 通道（呼叫端等回覆、回覆等系統框，
            // 系統框又要等使用者互動——RPC 呼叫端沒有滑鼠可以按）。這裡先問过一次、沒有就直接
            // 回錯，不進 `beginAnimatedCapture`。
            guard CGPreflightScreenCaptureAccess() else {
                return ["ok": false, "error": "noScreenRecordingPermission"]
            }
            // direct:true＝錄影（直接落地存 MP4，完成發 recordSaved 事件）；否則動畫截圖（開預覽）。
            // arm:true＝只進待命（不 auto-start，走 startArmed）：讓自動化設好選項/看 armed 二層工具列，
            // 之後由使用者按開始或 abortRecord 收掉。與 direct 正交。
            let arm = command.json["arm"] as? Bool ?? false
            beginRecord(direct: command.json["direct"] as? Bool ?? false, rect: rect, autoStart: !arm)
            // beginRecord 全程同步：呼叫回來後 state 已經是最終結果，不必等回呼。
            switch recordSession.state {
            case .recording:
                return ["ok": true]
            case .armed where arm:
                return ["ok": true, "state": "armed"]   // arm 模式停在待命＝成功
            case .selecting:
                // enterArmed 選區太小時早退，state 停在 .selecting（不是 .armed——早退分支
                // 完全沒碰 state，見 RecordSession.startProgrammatically 的註解）。
                return ["ok": false, "error": "selectionTooSmall"]
            default:
                // 其餘（.idle）＝矩形超出螢幕邊界（presentLocked 擋掉）或找不到目標螢幕。
                return ["ok": false, "error": "badRect"]
            }
        case "stopRecord":
            // 精準化（比照 startRecord／abortRecord）：只有真的在 recording 中才算「成功停止」。
            // selecting/armed 下呼叫 cancelIfActive() 會被解讀成使用者按了取消（發
            // recordingAborted、丟棄選區），那不是 stopRecord 的語意——呼叫端明確表達「結束並
            // 保留母帶」，不該在還沒開始錄製時被誤當成取消。因此不在這裡呼叫 cancelIfActive，
            // 直接回報目前 state 讓呼叫端自己判斷。
            guard recordSession.state == .recording else {
                return ["ok": false, "state": "\(recordSession.state)"]
            }
            recordSession.cancelIfActive()   // 走與熱鍵相同入口：recording 中＝停止並保留母帶
            return ["ok": true]
        case "abortRecord":
            recordSession.abortIfActive()    // 不論哪個 active 狀態都丟棄（同 Esc／取消鈕）
            // `.finishing` 不接受取消（刻意保留的紀律，見 RecordSession.cancel 的註解）——
            // abortIfActive 對它是 no-op，回值要老實反映「其實沒中止掉」，不能報 ok:true
            // 卻讓呼叫端以為母帶已經丟棄（review fix round 1 Important 5）。
            return ["ok": !recordSession.isActive, "state": "\(recordSession.state)"]
        case "openSettings":
            openSettings()
            return ["ok": true]
        case "micDevices":
            let devices = AudioInputDeviceList.all().map {
                ["uniqueID": $0.uniqueID, "name": $0.name, "isDefault": $0.isDefault] as [String: Any]
            }
            // `?? NSNull()`：`JSONSerialization` 不接受裸 `Optional<String>.none` 當 Any 值
            // （不在它認得的型別清單內，會讓整個 `withJSONObject:` 呼叫失敗，見
            // `UITestServer.reply` 的 `try?` 吞掉錯誤退化成空 `Data()`）——nil 必須顯式包成
            // `NSNull()` 才序列化得出來。
            return ["ok": true, "devices": devices,
                    "systemDefaultID": AudioInputDeviceList.systemDefaultID() ?? NSNull()]
        case "micProbeStart":
            // 省略 "deviceID"（或傳空字串）＝系統預設，同 `MicLevelMonitor.start(deviceID:)`
            // 對 nil 的既有語意。
            let deviceID = command.json["deviceID"] as? String
            micProbeMonitor.start(deviceID: (deviceID?.isEmpty == true) ? nil : deviceID)
            // 附上目前的麥克風授權狀態：`MicLevelMonitor.start()` 未授權時是**靜默不啟動**
            // （`latestLevel` 恆 0、不 crash，見該檔案註解），呼叫端光看 `{"ok":true}` 分辨不出
            // 「已啟動只是還沒收到聲音」與「未授權所以根本沒起 session」——端到端煙霧測試
            // 實測就撞過這個模糊地帶（task-A7-report），這裡直接把狀態攤開，不用呼叫端自己猜。
            let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            return ["ok": true, "authorized": authorized]
        case "micLevel":
            return ["ok": true, "level": micProbeMonitor.latestLevel]
        case "micProbeStop":
            micProbeMonitor.stop()
            return ["ok": true]
        case "captureRegion":
            // 非互動選區截圖：擷取→裁切→複製剪貼簿(可選存檔)，非同步,完成發 captureCompleted 事件。
            guard let rectStr = command.json["rect"] as? String,
                  let rect = CoordinateUtils.parseRect(rectStr) else { return ["ok": false, "error": "badRect"] }
            guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "error": "noScreenRecordingPermission"] }
            captureRegionRPC(rect, save: command.json["save"] as? Bool ?? false)
            return ["ok": true]
        case "recognizeText":
            // 非互動選區 OCR：擷取→裁切→辨識,非同步,完成發 textRecognized 事件。
            guard let rectStr = command.json["rect"] as? String,
                  let rect = CoordinateUtils.parseRect(rectStr) else { return ["ok": false, "error": "badRect"] }
            guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "error": "noScreenRecordingPermission"] }
            recognizeTextRPC(rect)
            return ["ok": true]
        case "pinClipboard":
            // 貼剪貼簿圖成浮窗（同步：不需擷取螢幕）。滾動/錄影中拒絕（不疊加,spec §9.1）。
            guard !scrollSession.isActive, !recordSession.isActive else { return ["ok": false, "error": "busy"] }
            guard let image = pinboard.imageFromPasteboard() else { return ["ok": false, "error": "noImage"] }
            pinController.pin(image: image, at: NSEvent.mouseLocation)
            return ["ok": true]
        default:
            return nil
        }
    }

    /// 非互動選區截圖（RPC）：擷取所有螢幕→用 `AutomationCapture.cropPlan` 定位並裁切→複製剪貼簿
    /// （可選存檔）→發 `captureCompleted`/`captureFailed` 事件。async(擷取只有 async API),故走事件。
    private func captureRegionRPC(_ globalRect: CGRect, save: Bool) {
        Task { @MainActor in
            guard let cropped = await self.captureCropped(globalRect) else {
                UITestServer.shared?.emit("captureFailed", ["reason": "captureOrCrop"]); return
            }
            let pointSize = CoordinateUtils.pointSize(pixelWidth: cropped.width, pixelHeight: cropped.height,
                                                      scale: self.captureScale(for: globalRect))
            let image = NSImage(cgImage: cropped, size: pointSize)
            self.pinboard.copy(image: image)
            var payload: [String: Any] = ["copied": true]
            let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
            if save, let url = self.output.saveExpanding(template: AppSettings.quickSavePathTemplate,
                                                         image: image, vars: vars, quiet: true) {
                payload["path"] = url.path
            }
            UITestServer.shared?.emit("captureCompleted", payload)
        }
    }

    /// 非互動選區 OCR（RPC）：擷取→裁切→`TextRecognizer.recognizeContentSync`→發 `textRecognized`
    /// （文字進剪貼簿,同互動版）/`captureFailed`。
    private func recognizeTextRPC(_ globalRect: CGRect) {
        Task { @MainActor in
            guard let cropped = await self.captureCropped(globalRect) else {
                UITestServer.shared?.emit("captureFailed", ["reason": "captureOrCrop"]); return
            }
            do {
                let text = (try TextRecognizer.recognizeContentSync(cgImage: cropped)).joined
                self.pinboard.copy(text: text)
                UITestServer.shared?.emit("textRecognized", ["text": text])
            } catch {
                UITestServer.shared?.emit("captureFailed", ["reason": "ocr: \(error)"])
            }
        }
    }

    /// 共用：擷取所有螢幕、依 cropPlan 裁出選區的 CGImage（左上原點像素）；任一步失敗回 nil。
    private func captureCropped(_ globalRect: CGRect) async -> CGImage? {
        guard let snapshots = try? await capturer.captureAllDisplays() else { return nil }
        let geoms = snapshots.map {
            AutomationCapture.DisplayGeometry(frameGlobal: $0.frameGlobal, pointSize: $0.pointSize, scale: $0.scale)
        }
        guard let plan = AutomationCapture.cropPlan(globalRect: globalRect, displays: geoms) else { return nil }
        return snapshots[plan.index].cgImage.cropping(to: plan.pixelCrop)
    }

    /// 選區所在螢幕的 pixel scale（找不到＝主螢幕 backingScaleFactor 或 2）。
    private func captureScale(for globalRect: CGRect) -> CGFloat {
        NSScreen.screens.first { $0.frame.contains(globalRect) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 解析 `"x,y,w,h"`（AppKit 全域座標，點）。四段都要是合法數字，否則回 nil。
    // MARK: - 權限

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要螢幕錄製權限"
        alert.informativeText = "請到「系統設定 → 隱私權與安全性 → 螢幕錄製」允許 anypaint，然後再按一次截圖快鍵。"
        alert.addButton(withTitle: "開啟系統設定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturer.openScreenRecordingSettings()
        }
    }
}
