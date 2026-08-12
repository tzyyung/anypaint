import AppKit
import AVFoundation

/// 截圖：框選相關（看門狗）。邏輯自 SettingsWindowController 純搬移。
final class CaptureSettingsViewController: NSViewController {
    private let watchdogPopup = NSPopUpButton()
    private let scrollWatchdogPopup = NSPopUpButton()
    private let scrollMaxHeightPopup = NSPopUpButton()
    private let recordCursorCheckbox = NSButton(checkboxWithTitle: "錄製時顯示滑鼠游標", target: nil, action: nil)
    private let recordClickRingCheckbox = NSButton(checkboxWithTitle: "點擊時顯示高亮圈", target: nil, action: nil)
    private let recordGifFpsPopup = NSPopUpButton()
    private let recordUseHEVCCheckbox = NSButton(checkboxWithTitle: "MP4 使用 HEVC（檔案較小，舊裝置相容性較差）", target: nil, action: nil)
    private let recordSystemAudioCheckbox = NSButton(checkboxWithTitle: "錄製系統聲音", target: nil, action: nil)
    private let recordMicCheckbox = NSButton(checkboxWithTitle: "錄製麥克風", target: nil, action: nil)

    override func loadView() {
        let watchdogHint = NSTextField(labelWithString:
            "無任何操作達此時間就自動取消框選（免按鍵的安全保險）。\n選「關閉」後將沒有免按鍵的自動逃生；Esc、右鍵、再按快鍵、工具列取消仍可用。")
        watchdogHint.usesSingleLineMode = false
        watchdogHint.cell?.wraps = true
        watchdogHint.preferredMaxLayoutWidth = 420
        watchdogHint.font = .systemFont(ofSize: 11)
        watchdogHint.textColor = .secondaryLabelColor

        let scrollHint = NSTextField(labelWithString:
            "滾動截圖 capturing 期間讀內容較久屬正常，看門狗獨立於上方框選看門狗；「關閉」時仍以長度上限與連續匹配失敗自動收工兜底。")
        scrollHint.usesSingleLineMode = false
        scrollHint.cell?.wraps = true
        scrollHint.preferredMaxLayoutWidth = 420
        scrollHint.font = .systemFont(ofSize: 11)
        scrollHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [buildWatchdogRow(), watchdogHint,
                                        buildScrollWatchdogRow(), buildScrollMaxHeightRow(), scrollHint,
                                        buildRecordSection()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view = settingsPageView(wrapping: stack)
    }

    /// 動畫截圖：游標／點擊圈兩個開關（Kap UX 連動，設計文件 §7）。
    private func buildRecordSection() -> NSView {
        let heading = NSTextField(labelWithString: "動畫截圖")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)

        recordCursorCheckbox.state = AppSettings.recordShowsCursor ? .on : .off
        recordCursorCheckbox.target = self
        recordCursorCheckbox.action = #selector(recordCursorToggled)

        recordClickRingCheckbox.state = AppSettings.recordClickRing ? .on : .off
        recordClickRingCheckbox.target = self
        recordClickRingCheckbox.action = #selector(recordClickRingToggled)
        updateClickRingEnabledState()   // 初始態也要連動，不只是之後切換時

        recordUseHEVCCheckbox.state = AppSettings.recordUseHEVC ? .on : .off
        recordUseHEVCCheckbox.target = self
        recordUseHEVCCheckbox.action = #selector(recordUseHEVCToggled)

        recordSystemAudioCheckbox.state = AppSettings.recordSystemAudio ? .on : .off
        recordSystemAudioCheckbox.target = self
        recordSystemAudioCheckbox.action = #selector(recordSystemAudioToggled)

        recordMicCheckbox.state = AppSettings.recordMicrophone ? .on : .off
        recordMicCheckbox.target = self
        recordMicCheckbox.action = #selector(recordMicToggled)

        let stack = NSStackView(views: [heading, recordCursorCheckbox, recordClickRingCheckbox,
                                        buildRecordGifFpsRow(), buildGifskiHintLabel(), recordUseHEVCCheckbox,
                                        recordSystemAudioCheckbox, recordMicCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    /// GIF 編碼幀率（沿用上方 watchdog popup 的建構/選中/action 模式，設計文件 §1.2）。
    private func buildRecordGifFpsRow() -> NSView {
        let label = NSTextField(labelWithString: "GIF 幀率：")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true   // 92：對齊上方幾列的標籤寬

        for fps in AppSettings.recordGifFpsOptions {
            recordGifFpsPopup.addItem(withTitle: "\(fps) fps")
            recordGifFpsPopup.lastItem?.tag = fps
        }
        let current = AppSettings.recordGifFps
        _ = recordGifFpsPopup.selectItem(withTag: current)   // recordGifFps 的 getter 已正規化過，必落在選項內
        recordGifFpsPopup.target = self
        recordGifFpsPopup.action = #selector(recordGifFpsChanged)

        let row = NSStackView(views: [label, recordGifFpsPopup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func recordGifFpsChanged() {
        AppSettings.recordGifFps = recordGifFpsPopup.selectedTag()
    }

    /// gifski 偵測 hint（唯讀，設計文件 §1.7）：偵測跑在 loadView（同步、一次 stat 呼叫，
    /// 成本可忽略），不隨後續互動更新——裝/移除 gifski 需要重開設定頁才會反映，可接受。
    private func buildGifskiHintLabel() -> NSView {
        let text: String
        if let path = GifskiEngine.detect() {
            text = "已偵測到 gifski（\(path)）——GIF 將以較高品質引擎產生"
        } else {
            text = "未偵測到 gifski——使用內建編碼器（安裝 gifski 可提升 GIF 品質）"
        }
        let label = NSTextField(labelWithString: text)
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.preferredMaxLayoutWidth = 420
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func recordUseHEVCToggled() {
        AppSettings.recordUseHEVC = (recordUseHEVCCheckbox.state == .on)
    }

    @objc private func recordSystemAudioToggled() {
        AppSettings.recordSystemAudio = (recordSystemAudioCheckbox.state == .on)
    }

    /// 開啟時才要求麥克風權限；使用者拒絕就把設定值與 checkbox 都彈回關閉（不留假象的「開」）。
    @objc private func recordMicToggled() {
        guard recordMicCheckbox.state == .on else {
            AppSettings.recordMicrophone = false
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                AppSettings.recordMicrophone = granted
                self.recordMicCheckbox.state = granted ? .on : .off
                if !granted {
                    let alert = NSAlert()
                    alert.messageText = "需要麥克風權限"
                    alert.informativeText = "請到「系統設定 › 隱私權與安全性 › 麥克風」開啟 anypaint。"
                    alert.runModal()
                }
            }
        }
    }

    @objc private func recordCursorToggled() {
        AppSettings.recordShowsCursor = (recordCursorCheckbox.state == .on)
        updateClickRingEnabledState()
    }

    @objc private func recordClickRingToggled() {
        AppSettings.recordClickRing = (recordClickRingCheckbox.state == .on)
    }

    /// 游標關閉時點擊圈跟著沒有意義（SCK 沒游標可疊圈）——只停用控件、不動存值，
    /// 游標重新打開時原本的設定值原樣恢復（Kap 的 UX 慣例）。
    private func updateClickRingEnabledState() {
        recordClickRingCheckbox.isEnabled = AppSettings.recordShowsCursor
    }

    private func buildWatchdogRow() -> NSView {
        let label = NSTextField(labelWithString: "自動取消：")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true   // 92：容納最長「滾動看門狗：」不截字

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
        _ = watchdogPopup.selectItem(withTag: Int(nearest))
        watchdogPopup.target = self
        watchdogPopup.action = #selector(watchdogChanged)

        let row = NSStackView(views: [label, watchdogPopup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func watchdogChanged() {
        AppSettings.overlayWatchdogSeconds = Double(watchdogPopup.selectedTag())
    }

    /// 滾動截圖 capturing 期間看門狗（沿用上方框選看門狗下拉的建構模式）。
    private func buildScrollWatchdogRow() -> NSView {
        let label = NSTextField(labelWithString: "滾動看門狗：")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true   // 92：容納最長「滾動看門狗：」不截字

        for seconds in AppSettings.scrollWatchdogOptions {
            let title = seconds == 0 ? "關閉" : "\(Int(seconds) / 60) 分鐘"
            scrollWatchdogPopup.addItem(withTitle: title)
            scrollWatchdogPopup.lastItem?.tag = Int(seconds)
        }
        let current = AppSettings.scrollWatchdogSeconds
        let nearest = AppSettings.scrollWatchdogOptions.min {
            abs($0 - current) < abs($1 - current)
        } ?? 300
        _ = scrollWatchdogPopup.selectItem(withTag: Int(nearest))
        scrollWatchdogPopup.target = self
        scrollWatchdogPopup.action = #selector(scrollWatchdogChanged)

        let row = NSStackView(views: [label, scrollWatchdogPopup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func scrollWatchdogChanged() {
        AppSettings.scrollWatchdogSeconds = Double(scrollWatchdogPopup.selectedTag())
    }

    /// 長圖高度上限（spec §7.5）。
    private func buildScrollMaxHeightRow() -> NSView {
        let label = NSTextField(labelWithString: "長圖上限：")
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true   // 92：容納最長「滾動看門狗：」不截字

        for px in AppSettings.scrollMaxHeightOptions {
            scrollMaxHeightPopup.addItem(withTitle: "\(px) px")
            scrollMaxHeightPopup.lastItem?.tag = px
        }
        let current = AppSettings.scrollMaxHeightPx
        let nearest = AppSettings.scrollMaxHeightOptions.min {
            abs($0 - current) < abs($1 - current)
        } ?? 30000
        _ = scrollMaxHeightPopup.selectItem(withTag: nearest)
        scrollMaxHeightPopup.target = self
        scrollMaxHeightPopup.action = #selector(scrollMaxHeightChanged)

        let row = NSStackView(views: [label, scrollMaxHeightPopup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func scrollMaxHeightChanged() {
        AppSettings.scrollMaxHeightPx = scrollMaxHeightPopup.selectedTag()
    }
}
