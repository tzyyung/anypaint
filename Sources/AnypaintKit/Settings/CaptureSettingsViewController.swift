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
    /// 「錄影」直接落地的存檔資料夾顯示（Task B1/B3）。
    private let recordSaveDirLabel = NSTextField(labelWithString: "")
    private let micDevicePopup = NSPopUpButton()
    private let micLevelMeter = LevelMeterView()
    private let micLevelMonitor = MicLevelMonitor()
    /// 麥克風裝置選擇＋電平表那一列（漸進展開，`isHidden` 隨「錄製麥克風」開關連動）。
    /// 在 `buildMicDetailRow()` 裡建構後才有值，`loadView` 一定先跑過那條路，之後才可能被
    /// 其他方法（`recordMicToggled` 等）存取。
    private var micDetailRow: NSView!
    /// 分頁目前是否顯示中（`viewWillAppear`/`viewWillDisappear` 維護）。`updateMicMonitorState()`
    /// 判斷「該不該開電平監看」時要一併看這個值——頁面被切走／設定視窗關閉時，即使「錄製麥克風」
    /// 開關仍是開的，也不該重新掛起監看。
    private var isViewVisible = false

    override func loadView() {
        micLevelMonitor.onLevel = { [weak self] level in
            self?.micLevelMeter.level = level
        }

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

        let micRow = buildMicDetailRow()
        micDetailRow = micRow

        let recordHeading = NSTextField(labelWithString: "錄影（直接存檔）")
        recordHeading.font = .systemFont(ofSize: 12, weight: .semibold)

        let stack = NSStackView(views: [heading, recordCursorCheckbox, recordClickRingCheckbox,
                                        buildRecordGifFpsRow(), buildGifskiHintLabel(), recordUseHEVCCheckbox,
                                        recordSystemAudioCheckbox, recordMicCheckbox, micRow,
                                        recordHeading, buildRecordSaveDirRow()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    /// 「錄影」直接落地的存檔資料夾列（Task B1/B3）：顯示目前路徑＋選擇／回預設。
    private func buildRecordSaveDirRow() -> NSView {
        let title = NSTextField(labelWithString: "存檔資料夾：")
        recordSaveDirLabel.stringValue = AppSettings.recordSaveDirectory ?? "~/Movies/anypaint"
        recordSaveDirLabel.lineBreakMode = .byTruncatingMiddle
        recordSaveDirLabel.textColor = .secondaryLabelColor
        recordSaveDirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pick = NSButton(title: "選擇…", target: self, action: #selector(pickRecordSaveDir))
        pick.bezelStyle = .rounded
        let reset = NSButton(title: "預設", target: self, action: #selector(resetRecordSaveDir))
        reset.bezelStyle = .rounded
        let row = NSStackView(views: [title, recordSaveDirLabel, pick, reset])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    @objc private func pickRecordSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.recordSaveDirectory = url.path
            recordSaveDirLabel.stringValue = url.path
        }
    }

    @objc private func resetRecordSaveDir() {
        AppSettings.recordSaveDirectory = nil
        recordSaveDirLabel.stringValue = "~/Movies/anypaint"
    }

    /// 麥克風裝置下拉＋即時電平表：漸進展開列，「錄製麥克風」勾上才顯示（`recordMicToggled`）。
    private func buildMicDetailRow() -> NSView {
        populateMicDevicePopup()
        micDevicePopup.target = self
        micDevicePopup.action = #selector(micDeviceChanged)
        micDevicePopup.menu?.delegate = self   // 展開時重新列舉，涵蓋熱插拔（見 menuWillOpen）

        micLevelMeter.widthAnchor.constraint(equalToConstant: 120).isActive = true
        micLevelMeter.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let row = NSStackView(views: [micDevicePopup, micLevelMeter])
        row.orientation = .horizontal
        row.spacing = 8
        row.isHidden = !AppSettings.recordMicrophone
        return row
    }

    /// 重新列舉麥克風裝置：第一項固定「系統預設」（`representedObject == nil`），其餘來自
    /// `AudioInputDeviceList.all()`。選中項一律以 `AppSettings.recordMicrophoneDeviceID`
    /// （存值）為準，不看 popup 目前的暫時選中狀態——存值在新列出的清單裡找不到對應裝置
    /// （拔線／幽靈裝置）就回退系統預設並清鍵。呼叫時機：`loadView`（首次）與
    /// `menuWillOpen`（每次展開，涵蓋熱插拔）。
    private func populateMicDevicePopup() {
        let devices = AudioInputDeviceList.all()
        // 幽靈裝置偵測＋該選第幾項的純決策抽到 AudioInputDeviceList.popupSelection（可測）。
        let sel = AudioInputDeviceList.popupSelection(saved: AppSettings.recordMicrophoneDeviceID,
                                                      deviceIDs: devices.map(\.uniqueID))
        if sel.isGhost {
            AppSettings.recordMicrophoneDeviceID = nil
            // 幽靈裝置清鍵後，底層監看可能還釘著那顆已消失的裝置（fix round 1，team-lead 審查
            // 抓到：清鍵沒有連動重掛，電平表會凍結在最後一格）。走唯一出口，讓它以新的
            // nil＝系統預設重新判斷啟停。
            updateMicMonitorState()
        }

        micDevicePopup.removeAllItems()
        micDevicePopup.addItem(withTitle: "系統預設")
        for device in devices {
            micDevicePopup.addItem(withTitle: device.name)
            micDevicePopup.lastItem?.representedObject = device.uniqueID
        }
        micDevicePopup.selectItem(at: sel.index)
    }

    @objc private func micDeviceChanged() {
        AppSettings.recordMicrophoneDeviceID = micDevicePopup.selectedItem?.representedObject as? String
        updateMicMonitorState()
    }

    /// 依「頁面是否顯示中」＋「開關」＋「選中裝置」決定電平監看的啟停，**真正的唯一出口**
    /// ——換裝置、開關切換、幽靈裝置清鍵、頁面顯示/隱藏，全部只透過這個方法碰
    /// `micLevelMonitor.start()`/`stop()`，呼叫端不直接呼叫兩者（fix round 1，team-lead 審查
    /// 抓到先前 `recordMicToggled`／`viewWillDisappear` 繞過這裡、註解名實不符）。
    /// `MicLevelMonitor.start()` 內部自己會先 stop 舊的，換裝置直接重掛即可，不需要呼叫端自己
    /// 拆成「先 stop 再 start」兩步。
    private func updateMicMonitorState() {
        guard isViewVisible, AppSettings.recordMicrophone else {
            micLevelMonitor.stop()
            return
        }
        micLevelMonitor.start(deviceID: AppSettings.recordMicrophoneDeviceID)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isViewVisible = true
        updateMicMonitorState()
    }

    /// 分頁切走／設定視窗關閉都會走這裡（NSTabViewController 的 view containment：非顯示中
    /// 分頁的 view 本來就不在階層內）。`isViewVisible = false` 讓 `updateMicMonitorState()`
    /// 的 guard 直接落到 stop()，不留著背景還開著麥克風 session。
    override func viewWillDisappear() {
        super.viewWillDisappear()
        isViewVisible = false
        updateMicMonitorState()
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
    /// 漸進展開：核取方塊狀態同步連動下方裝置選擇＋電平表列的顯示，並掛/停電平監看。
    @objc private func recordMicToggled() {
        guard recordMicCheckbox.state == .on else {
            AppSettings.recordMicrophone = false
            micDetailRow.isHidden = true
            updateMicMonitorState()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                AppSettings.recordMicrophone = granted
                self.recordMicCheckbox.state = granted ? .on : .off
                self.micDetailRow.isHidden = !granted
                // granted＝false 時 AppSettings.recordMicrophone 已同步變 false，
                // updateMicMonitorState() 的 guard 自然落到 stop()——不需要另外分支呼叫 stop()。
                self.updateMicMonitorState()
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
        let nearest = AppSettings.nearestOption(AppSettings.watchdogOptions, to: current) ?? 60
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
        let nearest = AppSettings.nearestOption(AppSettings.scrollWatchdogOptions, to: current) ?? 300
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
        let nearest = AppSettings.nearestOption(AppSettings.scrollMaxHeightOptions, to: current) ?? 30000
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

extension CaptureSettingsViewController: NSMenuDelegate {
    /// 麥克風裝置 popup 展開前重新列舉（涵蓋熱插拔）——見 `populateMicDevicePopup` 的呼叫時機說明。
    func menuWillOpen(_ menu: NSMenu) {
        populateMicDevicePopup()
    }
}
