import AppKit
import KeyboardShortcuts

/// 控制：全域快速鍵（recorder 純搬移）＋框選中（框選內功能鍵，可自訂）＋滑鼠（唯讀固定綁定一覽）三子分頁。
/// 子頁切換只顯隱、視窗高度不變（容器高取三者較高者）。
final class ControlSettingsViewController: NSViewController {
    private let segment = NSSegmentedControl(labels: ["全域快速鍵", "框選中", "滑鼠"],
                                             trackingMode: .selectOne,
                                             target: nil, action: nil)
    private var keysView: NSView!
    private var overlayView: NSView!
    private var mouseView: NSView!
    private var overlayFields: [OverlayAction: OverlayKeyRecorderField] = [:]
    private var overlayWarnings: [OverlayAction: NSTextField] = [:]

    override func loadView() {
        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0

        keysView = buildKeysView()
        overlayView = buildOverlayView()
        overlayView.isHidden = true
        mouseView = buildMouseView()
        mouseView.isHidden = true

        // 三子 view 疊放同一容器：各自 pin 頂/左/右，容器底 ≥ 三者底（高取較高者）
        let container = NSView()
        for sub in [keysView!, overlayView!, mouseView!] {
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
        overlayView.isHidden = segment.selectedSegment != 1
        mouseView.isHidden = segment.selectedSegment != 2
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

    /// 框選中的功能鍵。與全域快鍵分開呈現——全域鍵只負責啟動，進到框選後鍵盤屬於 app。
    private func buildOverlayView() -> NSView {
        let rows: [(String, OverlayAction)] = [
            ("重拍：", .reshoot),
            ("取色：", .pickColor),
            ("存檔：", .save),
            ("另存為：", .saveAs),
            ("存檔並開啟：", .saveAndOpen),
            ("辨識文字：", .recognizeText),
        ]
        var fieldRows: [NSView] = []
        for (title, action) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let warning = NSTextField(labelWithString: "")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = .systemOrange
            overlayWarnings[action] = warning

            let field = OverlayKeyRecorderField(
                binding: OverlayKeyBindings.binding(for: action)
            ) { [weak self] new in
                if let new {
                    OverlayKeyBindings.setBinding(new, for: action)
                } else {
                    OverlayKeyBindings.clear(action)
                }
                self?.overlayFields[action]?.binding = OverlayKeyBindings.binding(for: action)
                self?.refreshOverlayWarnings()
            }
            overlayFields[action] = field

            let row = NSStackView(views: [label, field, warning])
            row.orientation = .horizontal
            row.spacing = 8
            fieldRows.append(row)
        }

        let hint = NSTextField(labelWithString: "點一下欄位再按下想要的組合即可更改；按清除鈕可回到預設。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        fieldRows.append(hint)

        let stack = NSStackView(views: fieldRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        refreshOverlayWarnings()
        return stack
    }

    /// 互撞提示：只在真的有動作被遮蔽時說話，一切正常時完全不出現。
    private func refreshOverlayWarnings() {
        let shadowed = OverlayKeyBindings.shadowed(in: OverlayKeyBindings.all())
        for (action, field) in overlayWarnings {
            if let winner = shadowed[action] {
                let combo = OverlayKeyRecorderField.displayString(for: OverlayKeyBindings.binding(for: action))
                field.stringValue = "\(combo) 已用於「\(Self.actionName(winner))」——換一個沒被使用的組合"
            } else {
                field.stringValue = ""
            }
        }
    }

    private static func actionName(_ action: OverlayAction) -> String {
        switch action {
        case .reshoot: return "重拍"
        case .pickColor: return "取色"
        case .save: return "存檔"
        case .saveAs: return "另存為"
        case .saveAndOpen: return "存檔並開啟"
        case .recognizeText: return "辨識文字"
        }
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
