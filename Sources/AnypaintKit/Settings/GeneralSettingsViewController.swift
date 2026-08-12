import AppKit
import ServiceManagement

/// 一般：app 級設定（開機啟動）。
/// 開機啟動狀態以 SMAppService 系統實況為準，不自存 UserDefaults——
/// 使用者可能在「系統設定 → 登入項目」外部更改。
final class GeneralSettingsViewController: NSViewController {
    private let launchCheckbox = NSButton(checkboxWithTitle: "登入時自動啟動 anypaint",
                                          target: nil, action: nil)
    private let approvalHint = NSTextField(labelWithString:
        "系統要求核准：請到「系統設定 → 一般 → 登入項目」允許 anypaint。")
    private let allowLocalAutomationCheckbox = NSButton(checkboxWithTitle: "允許本機自動化（anypaintctl）",
                                                         target: nil, action: nil)
    private let allowLocalAutomationHint = NSTextField(labelWithString:
        "開啟後本機程式可遙控 anypaint 截圖／錄影；開啟／關閉皆需重新啟動 anypaint 後生效。")

    override func loadView() {
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)
        approvalHint.font = .systemFont(ofSize: 11)
        approvalHint.textColor = .secondaryLabelColor
        approvalHint.isHidden = true

        allowLocalAutomationCheckbox.state = AppSettings.allowLocalAutomation ? .on : .off
        allowLocalAutomationCheckbox.target = self
        allowLocalAutomationCheckbox.action = #selector(allowLocalAutomationToggled)
        allowLocalAutomationHint.font = .systemFont(ofSize: 11)
        allowLocalAutomationHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [launchCheckbox, approvalHint,
                                        allowLocalAutomationCheckbox, allowLocalAutomationHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view = settingsPageView(wrapping: stack)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSystem()
    }

    private func refreshFromSystem() {
        let status = SMAppService.mainApp.status
        launchCheckbox.state = status == .enabled ? .on : .off
        approvalHint.isHidden = status != .requiresApproval
    }

    @objc private func toggleLaunch() {
        do {
            if launchCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("anypaint: 開機啟動設定失敗 \(error)")
        }
        refreshFromSystem()   // 以系統實況回彈——失敗時 checkbox 不會停在錯誤狀態
    }

    @objc private func allowLocalAutomationToggled() {
        AppSettings.allowLocalAutomation = (allowLocalAutomationCheckbox.state == .on)
    }
}
