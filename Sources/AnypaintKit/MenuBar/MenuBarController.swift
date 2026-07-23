import AppKit
import KeyboardShortcuts

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
        addItem(to: menu, title: "截圖", action: #selector(captureAction), shortcut: .capture)
        addItem(to: menu, title: "貼圖", action: #selector(pinAction), shortcut: .pin)
        menu.addItem(.separator())
        addItem(to: menu, title: "關閉所有貼圖", action: #selector(closeAllPinsAction))
        menu.addItem(.separator())
        addItem(to: menu, title: "設定…", action: #selector(openSettingsAction))
        addItem(to: menu, title: "離開 anypaint", action: #selector(quitAction))
        menu.delegate = self   // 選單開闔時停/啟全域快鍵（見下方 NSMenuDelegate）
        statusItem.menu = menu
    }

    /// shortcut 非 nil 時用 KeyboardShortcuts.setShortcut 顯示快鍵，
    /// 使用者在設定頁改鍵會自動同步到選單。
    private func addItem(to menu: NSMenu, title: String, action: Selector,
                         shortcut: KeyboardShortcuts.Name? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut { item.setShortcut(for: shortcut) }
        menu.addItem(item)
    }

    @objc private func captureAction() { onCapture?() }
    @objc private func pinAction() { onPin?() }
    @objc private func closeAllPinsAction() { onCloseAllPins?() }
    @objc private func openSettingsAction() { onOpenSettings?() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

// NSMenu 打開時 thread 進 tracking mode，全域快鍵事件會被 buffer、
// 關選單時才一次爆發——KeyboardShortcuts 官方要求開選單時停用、關閉時恢復。
extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(.capture, .pin)
    }
    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(.capture, .pin)
    }
}
