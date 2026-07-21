import AppKit
import KeyboardShortcuts

/// 設定視窗：重新錄製截圖 / 貼圖的全域快鍵，並調整框選逾時（看門狗）秒數。
public final class SettingsWindowController: NSWindowController {

    private let watchdogPopup = NSPopUpButton()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), // 高度要容得下兩行 watchdogHint
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "anypaint 設定"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let shortcutsHeading = NSTextField(labelWithString: "全域快鍵")
        shortcutsHeading.font = .boldSystemFont(ofSize: 13)

        let captureRow = shortcutRow(title: "截圖", name: .capture)
        let pinRow = shortcutRow(title: "貼圖", name: .pin)

        let shortcutHint = NSTextField(labelWithString: "點一下欄位再按下想要的組合即可更改；按清除鈕可移除。")
        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .secondaryLabelColor

        let captureHeading = NSTextField(labelWithString: "框選")
        captureHeading.font = .boldSystemFont(ofSize: 13)

        let watchdogRow = buildWatchdogRow()

        let watchdogHint = NSTextField(labelWithString:
            "無任何操作達此時間就自動取消框選（免按鍵的安全保險）。\n選「關閉」後將沒有免按鍵的自動逃生；Esc、右鍵、再按快鍵、工具列取消仍可用。")
        watchdogHint.usesSingleLineMode = false
        watchdogHint.cell?.wraps = true
        watchdogHint.preferredMaxLayoutWidth = 360
        watchdogHint.font = .systemFont(ofSize: 11)
        watchdogHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            shortcutsHeading, captureRow, pinRow, shortcutHint,
            captureHeading, watchdogRow, watchdogHint
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: shortcutHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])
    }

    private func shortcutRow(title: String, name: KeyboardShortcuts.Name) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)

        let row = NSStackView(views: [label, recorder])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func buildWatchdogRow() -> NSView {
        let label = NSTextField(labelWithString: "自動取消")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true

        for seconds in AppSettings.watchdogOptions {
            let title = seconds == 0 ? "關閉" : "\(Int(seconds) / 60) 分鐘"
            watchdogPopup.addItem(withTitle: title)
            watchdogPopup.lastItem?.tag = Int(seconds)
        }
        // 舊值（含 stepper 時代的任意秒數）對應到最接近的選項
        let current = AppSettings.overlayWatchdogSeconds
        let nearest = AppSettings.watchdogOptions.min {
            abs($0 - current) < abs($1 - current)
        } ?? 60
        _ = watchdogPopup.selectItem(withTag: Int(nearest))   // 回傳 Bool（是否選中），這裡不需要
        watchdogPopup.target = self
        watchdogPopup.action = #selector(watchdogChanged)

        let row = NSStackView(views: [label, watchdogPopup])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    @objc private func watchdogChanged() {
        AppSettings.overlayWatchdogSeconds = Double(watchdogPopup.selectedTag())
    }
}
