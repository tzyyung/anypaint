import AppKit
import AVFoundation

// 實機教訓（round 2）：ScrollHUD 純按鈕面板不覆寫 canBecomeKey（borderless NSPanel 預設非 key），
// 按鈕靠 hit-test 不需要 key window。本 HUD 多了 durationField 這個文字輸入欄——canBecomeKey
// 預設 false 時面板永遠成不了 key window，文字欄收不到任何按鍵。改用 ScrollSelectionOverlay 同款：
// 子類覆寫 canBecomeKey=true，保留 becomesKeyOnlyIfNeeded=true（只有點進文字欄才真的取 key）。
private final class RecordHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// pill 開關（🎙/🔊/游標）：藍色填底＝開，取代原本的 NSButton(checkboxWithTitle:)。
/// 用 pushOnPushOff 讓點擊自動切 state 並送 action；state 改變時換 layer 底色。
private final class PillToggle: NSButton {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { fatalError() }
    private func setup() {
        setButtonType(.pushOnPushOff)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 12)
        contentTintColor = .white
        updateFill()
    }
    override var state: NSControl.StateValue { didSet { updateFill() } }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize; s.width += 20; s.height = 26; return s
    }
    private func updateFill() {
        layer?.backgroundColor = (state == .on
            ? NSColor.controlAccentColor.withAlphaComponent(0.34)
            : NSColor(white: 1, alpha: 0.14)).cgColor
        layer?.borderWidth = state == .on ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
    }
}

/// 統一 morph 錄影工具列（spec 2026-08-14）。同一面板、同一錨點貫穿：
/// - `.armed`：二層——第一層 🎙/🔊 pill＋⚙＋開始/取消；點 ⚙ 展開第二層（裝置/音量/秒數/游標）。
/// - `.recording`：極簡列——● 時鐘＋電平＋停止。
/// - `.done` / `.doneFailed`：contentView 換成 `RecordDoneView`（縮圖/播放/Finder/複製/重錄）。
@MainActor
public final class RecordHUDController: NSObject {
    public enum Mode { case armed, recording, done, doneFailed }

    public var onStart: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// 錄音裝置/音訊/游標在 HUD 被改動時通知（RecordSession 重掛待命試音錶／更新資訊）。
    public var onOptionsChanged: (() -> Void)?
    /// 完成態：↺ 重錄（沿用同選區）／面板關閉。
    public var onReRecord: (() -> Void)?
    public var onDoneClosed: (() -> Void)?

    private var panel: RecordHUDPanel?

    // 第一層（tier1）＋資訊列控制項
    private let clockLabel = NSTextField(labelWithString: "")
    private let micChip = PillToggle()
    private let systemAudioChip = PillToggle()
    private let levelMeter = LevelMeterView(frame: NSRect(x: 0, y: 0, width: 46, height: 8))
    private let gearButton = NSButton(title: "⚙", target: nil, action: nil)
    private let primaryButton = NSButton(title: "開始", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")

    // 第二層（tier2，點 ⚙ 展開）
    private let micDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeIcon = NSTextField(labelWithString: "🔊")
    private let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let soundSettingsButton = NSButton(title: "聲音設定…", target: nil, action: nil)
    private let durationField = NSTextField(string: "")
    private let durationSuffix = NSTextField(labelWithString: "秒（空白＝不限）")
    private let cursorChip = PillToggle()

    // 版面容器
    private var armedStack: NSStackView!
    private var tier2Container: NSStackView!
    private let doneView = RecordDoneView()

    private var mode: Mode = .armed
    private var micUIVisible = false
    private var regionPx: (w: Int, h: Int) = (0, 0)
    /// 第二層展開狀態（記憶，spec §3.4）。
    private var tier2Expanded: Bool {
        get { AppSettings.recordOptionsExpanded }
        set { AppSettings.recordOptionsExpanded = newValue }
    }
    /// 錄製中是否含麥克風（影響時鐘徽章）。
    public var micActive = false

    // 定位記憶（morph 時重算 origin 用；showDone 在 overlay 已 dismiss 後也能定位）。
    private var lastSelection: CGRect = .zero
    private var lastScreen: NSScreen?

    // 完成態：generation token（修 #6，防遲到縮圖落到重用/新面板）＋單一收起計時器（修 #4）＋Esc monitor。
    private var doneGeneration = 0
    private var doneHideWork: DispatchWorkItem?
    private var doneEscMonitor: Any?

    private var noticeHideWork: DispatchWorkItem?

    public override init() { super.init() }

    /// 秒數欄解析：空白/非整數/≤0 → nil（不限）；有值 clamp 1...600。
    public var durationSeconds: Double? { RecordMath.parseRecordDuration(durationField.stringValue) }

    // MARK: 顯示（armed / recording）

    public func show(near selection: CGRect, on screen: NSScreen, mode: Mode) {
        if panel == nil { buildPanel() }
        lastSelection = selection
        lastScreen = screen
        configure(mode: mode)
        reposition()
        panel?.orderFront(nil)
    }

    public func updateClock(elapsed: Double, limit: Double?) {
        let prefix = micActive ? "🎙 ● " : "● "
        clockLabel.stringValue = prefix + RecordMath.hudClockText(elapsedSeconds: elapsed, limitSeconds: limit)
        clockLabel.textColor = .systemRed
    }

    public func showMessage(_ text: String) {
        clockLabel.isHidden = false
        clockLabel.stringValue = text
        clockLabel.textColor = .systemYellow
        reposition()
    }

    public func dismiss() {
        cancelDoneTimers()
        panel?.orderOut(nil)
        onStart = nil; onStop = nil; onCancel = nil
        onReRecord = nil; onDoneClosed = nil
    }

    // MARK: 完成態（取代 RecordSavedNotice；同一面板原地 morph）

    /// 成功完成：morph 成 done 卡（縮圖非同步生成）。`near`／`on` 用 session 存的選區/螢幕。
    public func showDone(near selection: CGRect, on screen: NSScreen,
                         url: URL, durationSec: Double, sizeBytes: Int64, saveDirectory: URL?) {
        if panel == nil { buildPanel() }
        lastSelection = selection; lastScreen = screen
        mode = .done
        doneGeneration &+= 1
        let meta = RecordHUDInfo.doneMeta(durationSec: durationSec,
                                          widthPx: regionPx.w, heightPx: regionPx.h, bytes: sizeBytes)
        doneView.onAction = { [weak self] in self?.handleDoneAction($0) }
        doneView.configureSuccess(url: url, name: url.lastPathComponent, meta: meta, saveDirectory: saveDirectory)
        presentDoneContent()
        generateThumbnail(url: url, token: doneGeneration)
    }

    /// 失敗完成：morph 成 done 卡失敗態。
    public func showDoneFailed(near selection: CGRect, on screen: NSScreen,
                               detail: String, saveDirectory: URL?) {
        if panel == nil { buildPanel() }
        lastSelection = selection; lastScreen = screen
        mode = .doneFailed
        doneGeneration &+= 1
        doneView.onAction = { [weak self] in self?.handleDoneAction($0) }
        doneView.configureFailed(detail: detail, saveDirectory: saveDirectory)
        presentDoneContent()
    }

    private func presentDoneContent() {
        guard let p = panel else { return }
        cancelDoneTimers()
        p.contentView = doneView
        p.layoutIfNeeded()                     // 修 #7：用 done 態真實高度算 origin
        applyContentSize()
        reposition()
        p.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)   // 修 #9：accessory app 平時非前景,讓按鈕確實可點
        armDoneAutoDismiss()
        installDoneEscMonitor()
    }

    private func handleDoneAction(_ action: RecordDonePolicy.Action) {
        switch action {
        case .reRecord:
            cancelDoneTimers()
            onReRecord?()
        case .close:
            cancelDoneTimers()
            panel?.orderOut(nil)
            onDoneClosed?()
        case .play, .reveal, .copy:
            if RecordDonePolicy.dismissesPanel(after: action) {
                cancelDoneTimers()
                panel?.orderOut(nil)
                onDoneClosed?()
            }
        case .drag:
            break   // 拖曳不收面板（可連續拖多個 app）
        }
    }

    private func armDoneAutoDismiss() {
        doneHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.mode == .done || self.mode == .doneFailed else { return }   // 修 #4：新錄製已接手就別收
            self.panel?.orderOut(nil)
            self.onDoneClosed?()
            self.cancelDoneTimers()
        }
        doneHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RecordDonePolicy.dismissAfterSeconds, execute: work)
    }

    private func installDoneEscMonitor() {
        removeDoneEscMonitor()
        doneEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.keyCode == 53, self.mode == .done || self.mode == .doneFailed else { return ev }
            self.cancelDoneTimers(); self.panel?.orderOut(nil); self.onDoneClosed?()
            return nil
        }
    }
    private func removeDoneEscMonitor() {
        if let m = doneEscMonitor { NSEvent.removeMonitor(m); doneEscMonitor = nil }
    }
    private func cancelDoneTimers() { doneHideWork?.cancel(); doneHideWork = nil; removeDoneEscMonitor() }

    /// 縮圖：非同步生成（`generateCGImageAsynchronously`，macOS 15+，非棄用 API），回主緒前守
    /// token＋mode＋檔案仍在（修 #6）。失敗／遲到→保留佔位 ▶。
    private func generateThumbnail(url: URL, token: Int) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 240, height: 168)
        gen.generateCGImageAsynchronously(for: .zero) { [weak self] cg, _, _ in
            guard let cg else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            Task { @MainActor in
                guard let self, token == self.doneGeneration, self.mode == .done,
                      FileManager.default.fileExists(atPath: url.path) else { return }
                self.doneView.setThumbnail(img)
            }
        }
    }

    // MARK: 麥克風電平

    public func setMicEnabled(_ enabled: Bool, deviceName: String? = nil) {
        micUIVisible = enabled
        levelMeter.isHidden = !enabled
        if !enabled { setNoSignal(false); setMicLevel(0) }
    }
    public func setMicLevel(_ level: Float) { levelMeter.level = level }
    public func setNoSignal(_ show: Bool) {
        guard micUIVisible else { noticeLabel.isHidden = true; return }
        noticeHideWork?.cancel()
        noticeLabel.stringValue = show ? "麥克風無訊號，檢查裝置" : ""
        noticeLabel.isHidden = !show
    }
    public func showTransientNotice(_ text: String) {
        noticeHideWork?.cancel()
        noticeLabel.stringValue = text
        noticeLabel.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.noticeLabel.isHidden = true }
        noticeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: 資訊列

    public func setRegion(widthPx: Int, heightPx: Int) { regionPx = (widthPx, heightPx); refreshInfo() }
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
        case .done, .doneFailed:
            break
        }
    }

    // MARK: 版面

    private func buildPanel() {
        let p = RecordHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true

        clockLabel.textColor = .white
        clockLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        clockLabel.lineBreakMode = .byTruncatingTail
        clockLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureChip(micChip, title: "🎙 麥克風", action: #selector(micToggled))
        configureChip(systemAudioChip, title: "🔊 系統聲", action: #selector(systemAudioToggled))
        configureChip(cursorChip, title: "👆 游標", action: #selector(cursorToggled))

        levelMeter.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.widthAnchor.constraint(equalToConstant: 46).isActive = true
        levelMeter.heightAnchor.constraint(equalToConstant: 8).isActive = true
        levelMeter.isHidden = true

        gearButton.bezelStyle = .rounded
        gearButton.isBordered = false
        gearButton.font = .systemFont(ofSize: 14)
        gearButton.contentTintColor = .white
        gearButton.target = self; gearButton.action = #selector(gearToggled)

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self; primaryButton.action = #selector(primaryTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self; cancelButton.action = #selector(cancelTapped)

        infoLabel.textColor = NSColor(white: 0.78, alpha: 1)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        noticeLabel.textColor = .systemYellow
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.isHidden = true
        noticeLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        // tier2 控制項
        micDevicePopup.target = self; micDevicePopup.action = #selector(micDeviceChanged)
        micDevicePopup.controlSize = .small
        micDevicePopup.font = .systemFont(ofSize: 11)
        volumeIcon.font = .systemFont(ofSize: 11); volumeIcon.textColor = .white
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        volumeSlider.controlSize = .mini
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        soundSettingsButton.target = self; soundSettingsButton.action = #selector(soundSettingsTapped)
        soundSettingsButton.bezelStyle = .rounded
        soundSettingsButton.controlSize = .small
        (soundSettingsButton.cell as? NSButtonCell)?.font = .systemFont(ofSize: 11)
        durationField.font = .systemFont(ofSize: 12)
        durationField.placeholderString = "10"
        durationField.alignment = .right
        durationField.translatesAutoresizingMaskIntoConstraints = false
        durationField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        durationField.target = self; durationField.action = #selector(primaryTapped)
        durationSuffix.textColor = NSColor(white: 0.78, alpha: 1)
        durationSuffix.font = .systemFont(ofSize: 11)

        let tier1 = NSStackView(views: [clockLabel, micChip, levelMeter, systemAudioChip,
                                        spacer(), gearButton, primaryButton, cancelButton])
        tier1.orientation = .horizontal; tier1.alignment = .centerY; tier1.spacing = 7

        let infoRow = NSStackView(views: [infoLabel, noticeLabel])
        infoRow.orientation = .horizontal; infoRow.alignment = .centerY; infoRow.spacing = 8

        let deviceRow = NSStackView(views: [labeled("裝置"), micDevicePopup])
        deviceRow.orientation = .horizontal; deviceRow.alignment = .centerY; deviceRow.spacing = 6
        let volumeRow = NSStackView(views: [volumeIcon, volumeSlider, soundSettingsButton])
        volumeRow.orientation = .horizontal; volumeRow.alignment = .centerY; volumeRow.spacing = 6
        let durationRow = NSStackView(views: [labeled("限時"), durationField, durationSuffix, spacer(), cursorChip])
        durationRow.orientation = .horizontal; durationRow.alignment = .centerY; durationRow.spacing = 6

        tier2Container = NSStackView(views: [separator(), deviceRow, volumeRow, durationRow])
        tier2Container.orientation = .vertical; tier2Container.alignment = .leading; tier2Container.spacing = 7

        armedStack = NSStackView(views: [tier1, infoRow, tier2Container])
        armedStack.orientation = .vertical; armedStack.alignment = .leading; armedStack.spacing = 6
        armedStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        armedStack.translatesAutoresizingMaskIntoConstraints = false

        p.contentView = armedStack
        panel = p
    }

    private func configureChip(_ chip: PillToggle, title: String, action: Selector) {
        chip.title = title
        chip.target = self
        chip.action = action
    }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }
    private func separator() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return v
    }
    private func labeled(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.textColor = NSColor(white: 0.78, alpha: 1); t.font = .systemFont(ofSize: 11)
        return t
    }

    private func applyContentSize() {
        guard let p = panel, let cv = p.contentView else { return }
        cv.layoutSubtreeIfNeeded()
        p.setContentSize(cv.fittingSize)
    }
    private func reposition() {
        guard let p = panel, let scr = lastScreen else { return }
        p.setFrameOrigin(SelectionGeometry.hudOrigin(selection: lastSelection, panelSize: p.frame.size,
                                                      visibleFrame: scr.visibleFrame))
    }

    /// armed：二層（依 tier2Expanded 展開）；recording：極簡列（收 chips/gear/cancel、時鐘出）。
    private func configure(mode: Mode) {
        self.mode = mode
        cancelDoneTimers()
        if panel?.contentView !== armedStack { panel?.contentView = armedStack }
        let armed = (mode == .armed)
        clockLabel.isHidden = armed
        micChip.isHidden = !armed
        systemAudioChip.isHidden = !armed
        gearButton.isHidden = !armed
        cancelButton.isHidden = !armed
        tier2Container.isHidden = !(armed && tier2Expanded)
        switch mode {
        case .armed:
            syncOptionControls()
            gearButton.title = tier2Expanded ? "⚙ 收合" : "⚙ 更多"
            primaryButton.title = "開始"
        case .recording:
            primaryButton.title = "停止"
        case .done, .doneFailed:
            break
        }
        refreshInfo()
        applyContentSize()
    }

    /// 待命選項：填裝置下拉、依設定設 pill 開關與音量。
    private func syncOptionControls() {
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
        let micOn = AppSettings.recordMicrophone
        micChip.state = micOn ? .on : .off
        systemAudioChip.state = AppSettings.recordSystemAudio ? .on : .off
        cursorChip.state = AppSettings.recordShowsCursor ? .on : .off
        micDevicePopup.isEnabled = micOn
        let vol = micOn ? AudioInputVolume.volume(deviceUID: AppSettings.recordMicrophoneDeviceID) : nil
        let volSupported = (vol != nil)
        volumeIcon.isHidden = !(micOn && volSupported)
        volumeSlider.isHidden = !(micOn && volSupported)
        if let vol { volumeSlider.doubleValue = Double(vol) }
        soundSettingsButton.isHidden = !micOn
    }

    // MARK: 動作

    @objc private func primaryTapped() {
        switch mode {
        case .armed: onStart?()
        case .recording: onStop?()
        default: break
        }
    }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func gearToggled() {
        tier2Expanded.toggle()
        configure(mode: .armed)
        reposition()
    }
    @objc private func micToggled() {
        AppSettings.recordMicrophone = (micChip.state == .on)
        micDevicePopup.isEnabled = (micChip.state == .on)
        syncOptionControls()
        applyContentSize(); reposition()
        onOptionsChanged?()
    }
    @objc private func systemAudioToggled() { AppSettings.recordSystemAudio = (systemAudioChip.state == .on) }
    @objc private func cursorToggled() { AppSettings.recordShowsCursor = (cursorChip.state == .on) }
    @objc private func micDeviceChanged() {
        AppSettings.recordMicrophoneDeviceID = micDevicePopup.selectedItem?.representedObject as? String
        onOptionsChanged?()
    }
    @objc private func volumeChanged() {
        AudioInputVolume.setVolume(deviceUID: AppSettings.recordMicrophoneDeviceID, Float(volumeSlider.doubleValue))
    }
    @objc private func soundSettingsTapped() { AudioInputVolume.openSoundSettings() }
}
