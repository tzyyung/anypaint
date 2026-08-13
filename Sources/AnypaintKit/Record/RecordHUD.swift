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
        var origin = CGPoint(x: selection.midX - p.frame.width / 2, y: selection.minY - p.frame.height - 12)
        if origin.y < screen.visibleFrame.minY { origin.y = selection.maxY + 12 }
        origin.x = min(max(screen.visibleFrame.minX, origin.x), screen.visibleFrame.maxX - p.frame.width)
        p.setFrameOrigin(origin)
        p.orderFront(nil)
    }

    public func updateClock(elapsed: Double, limit: Double?) {
        let prefix = micActive ? "🎙 ● " : "● "
        clockLabel.stringValue = prefix + RecordMath.hudClockText(elapsedSeconds: elapsed, limitSeconds: limit)
        clockLabel.textColor = .systemRed
    }

    public func showMessage(_ text: String) {
        clockLabel.stringValue = text
        clockLabel.textColor = .systemYellow
    }

    public func dismiss() {
        panel?.orderOut(nil)
        onStart = nil
        onStop = nil
        onCancel = nil
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

        // 佈局：clockLabel 左（🎙 徽章前綴內建於其文字，不佔獨立位置）、
        // （durationField／durationSuffix，僅 armed）、primaryButton／cancelButton 右、
        // noticeLabel（隱藏時不佔位）。
        let stack = NSStackView(views: [clockLabel, durationField, durationSuffix, primaryButton, cancelButton, noticeLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        p.contentView = content
        panel = p
    }

    /// armed → 顯示秒數欄＋提示文案、primary=「開始」；recording → 隱藏秒數欄、primary=「停止」
    /// （時鐘文字由 updateClock 另外驅動，此處不覆寫 clockLabel）。
    private func configure(mode: Mode) {
        self.mode = mode
        switch mode {
        case .armed:
            durationField.isHidden = false
            durationSuffix.isHidden = false
            primaryButton.title = "開始"
            clockLabel.textColor = .white
            clockLabel.stringValue = "按「開始」錄製；秒數欄可留白"
        case .recording:
            durationField.isHidden = true
            durationSuffix.isHidden = true
            primaryButton.title = "停止"
        }
    }

    @objc private func primaryTapped() {
        switch mode {
        case .armed: onStart?()
        case .recording: onStop?()
        }
    }
    @objc private func cancelTapped() { onCancel?() }
}
