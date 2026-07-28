import AppKit

/// 設定視窗：macOS 偏好設定式工具列分頁（一般／截圖／輸出／控制）。
/// 各頁邏輯在對應的 *SettingsViewController；這裡只組裝。
public final class SettingsWindowController: NSWindowController {

    public init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        // .toolbar 樣式的 NSTabViewController 會用自己的 title 覆寫視窗標題（nil＝顯示
        // "Untitled"）——標題要設在 tab controller 上，設在 window.title 會被蓋掉。
        tabs.title = "anypaint 設定"
        let pages: [(String, String, NSViewController)] = [
            ("一般", "gearshape", GeneralSettingsViewController()),
            ("截圖", "viewfinder", CaptureSettingsViewController()),
            ("輸出", "square.and.arrow.down", OutputSettingsViewController()),
            ("控制", "keyboard", ControlSettingsViewController()),
        ]
        for (label, symbol, vc) in pages {
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(max(0, AppSettings.settingsSelectedTab),
                                            pages.count - 1)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]   // contentViewController 預設含 resizable——明確拿掉
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }
}

/// 切頁時記住分頁（下次開啟回到同頁）。
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        AppSettings.settingsSelectedTab = selectedTabViewItemIndex
    }
}
