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
    private var interceptMainToggle: NSButton!
    private var interceptHidToggle: NSButton!
    private var interceptStatus: NSTextField!

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
                                        shortcutHint,
                                        buildHotkeyInterceptSection()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    /// 進階：當截圖快鍵被 TeamViewer 等 event-tap 工具攔走時,改用 CGEventTap 搶在前景 app 之前接收
    /// （需輔助使用權限）。預設關＝現行零權限 Carbon。設計文件 `2026-08-15-hotkey-eventtap-design.md`。
    private func buildHotkeyInterceptSection() -> NSView {
        let title = NSTextField(labelWithString: "進階：搶回被攔截的快鍵")
        title.font = .boldSystemFont(ofSize: 12)

        // 情境說明放灰字提示行（checkbox 標題不換行,塞長句會被截斷）。
        let hint = NSTextField(labelWithString: "當截圖快鍵被 TeamViewer 等軟體攔走時，用系統低階攔截搶先接收。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 420

        let mode = AppSettings.hotkeyInterceptMode
        interceptMainToggle = NSButton(checkboxWithTitle: "啟用低階攔截（需輔助使用權限）",
                                       target: self, action: #selector(interceptMainChanged))
        interceptMainToggle.state = mode != .off ? .on : .off

        interceptHidToggle = NSButton(checkboxWithTitle: "加強模式（HID 層，衝突風險較大）",
                                      target: self, action: #selector(interceptHidChanged))
        interceptHidToggle.state = mode == .hid ? .on : .off
        interceptHidToggle.isEnabled = mode != .off

        interceptStatus = NSTextField(labelWithString: "")
        interceptStatus.font = .systemFont(ofSize: 11)
        interceptStatus.lineBreakMode = .byWordWrapping
        interceptStatus.maximumNumberOfLines = 3
        interceptStatus.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [title, hint, interceptMainToggle, interceptHidToggle, interceptStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        updateInterceptStatus()
        return stack
    }

    @objc private func interceptMainChanged() {
        if interceptMainToggle.state == .on {
            _ = Hotkeys.requestAccessibilityIfNeeded()   // 未授權→彈系統對話框並開啟隱私權面板
            let mode: HotkeyInterceptMode = interceptHidToggle.state == .on ? .hid : .session
            AppSettings.hotkeyInterceptMode = mode
            Hotkeys.applyMode(mode)
            interceptHidToggle.isEnabled = true
        } else {
            AppSettings.hotkeyInterceptMode = .off
            Hotkeys.applyMode(.off)
            interceptHidToggle.isEnabled = false
        }
        updateInterceptStatus()
    }

    @objc private func interceptHidChanged() {
        guard interceptMainToggle.state == .on else { return }
        let mode: HotkeyInterceptMode = interceptHidToggle.state == .on ? .hid : .session
        AppSettings.hotkeyInterceptMode = mode
        Hotkeys.applyMode(mode)
        updateInterceptStatus()
    }

    /// 顯示實際生效狀態（與「設定值」區分）：權限沒給時開關雖打勾但 tap 沒起來,要講清楚下一步。
    private func updateInterceptStatus() {
        let mode = AppSettings.hotkeyInterceptMode
        if mode == .off {
            interceptStatus.stringValue = "目前使用一般全域快鍵（免額外權限）。遇到被搶鍵才需要開啟。"
            interceptStatus.textColor = .secondaryLabelColor
        } else if Hotkeys.isTapActive {
            interceptStatus.stringValue = "已啟用低階攔截（\(mode == .hid ? "HID" : "session") 層）。若仍被搶，試試加強模式。"
            interceptStatus.textColor = .systemGreen
        } else {
            interceptStatus.stringValue = "尚未取得輔助使用權限。請到「系統設定 → 隱私權與安全性 → 輔助使用」勾選 anypaint，再重新開啟此開關。"
            interceptStatus.textColor = .systemOrange
        }
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

            let fieldRow = NSStackView(views: [label, field])
            fieldRow.orientation = .horizontal
            fieldRow.spacing = 8

            // 獨立一行放在欄位正下方（而不是同一行的第三格）：同一行給它的寬度只剩約 202pt，
            // 一句完整的中文提示放不下、又是不換行的 label，句子會被容器的 trailing 約束截斷，
            // 使用者只看到前半句、看不到「換一個」那半句該做的事。
            // isHidden＝true 時 NSStackView 完全不替它保留空間與間距，
            // 所以「沒有互撞」的那一行不會比別的動作多佔一點高度。
            let warning = NSTextField(labelWithString: "")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = .systemOrange
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 2
            warning.preferredMaxLayoutWidth = 420   // 略小於容器寬度 440，留一點餘裕避免貼齊右緣
            warning.isHidden = true
            overlayWarnings[action] = warning

            let group = NSStackView(views: [fieldRow, warning])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 4
            fieldRows.append(group)
        }

        let hint = NSTextField(labelWithString:
            "點一下欄位按下組合即可更改；Esc 取消、Delete 或按清除鈕都可回到預設組合。")
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

    /// 互撞提示：只在真的有動作被遮蔽時說話，一切正常時完全不出現（連空白行都不留）。
    private func refreshOverlayWarnings() {
        let shadowed = OverlayKeyBindings.shadowed(in: OverlayKeyBindings.all())
        for (action, warningLabel) in overlayWarnings {
            if let winner = shadowed[action] {
                // 欄位本身已經顯示組合，這裡不必再重複一次按鍵——只講使用者現在該做的事。
                warningLabel.stringValue = "這個組合已經被「\(winner.displayName)」用掉，請換一個。"
                warningLabel.isHidden = false
            } else {
                warningLabel.stringValue = ""
                warningLabel.isHidden = true
            }
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
