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

        Task { @MainActor in
            defer { self.captureInFlight = false }
            do {
                let snapshots = try await capturer.captureAllDisplays()
                overlayController.present(
                    snapshots: snapshots,
                    onSelect: { [weak self] image in self?.pinboard.copy(image: image) },
                    onSave: { [weak self] image in
                        self?.pinboard.copy(image: image)   // 剪貼簿先有——寫檔失敗也不白截（spec）
                        let dir = URL(fileURLWithPath: AppSettings.saveDirectoryPath)
                        let url = CaptureSaver.uniquedURL(
                            directory: dir,
                            filename: CaptureSaver.filename(for: Date()),
                            exists: { FileManager.default.fileExists(atPath: $0.path) })
                        do {
                            try CaptureSaver.writePNG(image: image, to: url)
                        } catch {
                            NSLog("anypaint: 存檔失敗 \(error)")
                            NSSound.beep()
                        }
                    },
                    onSaveAs: { [weak self] image in
                        self?.pinboard.copy(image: image)   // 對話框取消也不白截（spec）
                        self?.saveWithPanel(image: image)
                    },
                    onPin: { [weak self] image, frame in
                        self?.pinboard.copy(image: image)                    // 決策：貼＝同時複製
                        self?.pinController.pin(image: image, frame: frame)
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

    /// 另存為：彈 NSSavePanel 自選位置與檔名（覆寫確認交給面板，不套 uniquedURL）。
    private func saveWithPanel(image: NSImage) {
        let panel = NSSavePanel()
        panel.title = "圖像另存為"
        panel.nameFieldStringValue = CaptureSaver.filename(for: Date())
        panel.directoryURL = URL(fileURLWithPath: AppSettings.saveDirectoryPath)
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
