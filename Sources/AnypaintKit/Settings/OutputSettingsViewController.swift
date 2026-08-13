import AppKit
import UniformTypeIdentifiers

/// 輸出：手動儲存／快速儲存／自動儲存三小節＋命名規則＋還原預設。
/// 排版照 Snipaste 參考：右對齊 label、唯讀預覽欄、按鈕右對齊（驗收回饋修訂）。
/// 設定值讀寫邏輯與改版前完全等價。
final class OutputSettingsViewController: NSViewController {

    private let manualNameField = NSTextField()
    private let manualPreview = NSTextField()
    private let notifyCheckbox = NSButton(checkboxWithTitle:
        "儲存後顯示系統通知（快速儲存與自動儲存共用）", target: nil, action: nil)
    private let quickPathField = NSTextField()
    private let quickPreview = NSTextField()
    private let autoSaveCheckbox = NSButton(checkboxWithTitle:
        "自動儲存（每次完成截圖都額外存一份）", target: nil, action: nil)
    private let autoPathField = NSTextField()
    private let autoPreview = NSTextField()
    private var autoSaveControls: [NSControl] = []
    private let openWithPopUp = NSPopUpButton()
    /// 「選擇其他 App…」項的 tag——與代表某個 App 的項（representedObject＝bundle ID）區分。
    private static let chooseOtherAppTag = -1

    /// 命名規則視窗（lazy、重用）。
    private var namingRules: NamingRulesWindowController?

    /// 預覽用變數：os/電腦名/使用者名為真值，%title% 用範例字（設定頁沒有截圖 session）。
    private let previewVars = CaptureVars.makeVars(title: "視窗標題")

    override func loadView() {
        let manualLabel = subheading("手動儲存（另存為 ⌘⇧S）")
        setupField(manualNameField, value: AppSettings.manualNameTemplate)
        setupPreview(manualPreview)

        let quickLabel = subheading("快速儲存（⌘S）")
        notifyCheckbox.state = AppSettings.saveNotificationEnabled ? .on : .off
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled)
        setupField(quickPathField, value: AppSettings.quickSavePathTemplate)
        setupPreview(quickPreview)

        let openWithLabel = subheading("存檔並開啟（⌘O）")
        openWithPopUp.target = self
        openWithPopUp.action = #selector(openWithChanged)
        openWithPopUp.toolTip = "按「存檔並開啟」時，把存好的 PNG 交給哪個 App"
        openWithPopUp.widthAnchor.constraint(equalToConstant: 356).isActive = true   // 76 + 8 + 356 = 440
        rebuildOpenWithMenu()

        let autoLabel = subheading("自動儲存")
        autoSaveCheckbox.state = AppSettings.autoSaveEnabled ? .on : .off
        autoSaveCheckbox.target = self
        autoSaveCheckbox.action = #selector(autoSaveToggled)
        setupField(autoPathField, value: AppSettings.autoSavePathTemplate)
        setupPreview(autoPreview)

        let quickButtons = trailingRow(folderButtons(open: #selector(openQuickFolder),
                                                     change: #selector(changeQuickFolder)))
        let autoButtonViews = folderButtons(open: #selector(openAutoFolder),
                                            change: #selector(changeAutoFolder))
        let autoButtons = trailingRow(autoButtonViews)
        autoSaveControls = [autoPathField, autoPreview]
            + autoButtonViews.compactMap { $0 as? NSControl }

        let rulesButton = NSButton(title: "命名規則…", target: self, action: #selector(showNamingRules))
        rulesButton.bezelStyle = .rounded
        rulesButton.controlSize = .small
        let resetButton = NSButton(title: "還原預設", target: self, action: #selector(resetOutput))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.addView(rulesButton, in: .leading)
        bottomRow.addView(resetButton, in: .trailing)
        bottomRow.widthAnchor.constraint(equalToConstant: 440).isActive = true

        let manualPreviewRow = labeledRow("預覽：", control: manualPreview)
        let openWithRow = labeledRow("開啟方式：", control: openWithPopUp)
        let stack = NSStackView(views: [
            manualLabel,
            labeledRow("檔案名稱：", control: manualNameField),
            manualPreviewRow,
            quickLabel, notifyCheckbox,
            labeledRow("路徑：", control: quickPathField),
            labeledRow("預覽：", control: quickPreview),
            quickButtons,
            openWithLabel, openWithRow,
            autoLabel, autoSaveCheckbox,
            labeledRow("路徑：", control: autoPathField),
            labeledRow("預覽：", control: autoPreview),
            autoButtons,
            bottomRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: manualPreviewRow)
        stack.setCustomSpacing(16, after: quickButtons)
        stack.setCustomSpacing(16, after: openWithRow)
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

    /// 「右對齊 label（76pt）：控件」列；列寬統一 440——各列左右緣對齊（排版規格）。
    private func labeledRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return row
    }

    /// 內容靠右的列（資料夾按鈕）。
    private func trailingRow(_ views: [NSView]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for v in views { row.addView(v, in: .trailing) }
        row.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return row
    }

    private func setupField(_ field: NSTextField, value: String) {
        field.stringValue = value
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = self
    }

    /// 預覽＝唯讀欄位樣式（與輸入欄同寬對齊；可選取複製）。
    private func setupPreview(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = true
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
    }

    private func folderButtons(open: Selector, change: Selector) -> [NSView] {
        let openButton = NSButton(title: "開啟資料夾", target: self, action: open)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        let changeButton = NSButton(title: "變更資料夾…", target: self, action: change)
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        return [openButton, changeButton]
    }

    // MARK: - 開啟方式

    /// 選單：系統預設 ─ 能開 PNG 的 App ─（目前選的若不在上面，補一項）─ 選擇其他 App…
    ///
    /// 每次重建而不是增量更新：使用者可能在設定頁開著時裝了新 App，重建最省心；
    /// 選單只在載入與變更時建，成本無關緊要。
    private func rebuildOpenWithMenu() {
        let ws = NSWorkspace.shared
        let menu = NSMenu()

        // 「系統預設」附上實際會用到的程式名——不讓「預設」變成黑箱。
        // URLForApplicationToOpenContentType 不需要實際檔案存在（已查 SDK header，macOS 12+）。
        let defaultName = ws.urlForApplication(toOpen: .png).map { appDisplayName(at: $0) }
        let systemItem = NSMenuItem(title: defaultName.map { "系統預設（\($0)）" } ?? "系統預設",
                                    action: nil, keyEquivalent: "")
        systemItem.representedObject = ""
        menu.addItem(systemItem)
        menu.addItem(.separator())

        var listed = Set<String>()
        let apps = ws.urlsForApplications(toOpen: .png)
            .compactMap { url -> (id: String, name: String, url: URL)? in
                guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
                return (id, appDisplayName(at: url), url)
            }
            .filter { listed.insert($0.id).inserted }   // 同一 App 有多份拷貝時只留第一個
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for app in apps { menu.addItem(appItem(id: app.id, name: app.name, url: app.url)) }

        // 目前選的 App 若不在上面（手動選了不關聯 PNG 的 App，或它已被刪）→ 補一項並選中，
        // 否則選單會顯示成別的東西、使用者看不出自己設過什麼。
        let current = AppSettings.openWithBundleIdentifier
        if !current.isEmpty, !listed.contains(current) {
            menu.addItem(.separator())
            if let url = ws.urlForApplication(withBundleIdentifier: current) {
                menu.addItem(appItem(id: current, name: appDisplayName(at: url), url: url))
            } else {
                let missing = NSMenuItem(title: "\(current)（找不到，將用系統預設）",
                                         action: nil, keyEquivalent: "")
                missing.representedObject = current
                menu.addItem(missing)
            }
        }

        menu.addItem(.separator())
        let other = NSMenuItem(title: "選擇其他 App…", action: nil, keyEquivalent: "")
        other.tag = Self.chooseOtherAppTag
        menu.addItem(other)

        openWithPopUp.menu = menu
        let target = menu.items.first { ($0.representedObject as? String) == current }
        openWithPopUp.select(target ?? menu.items.first)
    }

    private func appItem(id: String, name: String, url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.representedObject = id
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    /// App 的顯示名，盡量拿到本地化版本（繁中系統上「預覽程式」而非「Preview」）。
    ///
    /// 兩條路都試過才這樣寫：現代 App 的本地化名放在 `Contents/Resources/InfoPlist.loctable`
    /// （Preview.app 的 `zh_TW` 鍵確實是「預覽程式」，實測確認），但取得方式不只一種且各有
    /// 失效情境——`FileManager.displayName` 依 process 的 localization，命令列下實測會原樣
    /// 回「Preview.app」；`localizedInfoDictionary` 同樣依 process 偏好語系解析。
    /// 所以：先問 Finder 名，它若明顯沒本地化（等於檔名）再問 bundle，最後退回檔名。
    /// 任何一條失敗都還有可讀的名字，不會出現空白選項。
    private func appDisplayName(at url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        let finderName = (FileManager.default.displayName(atPath: url.path) as NSString)
            .deletingPathExtension
        if !finderName.isEmpty, finderName != fileName { return finderName }
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.localizedInfoDictionary?[key] as? String, !name.isEmpty {
                    return name
                }
                if let name = bundle.infoDictionary?[key] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return fileName
    }

    @objc private func openWithChanged() {
        guard let item = openWithPopUp.selectedItem else { return }
        if item.tag == Self.chooseOtherAppTag {
            if let id = pickApplication() { AppSettings.openWithBundleIdentifier = id }
            rebuildOpenWithMenu()   // 取消也要重建：否則選單停在「選擇其他 App…」這個非設定值
            return
        }
        AppSettings.openWithBundleIdentifier = (item.representedObject as? String) ?? ""
    }

    /// 選一個 .app；回傳它的 bundle ID（存 ID 不存路徑——App 搬家仍找得到）。
    private func pickApplication() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "選擇"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
            NSSound.beep()   // 選到讀不出 bundle ID 的東西：不能存，否則設了等於沒設
            return nil
        }
        return id
    }

    // MARK: - 預覽

    /// 樣板 → 預覽值（即時展開；結尾非 .png 加補正提示）。「預覽：」由 label 顯示，不再前綴。
    /// ~ 展開成絕對路徑——預覽顯示實際會存到哪（非 ~ 開頭原樣回傳，檔名樣板不受影響）。
    private func previewText(for template: String) -> String {
        var text = FilenameTemplate.expand(template, date: Date(), vars: previewVars)
        text = (text as NSString).expandingTildeInPath
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

    // MARK: - Actions（邏輯與改版前等價）

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
        let controller = namingRules ?? NamingRulesWindowController()
        namingRules = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resetOutput() {
        AppSettings.resetOutputDefaults()
        manualNameField.stringValue = AppSettings.manualNameTemplate
        quickPathField.stringValue = AppSettings.quickSavePathTemplate
        autoPathField.stringValue = AppSettings.autoSavePathTemplate
        notifyCheckbox.state = AppSettings.saveNotificationEnabled ? .on : .off
        autoSaveCheckbox.state = AppSettings.autoSaveEnabled ? .on : .off
        rebuildOpenWithMenu()   // 開啟方式也在 resetOutputDefaults 的清單裡
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

    /// 手打路徑樣板正規化：trim；~ 與絕對路徑保留樣板原文（不展開——展開交給預覽與存檔，
    /// 樣板保持可攜）；相對路徑補 ~/ 前綴（cwd 不可靠，launchd 啟動＝/，且不寫死家目錄）。
    /// 空字串原樣回傳（setter 存空＝getter 回預設）。
    private func normalizedPathTemplate(_ raw: String) -> String {
        FilenameTemplate.normalizedPathTemplate(raw)
    }
}
