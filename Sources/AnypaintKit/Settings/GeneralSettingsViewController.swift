import AppKit
import ServiceManagement

/// 一般：app 級設定（開機啟動）。
/// 開機啟動狀態以 SMAppService 系統實況為準，不自存 UserDefaults——
/// 使用者可能在「系統設定 → 登入項目」外部更改。
final class GeneralSettingsViewController: NSViewController {
    private let launchCheckbox = NSButton(checkboxWithTitle: "登入時自動啟動 任截圖",
                                          target: nil, action: nil)
    private let approvalHint = NSTextField(labelWithString:
        "系統要求核准：請到「系統設定 → 一般 → 登入項目」允許 任截圖。")

    override func loadView() {
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)
        approvalHint.font = .systemFont(ofSize: 11)
        approvalHint.textColor = .secondaryLabelColor
        approvalHint.isHidden = true
        let stack = NSStackView(views: [launchCheckbox, approvalHint])
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
}
