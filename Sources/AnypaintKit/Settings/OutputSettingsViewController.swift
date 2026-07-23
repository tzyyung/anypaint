import AppKit

/// 輸出：手動儲存／快速儲存／自動儲存三小節＋命名規則＋還原預設。
/// 自 SettingsWindowController 純搬移（分頁重構）；邏輯不變。
final class OutputSettingsViewController: NSViewController {

    private let manualNameField = NSTextField()
    private let manualPreview = NSTextField(labelWithString: "")
    private let notifyCheckbox = NSButton(checkboxWithTitle:
        "儲存後顯示系統通知（快速儲存與自動儲存共用）", target: nil, action: nil)
    private let quickPathField = NSTextField()
    private let quickPreview = NSTextField(labelWithString: "")
    private let autoSaveCheckbox = NSButton(checkboxWithTitle:
        "自動儲存（每次完成擷取都額外存一份）", target: nil, action: nil)
    private let autoPathField = NSTextField()
    private let autoPreview = NSTextField(labelWithString: "")
    private var autoSaveControls: [NSControl] = []

    /// 預覽用變數：os/電腦名/使用者名為真值，%title% 用範例字（設定頁沒有截圖 session）。
    private let previewVars = CaptureVars.makeVars(title: "視窗標題")

    override func loadView() {
        let manualLabel = subheading("手動儲存——另存為（⌘⇧S）的預設檔名")
        let manualRow = fieldRow(title: "檔名樣板", field: manualNameField,
                                 value: AppSettings.manualNameTemplate)
        setupPreview(manualPreview)

        let quickLabel = subheading("快速儲存——「存」鈕 / ⌘S")
        notifyCheckbox.state = AppSettings.saveNotificationEnabled ? .on : .off
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled)
        let quickRow = fieldRow(title: "路徑樣板", field: quickPathField,
                                value: AppSettings.quickSavePathTemplate)
        setupPreview(quickPreview)
        let quickButtons = folderButtons(open: #selector(openQuickFolder),
                                         change: #selector(changeQuickFolder))

        let autoLabel = subheading("自動儲存")
        autoSaveCheckbox.state = AppSettings.autoSaveEnabled ? .on : .off
        autoSaveCheckbox.target = self
        autoSaveCheckbox.action = #selector(autoSaveToggled)
        let autoRow = fieldRow(title: "路徑樣板", field: autoPathField,
                               value: AppSettings.autoSavePathTemplate)
        setupPreview(autoPreview)
        let autoButtons = folderButtons(open: #selector(openAutoFolder),
                                        change: #selector(changeAutoFolder))
        autoSaveControls = [autoPathField] + controls(in: autoButtons)

        let rulesButton = NSButton(title: "命名規則…", target: self, action: #selector(showNamingRules))
        rulesButton.bezelStyle = .rounded
        rulesButton.controlSize = .small
        let resetButton = NSButton(title: "還原預設", target: self, action: #selector(resetOutput))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        let bottomRow = NSStackView(views: [rulesButton, resetButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8

        let stack = NSStackView(views: [
            manualLabel, manualRow, manualPreview,
            quickLabel, notifyCheckbox, quickRow, quickPreview, quickButtons,
            autoLabel, autoSaveCheckbox, autoRow, autoPreview, autoButtons,
            bottomRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: manualPreview)
        stack.setCustomSpacing(16, after: quickButtons)
        stack.setCustomSpacing(16, after: autoButtons)
        view = settingsPageView(wrapping: stack)

        refreshPreviews()
        updateAutoSaveEnabledState()
    }

    // MARK: - 元件工廠

    private func subheading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func fieldRow(title: String, field: NSTextField, value: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        field.stringValue = value
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = self
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func setupPreview(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
    }

    private func folderButtons(open: Selector, change: Selector) -> NSStackView {
        let openButton = NSButton(title: "開啟資料夾", target: self, action: open)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        let changeButton = NSButton(title: "變更資料夾…", target: self, action: change)
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        let row = NSStackView(views: [openButton, changeButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func controls(in row: NSStackView) -> [NSControl] {
        row.arrangedSubviews.compactMap { $0 as? NSControl }
    }

    // MARK: - 預覽

    /// 樣板 → 預覽文字（即時展開；結尾非 .png 加補正提示，spec）。
    private func previewText(for template: String) -> String {
        var text = "預覽：" + FilenameTemplate.expand(template, date: Date(), vars: previewVars)
        if !FilenameTemplate.hasPNGExtension(template) { text += "（將自動補 .png）" }
        return text
    }

    /// 欄位現值優先（打字中即時）；欄空＝顯示生效預設（getter 空回預設）。
    private func refreshPreviews() {
        let manual = manualNameField.stringValue.isEmpty
            ? AppSettings.manualNameTemplate : manualNameField.stringValue
        manualPreview.stringValue = previewText(for: manual)
        let quick = quickPathField.stringValue.isEmpty
            ? AppSettings.quickSavePathTemplate : quickPathField.stringValue
        quickPreview.stringValue = previewText(for: quick)
        let auto = autoPathField.stringValue.isEmpty
            ? AppSettings.autoSavePathTemplate : autoPathField.stringValue
        autoPreview.stringValue = previewText(for: auto)
    }

    // MARK: - Actions

    @objc private func notifyToggled() {
        AppSettings.saveNotificationEnabled = (notifyCheckbox.state == .on)
    }

    @objc private func autoSaveToggled() {
        AppSettings.autoSaveEnabled = (autoSaveCheckbox.state == .on)
        updateAutoSaveEnabledState()
    }

    private func updateAutoSaveEnabledState() {
        let on = AppSettings.autoSaveEnabled
        for control in autoSaveControls { control.isEnabled = on }
        autoPreview.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// 樣板展開後的目錄段（絕對路徑；日期 token 用當下時間）。
    private func expandedDirectory(of template: String) -> String {
        let expanded = FilenameTemplate.expand(template, date: Date(), vars: previewVars)
        var path = (expanded as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = NSHomeDirectory() + "/" + path }
        return (path as NSString).deletingLastPathComponent
    }

    @objc private func openQuickFolder() {
        openFolder(expandedDirectory(of: AppSettings.quickSavePathTemplate))
    }

    @objc private func openAutoFolder() {
        openFolder(expandedDirectory(of: AppSettings.autoSavePathTemplate))
    }

    private func openFolder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        // 還沒存過檔時資料夾可能不存在，NSWorkspace.open 會無聲失敗——先建立
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func changeQuickFolder() {
        guard let dir = pickFolder(startingAt: expandedDirectory(of: AppSettings.quickSavePathTemplate))
        else { return }
        // 只換目錄段、保留檔名樣板段（樣板字面的最後一段，spec）
        let name = (AppSettings.quickSavePathTemplate as NSString).lastPathComponent
        AppSettings.quickSavePathTemplate = dir + "/" + name
        quickPathField.stringValue = AppSettings.quickSavePathTemplate
        refreshPreviews()
    }

    @objc private func changeAutoFolder() {
        guard let dir = pickFolder(startingAt: expandedDirectory(of: AppSettings.autoSavePathTemplate))
        else { return }
        let name = (AppSettings.autoSavePathTemplate as NSString).lastPathComponent
        AppSettings.autoSavePathTemplate = dir + "/" + name
        autoPathField.stringValue = AppSettings.autoSavePathTemplate
        refreshPreviews()
    }

    private func pickFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    @objc private func showNamingRules() {
        let alert = NSAlert()
        alert.messageText = "命名規則"
        alert.informativeText = """
        日期時間寫在 $ $ 內，例：$yyyy-MM-dd HH.mm.ss$

        d / dd　日（1-31／01-31）　　ddd / dddd　星期（Sun／Sunday）
        M / MM　月（1-12／01-12）　　MMM / MMMM　月（Jul／July）
        yy / yyyy　年（26／2026）　　H / HH　時（0-23／00-23）
        m / mm　分　　s / ss　秒
        z / zzz　毫秒（0-999／000-999）　　t　時區（如 +0800）

        變數：%os%＝系統版本、%computername%＝電腦名稱、
        %username%＝使用者名稱、%title%＝截圖前的使用中視窗標題、
        %title:20%＝標題截前 20 字。

        非法字元 | : * ? < > 會自動換成 -；路徑中的 / 是資料夾分隔。
        目前僅支援 .png（樣板結尾不是 .png 會自動補上）。
        """
        alert.runModal()
    }

    @objc private func resetOutput() {
        AppSettings.resetOutputDefaults()
        manualNameField.stringValue = AppSettings.manualNameTemplate
        quickPathField.stringValue = AppSettings.quickSavePathTemplate
        autoPathField.stringValue = AppSettings.autoSavePathTemplate
        notifyCheckbox.state = AppSettings.saveNotificationEnabled ? .on : .off
        autoSaveCheckbox.state = AppSettings.autoSaveEnabled ? .on : .off
        refreshPreviews()
        updateAutoSaveEnabledState()
    }
}

extension OutputSettingsViewController: NSTextFieldDelegate {
    /// 打字即時更新預覽（spec：改完立即預覽）。
    func controlTextDidChange(_ obj: Notification) {
        refreshPreviews()
    }

    /// 失焦/Enter＝寫入設定並回填生效值（所見即所得；空字串＝回復預設）。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === manualNameField {
            AppSettings.manualNameTemplate = field.stringValue.trimmingCharacters(in: .whitespaces)
            field.stringValue = AppSettings.manualNameTemplate
        } else if field === quickPathField {
            AppSettings.quickSavePathTemplate = normalizedPathTemplate(field.stringValue)
            field.stringValue = AppSettings.quickSavePathTemplate
        } else if field === autoPathField {
            AppSettings.autoSavePathTemplate = normalizedPathTemplate(field.stringValue)
            field.stringValue = AppSettings.autoSavePathTemplate
        } else {
            return
        }
        refreshPreviews()
    }

    /// 手打路徑樣板正規化：trim；~ 展開；相對路徑以家目錄為基底（cwd 不可靠，launchd 啟動＝/）。
    /// 空字串原樣回傳（setter 存空＝getter 回預設）。
    private func normalizedPathTemplate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        var path = (trimmed as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = NSHomeDirectory() + "/" + path }
        return path
    }
}
