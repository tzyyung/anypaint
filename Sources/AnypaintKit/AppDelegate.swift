import AppKit
import AVFoundation
import KeyboardShortcuts
import UniformTypeIdentifiers

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
    private enum ActiveMode { case none, freeze, scroll, record }
    private var activeMode: ActiveMode {
        if overlayController.isActive || captureInFlight { return .freeze }
        if scrollSession.isActive { return .scroll }
        if recordSession.isActive { return .record }
        return .none
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
        menuBar.onCloseAllPins = { [weak self] in self?.pinController.closeAll() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }

        // 重拍（overlay 中按 R）：對現在的實況畫面重新凍結（含工具本身），換掉舊 overlay。
        // 沿用 present() 已存的處理器閉包（含原始 vars），故這裡只需擷取＋換場。
        overlayController.onReshoot = { [weak self] in self?.reshootOverlay() }

        // 全域快鍵（可在設定頁更改；底層為 Carbon，免輔助使用權限）
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in self?.beginCapture() }
        KeyboardShortcuts.onKeyDown(for: .pin) { [weak self] in self?.pinFromClipboard() }
        KeyboardShortcuts.onKeyDown(for: .scrollCapture) { [weak self] in self?.beginScrollCapture() }
        KeyboardShortcuts.onKeyDown(for: .animatedCapture) { [weak self] in self?.beginAnimatedCapture() }
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
            } catch CaptureError.noPermission {
                showPermissionAlert()
            } catch {
                NSLog("anypaint: 擷取失敗 \(error)")
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
    private func beginAnimatedCapture(rect: CGRect? = nil) {
        switch activeMode {
        case .record: recordSession.cancelIfActive(); return   // 再按＝armed 取消／recording 停止收檔
        case .freeze, .scroll: return                            // 凍結／滾動中 → 不疊加
        case .none: break
        }
        // 螢幕錄製權限預檢（已查 header：preflight 不彈框；request 首次會彈系統框）。
        // request 成功＝使用者剛允許——macOS 授權後常需重啟 app 才生效，因此一律 return 讓使用者重按，
        // 不直接續跑（續跑會拿到黑畫面 stream）。alert 文案沿用既有 showPermissionAlert。
        guard CGPreflightScreenCaptureAccess() else {
            if !CGRequestScreenCaptureAccess() { showPermissionAlert() }
            return
        }
        KeyboardShortcuts.disable(.capture, .pin, .scrollCapture)   // 錄製中擋其他三入口（spec §9.1）
        menuBar.setRecording(true)
        // %title% 於按下快鍵當下凍結（spec，同 beginScrollCapture 理由）。
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
        recordSession.onFinished = { [weak self] url, captureScale in
            guard let self else { return }
            KeyboardShortcuts.enable(.capture, .pin, .scrollCapture)   // 恢復點集中在單一出口
            self.menuBar.setRecording(false)
            guard let url else { return }                              // 取消或失敗 → 靜默（同 scroll 慣例）
            if self.recordPreviewController == nil {
                self.recordPreviewController = RecordPreviewWindowController(output: self.recordOutput,
                                                                              pinboard: self.pinboard)
            }
            Task { @MainActor in
                // present(movieURL:vars:captureScale:) 是 async（需先讀母帶 naturalSize）。
                await self.recordPreviewController?.present(movieURL: url, vars: vars, captureScale: captureScale)
            }
        }
        if let rect { recordSession.startProgrammatically(rect: rect) } else { recordSession.begin() }
        // begin()／startProgrammatically() 在無主螢幕時會靜默 no-op（onFinished 永不 fire）——
        // 若沒真的進場就立刻把剛 disable 的快鍵/選單恢復，否則其餘三入口永久失效需重啟。
        guard recordSession.isActive else {
            KeyboardShortcuts.enable(.capture, .pin, .scrollCapture)
            menuBar.setRecording(false)
            return
        }
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
            beginAnimatedCapture(rect: rect)
            // beginAnimatedCapture 全程同步：呼叫回來後 state 已經是最終結果，不必等回呼。
            switch recordSession.state {
            case .recording:
                return ["ok": true]
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
        default:
            return nil
        }
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
