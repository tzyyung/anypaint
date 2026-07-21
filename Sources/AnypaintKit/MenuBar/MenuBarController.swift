import AppKit

/// 選單列（NSStatusItem）入口。單一職責：呈現選單並把使用者動作轉成回呼。
/// 不知道「截圖/貼圖怎麼做」，只負責觸發。
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem

    /// 使用者點「截圖」時呼叫。
    var onCapture: (() -> Void)?
    /// 使用者點「貼圖」時呼叫。
    var onPin: (() -> Void)?
    /// 關閉所有貼圖。
    var onCloseAllPins: (() -> Void)?
    /// 開啟設定頁。
    var onOpenSettings: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // 記住使用者用 ⌘ 拖曳排好的位置（例如拖出瀏海後），下次啟動沿用。
        // 註：macOS 無 API 讓 app 主動避開瀏海，只能靠這個持久化使用者的排列。
        statusItem.autosaveName = "anypaint.statusitem"

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scissors",
                                   accessibilityDescription: "anypaint")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        addItem(to: menu, title: "截圖", action: #selector(captureAction))
        addItem(to: menu, title: "貼圖", action: #selector(pinAction))
        menu.addItem(.separator())
        addItem(to: menu, title: "關閉所有貼圖", action: #selector(closeAllPinsAction))
        menu.addItem(.separator())
        addItem(to: menu, title: "設定…", action: #selector(openSettingsAction))
        addItem(to: menu, title: "離開 anypaint", action: #selector(quitAction))
        statusItem.menu = menu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func captureAction() { onCapture?() }
    @objc private func pinAction() { onPin?() }
    @objc private func closeAllPinsAction() { onCloseAllPins?() }
    @objc private func openSettingsAction() { onOpenSettings?() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
