import AppKit
import KeyboardShortcuts

/// 控制：全域快速鍵（recorder 純搬移）＋滑鼠（唯讀固定綁定一覽）兩子分頁。
/// 子頁切換只顯隱、視窗高度不變（容器高取兩者較高者）。
final class ControlSettingsViewController: NSViewController {
    private let segment = NSSegmentedControl(labels: ["全域快速鍵", "滑鼠"],
                                             trackingMode: .selectOne,
                                             target: nil, action: nil)
    private var keysView: NSView!
    private var mouseView: NSView!

    override func loadView() {
        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0

        keysView = buildKeysView()
        mouseView = buildMouseView()
        mouseView.isHidden = true

        // 兩子 view 疊放同一容器：各自 pin 頂/左/右，容器底 ≥ 兩者底（高取較高者）
        let container = NSView()
        for sub in [keysView!, mouseView!] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: container.topAnchor),
                sub.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                container.bottomAnchor.constraint(greaterThanOrEqualTo: sub.bottomAnchor),
            ])
        }
        container.widthAnchor.constraint(equalToConstant: 440).isActive = true

        let stack = NSStackView(views: [segment, container])
        stack.orientation = .vertical
        stack.alignment = .centerX   // segment 置中（Snipaste 同款）；container 滿寬不受影響
        stack.spacing = 16
        view = settingsPageView(wrapping: stack)
    }

    @objc private func segmentChanged() {
        keysView.isHidden = segment.selectedSegment != 0
        mouseView.isHidden = segment.selectedSegment != 1
    }

    private func buildKeysView() -> NSView {
        let shortcutHint = NSTextField(labelWithString: "點一下欄位再按下想要的組合即可更改；按清除鈕可移除。")
        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [shortcutRow(title: "截圖：", name: .capture),
                                        shortcutRow(title: "貼圖：", name: .pin),
                                        shortcutRow(title: "滾動截圖：", name: .scrollCapture),
                                        shortcutRow(title: "動畫截圖：", name: .animatedCapture),
                                        shortcutHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func shortcutRow(title: String, name: KeyboardShortcuts.Name) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true   // 92：容納最長「滾動截圖：」不截字

        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)

        let row = NSStackView(views: [label, recorder])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildMouseView() -> NSView {
        // 與 PinWindow 實作同步的固定綁定（spec 一覽表）
        let rows: [(String, String)] = [
            ("貼圖縮放", "滑鼠滾輪"),
            ("調整透明度", "⌘＋滑鼠滾輪（或 [ / ]，0 還原）"),
            ("關閉貼圖", "左鍵雙按"),
            ("重設大小與透明度", "中鍵點選"),
            ("快速縮圖", "⇧＋左鍵雙按"),
            ("複製文字（OCR）", "⇧＋右鍵點選"),
        ]
        let grid = NSGridView(views: rows.map { pair -> [NSView] in
            let name = NSTextField(labelWithString: pair.0 + "：")
            name.alignment = .right
            let value = NSTextField(labelWithString: pair.1)
            return [name, value]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        let note = NSTextField(labelWithString: "目前為固定綁定；自訂功能規劃中。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }
}
