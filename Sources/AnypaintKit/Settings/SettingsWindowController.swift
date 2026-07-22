import AppKit
import KeyboardShortcuts

/// 設定視窗：重新錄製截圖 / 貼圖的全域快鍵，並調整框選逾時（看門狗）秒數。
public final class SettingsWindowController: NSWindowController {

    private let watchdogPopup = NSPopUpButton()
    private let savePathField = NSTextField()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380), // 初始值；實際高度由 buildUI 依內容實算
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

        let saveHeading = NSTextField(labelWithString: "存檔")
        saveHeading.font = .boldSystemFont(ofSize: 13)

        let saveRow = buildSaveRow()

        let saveHint = NSTextField(labelWithString:
            "框選後按工具列「存」鈕或 ⌘S，自動以「anypaint 日期 時間.png」存到此資料夾。")
        saveHint.usesSingleLineMode = false
        saveHint.cell?.wraps = true
        saveHint.preferredMaxLayoutWidth = 360
        saveHint.font = .systemFont(ofSize: 11)
        saveHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            shortcutsHeading, captureRow, pinRow, shortcutHint,
            captureHeading, watchdogRow, watchdogHint,
            saveHeading, saveRow, saveHint
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: shortcutHint)
        stack.setCustomSpacing(20, after: watchdogHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])

        // 視窗高度依內容實算（別再手猜 magic number——存檔區加入後 380 不夠，審查抓到）。
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 420, height: stack.fittingSize.height + 40))
        window?.center()   // resize 是頂邊固定向下長，init 時的 center 已偏——重新置中（審查 Minor）
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

    private func buildSaveRow() -> NSView {
        let label = NSTextField(labelWithString: "存檔位置：")
        savePathField.stringValue = AppSettings.saveDirectoryPath
        savePathField.lineBreakMode = .byTruncatingMiddle
        savePathField.delegate = self
        savePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let change = NSButton(title: "變更…", target: self, action: #selector(chooseSaveFolder))
        change.bezelStyle = .rounded
        change.controlSize = .small
        let reveal = NSButton(title: "開啟資料夾", target: self, action: #selector(revealSaveFolder))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        let row = NSStackView(views: [label, savePathField, change, reveal])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: AppSettings.saveDirectoryPath)
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.saveDirectoryPath = url.path
            savePathField.stringValue = url.path
        }
    }

    @objc private func revealSaveFolder() {
        let url = URL(fileURLWithPath: AppSettings.saveDirectoryPath)
        // 還沒存過檔時資料夾可能不存在，NSWorkspace.open 會無聲失敗——先建立
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// 路徑欄失焦/按 Enter＝存（支援手打路徑，~ 自動展開）。
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === savePathField else { return }
        let raw = savePathField.stringValue.trimmingCharacters(in: .whitespaces)
        var path = (raw as NSString).expandingTildeInPath
        if !path.isEmpty, !path.hasPrefix("/") {
            // 相對路徑以家目錄為基底——cwd 不可靠（Finder/launchd 啟動時為 /）
            path = NSHomeDirectory() + "/" + path
        }
        AppSettings.saveDirectoryPath = path   // 空字串＝回復預設（getter 回桌面）
        savePathField.stringValue = AppSettings.saveDirectoryPath   // 回填生效值，所見即所得
    }
}
