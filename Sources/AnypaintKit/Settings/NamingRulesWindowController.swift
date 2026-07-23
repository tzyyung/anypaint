import AppKit

/// 命名規則說明視窗：分節＋token/說明兩欄表格（照 Snipaste 排版參考）。
/// 由 OutputSettingsViewController lazy 持有，重複開啟重用。
final class NamingRulesWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), // 高度由 buildUI 實算
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "命名規則"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let sections: [NSView] = [
            sectionTitle("非法字元"),
            noteLabel("| : * ? < > 會自動換成 -；路徑中的 / 是資料夾分隔。\n目前僅支援 .png（樣板結尾不是 .png 會自動補上）。"),
            separator(),
            sectionTitle("環境變數：%……%"),
            tokenGrid([
                ("%os%", "作業系統"),
                ("%computername%", "電腦名稱"),
                ("%username%", "使用者名稱"),
            ]),
            separator(),
            sectionTitle("特殊變數"),
            tokenGrid([
                ("%title%", "截圖前的使用中視窗標題"),
                ("%title:50%", "同上，但標題長度被限制在 50 個字元以內"),
            ]),
            separator(),
            sectionTitle("日期和時間：$……$"),
            tokenGrid([
                ("d / dd", "日期（1–31／01–31）"),
                ("ddd / dddd", "星期幾（英文縮寫／全稱）"),
                ("M / MM", "月份（1–12／01–12）"),
                ("MMM / MMMM", "月份（英文縮寫／全稱）"),
                ("yy / yyyy", "年（兩位數／四位數）"),
                ("H / HH", "時（0–23／00–23）"),
                ("m / mm", "分（0–59／00–59）"),
                ("s / ss", "秒（0–59／00–59）"),
                ("z / zzz", "毫秒（0–999／000–999）"),
                ("t", "時區（如 +0800）"),
            ]),
        ]

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])

        // 視窗高度依內容實算（規範：禁 magic number）
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 480, height: stack.fittingSize.height + 40))
        window?.center()
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.preferredMaxLayoutWidth = 440
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return box
    }

    private func tokenGrid(_ rows: [(String, String)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { pair -> [NSView] in
            let token = NSTextField(labelWithString: pair.0)
            token.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let desc = NSTextField(labelWithString: "－ " + pair.1)
            desc.font = .systemFont(ofSize: 12)
            return [token, desc]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).width = 130   // token 欄固定寬——各節左緣對齊
        return grid
    }
}
