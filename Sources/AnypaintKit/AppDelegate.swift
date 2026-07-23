import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

/// 應用協調者：組裝各模組、註冊快鍵、串起截圖與貼圖流程。
/// 自己不做底層細節，只負責「誰在什麼時候呼叫誰」。
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let capturer = ScreenCapturer()
    private let pinboard = PinboardService()
    private let pinController = PinWindowController()

    // 單一持久的 overlay 協調者（不再每次 new，避免造出沒人管的孤兒視窗）。
    private let overlayController = SelectionOverlayController()
    // 同步防重入旗標：擷取是 async，這個旗標在按下當下就設，擋住連按空窗期。
    private var captureInFlight = false

    private var settingsWindowController: SettingsWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 選單列動作
        menuBar.onCapture = { [weak self] in self?.beginCapture() }
        menuBar.onPin = { [weak self] in self?.pinFromClipboard() }
        menuBar.onCloseAllPins = { [weak self] in self?.pinController.closeAll() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }

        // 全域快鍵（可在設定頁更改；底層為 Carbon，免輔助使用權限）
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in self?.beginCapture() }
        KeyboardShortcuts.onKeyDown(for: .pin) { [weak self] in self?.pinFromClipboard() }
    }

    // MARK: - 截圖：凍結 → 框選 → 複製到剪貼簿

    private func beginCapture() {
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
                        self?.autoSaveIfEnabled(image: image, vars: vars)
                    },
                    onSave: { [weak self] image in
                        self?.pinboard.copy(image: image)   // 剪貼簿先有——寫檔失敗也不白截（spec）
                        self?.saveExpanding(template: AppSettings.quickSavePathTemplate,
                                            image: image, vars: vars, quiet: false)
                        self?.autoSaveIfEnabled(image: image, vars: vars)
                    },
                    onSaveAs: { [weak self] image in
                        self?.pinboard.copy(image: image)   // 對話框取消也不白截（spec）
                        self?.saveWithPanel(image: image, vars: vars)
                        self?.autoSaveIfEnabled(image: image, vars: vars)
                    },
                    onPin: { [weak self] image, frame in
                        self?.pinboard.copy(image: image)                    // 決策：貼＝同時複製
                        self?.pinController.pin(image: image, frame: frame)
                        self?.autoSaveIfEnabled(image: image, vars: vars)
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

    /// 展開路徑樣板 → 補 .png → 檔名 fallback → 相對路徑補家目錄 → 碰撞遞增 → 寫檔 → 通知。
    /// quiet：自動儲存失敗不 beep（背景行為不打擾，spec）。
    private func saveExpanding(template: String, image: NSImage,
                               vars: [String: String], quiet: Bool) {
        let now = Date()
        var expanded = FilenameTemplate.ensuringPNGExtension(
            FilenameTemplate.expand(template, date: now, vars: vars))
        let fallback = FilenameTemplate.expand(FilenameTemplate.defaultName, date: now, vars: vars)
        expanded = FilenameTemplate.ensuringMeaningfulFilename(expanded, fallbackName: fallback)
        var path = (expanded as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = NSHomeDirectory() + "/" + path }   // cwd 不可靠（launchd 啟動＝/）
        let target = URL(fileURLWithPath: path)
        let url = CaptureSaver.uniquedURL(
            directory: target.deletingLastPathComponent(),
            filename: target.lastPathComponent,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            try CaptureSaver.writePNG(image: image, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent)
            }
        } catch {
            NSLog("anypaint: 存檔失敗 \(error)")
            if !quiet { NSSound.beep() }
        }
    }

    /// 自動儲存（spec：預設關；掛全部四條完成鏈）。
    private func autoSaveIfEnabled(image: NSImage, vars: [String: String]) {
        guard AppSettings.autoSaveEnabled else { return }
        saveExpanding(template: AppSettings.autoSavePathTemplate,
                      image: image, vars: vars, quiet: true)
    }

    /// 另存為：彈 NSSavePanel 自選位置與檔名（覆寫確認交給面板，不套 uniquedURL）。
    /// 預設檔名＝manualNameTemplate 展開；起始目錄＝快速儲存路徑樣板的目錄段。
    /// 另存為不發通知——使用者親自選了位置，看得到結果（spec 只涵蓋快速/自動）。
    private func saveWithPanel(image: NSImage, vars: [String: String]) {
        let now = Date()
        var name = FilenameTemplate.ensuringPNGExtension(
            FilenameTemplate.expand(AppSettings.manualNameTemplate, date: now, vars: vars))
        name = name.replacingOccurrences(of: "/", with: "-")   // 檔名欄不接受目錄
        name = FilenameTemplate.ensuringMeaningfulFilename(
            name,
            fallbackName: FilenameTemplate.expand(FilenameTemplate.defaultName,
                                                  date: now, vars: vars))
        let quickExpanded = FilenameTemplate.expand(AppSettings.quickSavePathTemplate,
                                                    date: now, vars: vars)
        let startDir = URL(fileURLWithPath: (quickExpanded as NSString).expandingTildeInPath)
            .deletingLastPathComponent()

        let panel = NSSavePanel()
        panel.title = "圖像另存為"
        panel.nameFieldStringValue = name
        panel.directoryURL = startDir
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 面板不會成 key
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CaptureSaver.writePNG(image: image, to: url)
        } catch {
            NSLog("anypaint: 另存失敗 \(error)")
            NSSound.beep()
        }
    }

    // MARK: - 貼圖：讀剪貼簿 → 置頂浮動視窗

    private func pinFromClipboard() {
        guard let image = pinboard.imageFromPasteboard() else {
            NSSound.beep()
            return
        }
        pinController.pin(image: image, at: NSEvent.mouseLocation)
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
