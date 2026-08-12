import AppKit
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
            guard let rectStr = command.json["rect"] as? String,
                  let rect = Self.parseRect(rectStr) else {
                return ["ok": false, "error": "badRect"]
            }
            beginAnimatedCapture(rect: rect)
            return ["ok": recordSession.isActive]
        case "stopRecord":
            recordSession.cancelIfActive()   // 走與熱鍵相同入口：recording 中＝停止並保留母帶
            return ["ok": true]
        case "abortRecord":
            recordSession.abortIfActive()    // 不論哪個 active 狀態都丟棄（同 Esc／取消鈕）
            return ["ok": true]
        case "openSettings":
            openSettings()
            return ["ok": true]
        default:
            return nil
        }
    }

    /// 解析 `"x,y,w,h"`（AppKit 全域座標，點）。四段都要是合法數字，否則回 nil。
    private static func parseRect(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

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
