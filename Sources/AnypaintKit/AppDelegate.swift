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

    private var settingsWindowController: SettingsWindowController?

    /// 三入口互斥（spec §9.1）：任一 capture mode active 時其他入口 guard-return。
    /// preview 不佔 mode（session 已結束，開著可以再截）。
    private enum ActiveMode { case none, freeze, scroll }
    private var activeMode: ActiveMode {
        if overlayController.isActive || captureInFlight { return .freeze }
        if scrollSession.isActive { return .scroll }
        return .none
    }

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 選單列動作
        menuBar.onCapture = { [weak self] in self?.beginCapture() }
        menuBar.onPin = { [weak self] in self?.pinFromClipboard() }
        menuBar.onScrollCapture = { [weak self] in self?.beginScrollCapture() }
        menuBar.onCloseAllPins = { [weak self] in self?.pinController.closeAll() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }

        // 全域快鍵（可在設定頁更改；底層為 Carbon，免輔助使用權限）
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in self?.beginCapture() }
        KeyboardShortcuts.onKeyDown(for: .pin) { [weak self] in self?.pinFromClipboard() }
        KeyboardShortcuts.onKeyDown(for: .scrollCapture) { [weak self] in self?.beginScrollCapture() }
    }

    // MARK: - 截圖：凍結 → 框選 → 複製到剪貼簿

    private func beginCapture() {
        guard !scrollSession.isActive else { return }   // 滾動中不疊凍結（spec §9.1）
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

    // MARK: - 貼圖：讀剪貼簿 → 置頂浮動視窗

    private func pinFromClipboard() {
        guard !scrollSession.isActive else { return }   // 滾動中不疊貼圖（spec §9.1）
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
        case .none: break
        }
        KeyboardShortcuts.disable(.capture, .pin)               // 滾動中擋另外兩入口（spec §9.1）
        menuBar.setScrollCapturing(true)
        let vars = CaptureVars.makeVars(title: CaptureVars.currentFrontTitle())
        scrollSession.onFinished = { [weak self] image in
            guard let self else { return }
            KeyboardShortcuts.enable(.capture, .pin)            // 恢復點集中在單一出口（spec §9.1）
            self.menuBar.setScrollCapturing(false)
            guard let image else { return }                     // 取消或 0 格 → 靜默（spec §3）
            if self.previewController == nil {
                self.previewController = ScrollPreviewWindowController(output: self.output, pinboard: self.pinboard)
            }
            self.previewController?.present(image: image, vars: vars)
        }
        scrollSession.begin()
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
