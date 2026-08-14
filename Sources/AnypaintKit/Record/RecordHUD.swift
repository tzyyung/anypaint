import AppKit

// 實機教訓（round 2）：ScrollHUD 純按鈕面板不覆寫 canBecomeKey（borderless NSPanel 預設非 key），
// 按鈕靠 hit-test 不需要 key window。本 HUD 多了 durationField 這個文字輸入欄——canBecomeKey
// 預設 false 時面板永遠成不了 key window，文字欄收不到任何按鍵，點了打不了字（round 1 的
// becomesKeyOnlyIfNeeded 因此完全無效：它只決定「何時」變 key，前提是 canBecomeKey 本身要為
// true）。改用 ScrollSelectionOverlay.swift 的 ScrollSelectionWindow 同一手法：子類覆寫
// canBecomeKey=true，並保留 becomesKeyOnlyIfNeeded=true 限制「只有點進文字欄才真的取 key」，
// 兩者疊加才是「按鈕不搶焦點、文字欄可以打字」。canBecomeMain 維持 false——HUD 不該搶走
// app 的 main window 身分（menu bar app 沒有一般意義的 main window）。
private final class RecordHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 動畫截圖 HUD。視窗配置與擺位沿用 ScrollHUDController 成例（四件套缺一有坑，見該檔頭註）。
/// armed：〔秒數欄（空白=不限）〕〔開始〕〔取消〕；recording：〔● 時鐘〕〔停止〕〔取消〕。
@MainActor
public final class RecordHUDController: NSObject {
    public enum Mode { case armed, recording }

    public var onStart: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private let clockLabel = NSTextField(labelWithString: "")
    private let durationField = NSTextField(string: "")
    private let durationSuffix = NSTextField(labelWithString: "秒（空白＝不限）")
    private let primaryButton = NSButton(title: "開始", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    /// 錄前選項工具列（Task #2，QuickRecorder 式）：錄音裝置下拉＋音訊/游標快速開關。
    private let micDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let micCheck = NSButton(checkboxWithTitle: "麥克風", target: nil, action: nil)
    private let systemAudioCheck = NSButton(checkboxWithTitle: "系統聲", target: nil, action: nil)
    private let cursorCheck = NSButton(checkboxWithTitle: "游標", target: nil, action: nil)
    /// 輸入音量滑桿（改系統裝置輸入增益）＋聲音設定捷徑（Task #1/#3）。
    private let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeIcon = NSTextField(labelWithString: "🔊")
    private let soundSettingsButton = NSButton(title: "聲音設定", target: nil, action: nil)
    /// 資訊列：待命顯示「存至 <dir> · <W>×<H> px」；錄製顯示「<W>×<H> px · <size>」。
    private let infoLabel = NSTextField(labelWithString: "")
    private let levelMeter = LevelMeterView(frame: NSRect(x: 0, y: 0, width: 60, height: 12))
    private var micUIVisible = false
    /// 目前選區的像素尺寸（供資訊列；RecordSession 在 show 前 setRegion）。
    private var regionPx: (w: Int, h: Int) = (0, 0)
    /// 錄音裝置/音訊/游標設定被使用者在 HUD 改動時通知（RecordSession 重掛待命試音錶／更新資訊）。
    public var onOptionsChanged: (() -> Void)?
    /// 短暫提示行（例如麥克風權限降級），預設隱藏；樣式照 durationSuffix。
    private let noticeLabel = NSTextField(labelWithString: "")
    private var mode: Mode = .armed
    /// 錄製中是否包含麥克風（Task 13；由 RecordSession 用降級後的 options 設定）。
    /// 影響 updateClock 的徽章前綴，本身不驅動任何佈局。
    public var micActive = false
    /// showTransientNotice 的隱藏計時器：存起來才能在 3 秒內第二次呼叫時取消上一顆
    /// （T11 審查移交必修 b——否則兩次提示疊加時，第一顆計時器會把第二次的提示提前關掉）。
    private var noticeHideWork: DispatchWorkItem?

    public override init() { super.init() }

    /// 秒數欄解析：空白/非整數/≤0 → nil（不限）；有值 clamp 1...600（設計文件 §1「1–600 整數秒」）。
    /// 用 `Int(t)`，不用 `Double(t)`：小數輸入（例如 "2.5"）視為無效——同空白一樣回 nil、
    /// 靜默當成不限，不在 HUD 上顯示錯誤。待命階段的 HUD 沒有錯誤訊息的容身之處
    /// （`showMessage` 是給選區太小用的），與其半吊子地只挑得出某些無效輸入來提示、
    /// 不如統一「無效輸入＝不限」這一種行為，簡單且可預期。
    public var durationSeconds: Double? {
        RecordMath.parseRecordDuration(durationField.stringValue)
    }

    /// 位置：選區下緣外 12pt；貼近螢幕底時翻到上緣外；水平 clamp 進螢幕（避免貼邊選區把 HUD 推出畫面）。
    public func show(near selection: CGRect, on screen: NSScreen, mode: Mode) {
        if panel == nil { buildPanel() }
        configure(mode: mode)
        let p = panel!
        p.setFrameOrigin(SelectionGeometry.hudOrigin(selection: selection, panelSize: p.frame.size,
                                                     visibleFrame: screen.visibleFrame))
        p.orderFront(nil)
    }

    public func updateClock(elapsed: Double, limit: Double?) {
        let prefix = micActive ? "🎙 ● " : "● "
        clockLabel.stringValue = prefix + RecordMath.hudClockText(elapsedSeconds: elapsed, limitSeconds: limit)
        clockLabel.textColor = .systemRed
    }

    public func showMessage(_ text: String) {
        clockLabel.isHidden = false   // armed 模式預設隱藏時鐘,錯誤訊息要強制顯示（選區太小）
        clockLabel.stringValue = text
        clockLabel.textColor = .systemYellow
    }

    public func dismiss() {
        panel?.orderOut(nil)
        onStart = nil
        onStop = nil
        onCancel = nil
    }

    // MARK: 麥克風電平（Task B2）

    /// 顯示/隱藏麥克風電平表（錄影含麥克風才顯示）。裝置名改由裝置下拉呈現,不再另有標籤。
    public func setMicEnabled(_ enabled: Bool, deviceName: String? = nil) {
        micUIVisible = enabled
        levelMeter.isHidden = !enabled
        if !enabled { setNoSignal(false); setMicLevel(0) }
    }

    /// 設定目前選區像素尺寸（資訊列用）。show(mode:) 前呼叫。
    public func setRegion(widthPx: Int, heightPx: Int) {
        regionPx = (widthPx, heightPx)
        refreshInfo()
    }

    /// 錄製中更新檔案大小（資訊列）。
    public func setRecordingBytes(_ bytes: Int64?) {
        infoLabel.stringValue = RecordHUDInfo.recordingInfo(widthPx: regionPx.w, heightPx: regionPx.h, bytes: bytes)
    }

    private func refreshInfo() {
        switch mode {
        case .armed:
            infoLabel.stringValue = RecordHUDInfo.armedInfo(saveDirectory: AppSettings.recordSaveDirectory,
                                                            widthPx: regionPx.w, heightPx: regionPx.h)
        case .recording:
            infoLabel.stringValue = RecordHUDInfo.recordingInfo(widthPx: regionPx.w, heightPx: regionPx.h, bytes: nil)
        }
    }

    /// 待命選項工具列初始化：填裝置下拉、依設定設好勾選狀態。armed configure 時呼叫。
    private func syncOptionControls() {
        // 裝置下拉：系統預設 + 各裝置（representedObject＝uniqueID；nil＝系統預設）。
        micDevicePopup.removeAllItems()
        micDevicePopup.addItem(withTitle: "系統預設")
        micDevicePopup.lastItem?.representedObject = nil as String?
        let devices = AudioInputDeviceList.all()
        let saved = AppSettings.recordMicrophoneDeviceID
        var selectIndex = 0
        for (i, d) in devices.enumerated() {
            micDevicePopup.addItem(withTitle: d.name)
            micDevicePopup.lastItem?.representedObject = d.uniqueID
            if d.uniqueID == saved { selectIndex = i + 1 }
        }
        micDevicePopup.selectItem(at: selectIndex)
        micCheck.state = AppSettings.recordMicrophone ? .on : .off
        systemAudioCheck.state = AppSettings.recordSystemAudio ? .on : .off
        cursorCheck.state = AppSettings.recordShowsCursor ? .on : .off
        let micOn = AppSettings.recordMicrophone
        micDevicePopup.isEnabled = micOn   // 沒開麥克風時裝置下拉停用
        // 輸入音量滑桿：裝置支援才顯示且可調（部分裝置唯讀/不支援）。
        let vol = micOn ? AudioInputVolume.volume(deviceUID: AppSettings.recordMicrophoneDeviceID) : nil
        let volSupported = (vol != nil)
        volumeIcon.isHidden = !(micOn && volSupported)
        volumeSlider.isHidden = !(micOn && volSupported)
        if let vol { volumeSlider.doubleValue = Double(vol) }
        soundSettingsButton.isHidden = !micOn   // 麥克風開才給聲音設定捷徑
    }

    /// 即時電平（線性 RMS 0..1）。
    public func setMicLevel(_ level: Float) { levelMeter.level = level }

    /// 無訊號警告（常駐,非 3 秒瞬時）：待命/錄製連續靜音達門檻時亮黃字,有訊號即清。
    public func setNoSignal(_ show: Bool) {
        guard micUIVisible else { noticeLabel.isHidden = true; return }
        noticeHideWork?.cancel()   // 蓋掉任何 transient 隱藏排程
        noticeLabel.stringValue = show ? "麥克風無訊號，檢查裝置" : ""
        noticeLabel.isHidden = !show
    }

    /// 短暫提示（3 秒自動清除）：借用既有 clockLabel 樣式下方另一行黃字。
    /// 隱藏用可取消的 DispatchWorkItem（T11 審查移交必修 b）：3 秒內再呼叫一次，先取消
    /// 舊的隱藏排程再重新排 3 秒，避免第一顆計時器把第二次的提示提前關掉。
    public func showTransientNotice(_ text: String) {
        noticeHideWork?.cancel()
        noticeLabel.stringValue = text
        noticeLabel.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.noticeLabel.isHidden = true
        }
        noticeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func buildPanel() {
        let p = RecordHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // 高於選區 overlay
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        // canBecomeKey=true 由 RecordHUDPanel 子類覆寫（見檔頭註：文字欄位需要 key window）。
        // becomesKeyOnlyIfNeeded 限制「只有點進 durationField 才真的取 key」——按鈕仍靠 hit-test，
        // 不因為 canBecomeKey 變 true 就搶走前景／偷走其他視窗的 key 狀態（nonactivating panel
        // 本身也不 makeKey、不 activate，兩層限制疊加）。
        p.becomesKeyOnlyIfNeeded = true

        clockLabel.textColor = .white
        clockLabel.font = .systemFont(ofSize: 12, weight: .regular)
        clockLabel.lineBreakMode = .byTruncatingTail
        clockLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationField.font = .systemFont(ofSize: 12, weight: .regular)
        durationField.placeholderString = "10"
        durationField.alignment = .right
        durationField.translatesAutoresizingMaskIntoConstraints = false
        durationField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        // 秒數欄按 Enter＝按「開始」（armed 唯一可能狀態；recording 時欄位已隱藏收不到打字）。
        // NSTextField 預設 sendsActionOnEndEditing=false，action 只在按下 Return 時觸發，
        // 點別處讓欄位失焦**不會**誤發——與 primaryButton 共用同一個 selector 安全。
        durationField.target = self
        durationField.action = #selector(primaryTapped)

        durationSuffix.textColor = .white
        durationSuffix.font = .systemFont(ofSize: 12, weight: .regular)

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        noticeLabel.textColor = .systemYellow
        noticeLabel.font = .systemFont(ofSize: 12, weight: .regular)
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.isHidden = true
        // T11 審查移交必修 (a)：版面擠爆時 clockLabel（跳動中的錄製時鐘）不得先被壓縮——
        // clockLabel 已是 .defaultLow(250)，noticeLabel 給更低的優先度，擠爆時先讓 noticeLabel
        // 的寬度讓步（它本來就有 lineBreakMode 截尾兜底）。
        noticeLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)

        levelMeter.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.widthAnchor.constraint(equalToConstant: 60).isActive = true
        levelMeter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        levelMeter.isHidden = true

        // 選項工具列控制項（Task #2）。
        micDevicePopup.target = self; micDevicePopup.action = #selector(micDeviceChanged)
        micDevicePopup.controlSize = .small
        micDevicePopup.font = .systemFont(ofSize: 11)
        micCheck.target = self; micCheck.action = #selector(micCheckToggled)
        micCheck.controlSize = .small
        systemAudioCheck.target = self; systemAudioCheck.action = #selector(systemAudioToggled)
        systemAudioCheck.controlSize = .small
        cursorCheck.target = self; cursorCheck.action = #selector(cursorToggled)
        cursorCheck.controlSize = .small
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        volumeSlider.controlSize = .mini
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        soundSettingsButton.target = self; soundSettingsButton.action = #selector(soundSettingsTapped)
        soundSettingsButton.bezelStyle = .rounded
        soundSettingsButton.controlSize = .small
        (soundSettingsButton.cell as? NSButtonCell)?.font = .systemFont(ofSize: 11)
        for c in [micCheck, systemAudioCheck, cursorCheck] {
            c.setContentCompressionResistancePriority(.required, for: .horizontal)
            (c.cell as? NSButtonCell)?.font = .systemFont(ofSize: 11)
        }
        infoLabel.textColor = NSColor(white: 0.75, alpha: 1)
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 兩列佈局：上列＝控制（模式相依）；下列＝電平表＋資訊＋警告。
        volumeIcon.font = .systemFont(ofSize: 11)
        let controlRow = NSStackView(views: [clockLabel, micDevicePopup, micCheck, volumeIcon, volumeSlider,
                                             systemAudioCheck, cursorCheck, soundSettingsButton,
                                             durationField, durationSuffix, primaryButton, cancelButton])
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.spacing = 8
        let infoRow = NSStackView(views: [levelMeter, infoLabel, noticeLabel])
        infoRow.orientation = .horizontal
        infoRow.alignment = .centerY
        infoRow.spacing = 8

        let container = NSStackView(views: [controlRow, infoRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        container.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 76))
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        p.contentView = content
        panel = p
    }

    /// armed → 顯示秒數欄＋提示文案、primary=「開始」；recording → 隱藏秒數欄、primary=「停止」
    /// （時鐘文字由 updateClock 另外驅動，此處不覆寫 clockLabel）。
    private func configure(mode: Mode) {
        self.mode = mode
        let armed = (mode == .armed)
        // 待命才顯示選項工具列（裝置/音訊/游標/秒數）；錄製中收起,只留時鐘/停止。
        durationField.isHidden = !armed
        durationSuffix.isHidden = !armed
        micDevicePopup.isHidden = !armed
        micCheck.isHidden = !armed
        systemAudioCheck.isHidden = !armed
        cursorCheck.isHidden = !armed
        volumeIcon.isHidden = !armed          // 錄製中收起音量/聲音設定（syncOptionControls 會在 armed 再依支援與否調整）
        volumeSlider.isHidden = !armed
        soundSettingsButton.isHidden = !armed
        clockLabel.isHidden = armed          // 待命不顯示時鐘（改用提示文字放 infoLabel 前）
        switch mode {
        case .armed:
            syncOptionControls()             // 填裝置下拉＋依設定設勾選
            primaryButton.title = "開始"
        case .recording:
            primaryButton.title = "停止"
        }
        refreshInfo()
    }

    @objc private func primaryTapped() {
        switch mode {
        case .armed: onStart?()
        case .recording: onStop?()
        }
    }
    @objc private func cancelTapped() { onCancel?() }

    // MARK: 選項工具列動作（寫 AppSettings + 通知 RecordSession 重掛/更新）

    @objc private func micCheckToggled() {
        AppSettings.recordMicrophone = (micCheck.state == .on)
        micDevicePopup.isEnabled = (micCheck.state == .on)
        onOptionsChanged?()
    }
    @objc private func systemAudioToggled() {
        AppSettings.recordSystemAudio = (systemAudioCheck.state == .on)
    }
    @objc private func cursorToggled() {
        AppSettings.recordShowsCursor = (cursorCheck.state == .on)
    }
    @objc private func micDeviceChanged() {
        AppSettings.recordMicrophoneDeviceID = micDevicePopup.selectedItem?.representedObject as? String
        onOptionsChanged?()
    }
    @objc private func volumeChanged() {
        // 改系統裝置輸入增益（等同系統設定→聲音→輸入滑桿）；電平表會即時反映。
        AudioInputVolume.setVolume(deviceUID: AppSettings.recordMicrophoneDeviceID, Float(volumeSlider.doubleValue))
    }
    @objc private func soundSettingsTapped() { AudioInputVolume.openSoundSettings() }
}
