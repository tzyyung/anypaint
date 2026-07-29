import AppKit

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
    private var mode: Mode = .armed

    public override init() { super.init() }

    /// 秒數欄解析：空白/非整數/≤0 → nil（不限）；有值 clamp 1...600（設計文件 §1「1–600 整數秒」）。
    /// 用 `Int(t)`，不用 `Double(t)`：小數輸入（例如 "2.5"）視為無效——同空白一樣回 nil、
    /// 靜默當成不限，不在 HUD 上顯示錯誤。待命階段的 HUD 沒有錯誤訊息的容身之處
    /// （`showMessage` 是給選區太小用的），與其半吊子地只挑得出某些無效輸入來提示、
    /// 不如統一「無效輸入＝不限」這一種行為，簡單且可預期。
    public var durationSeconds: Double? {
        let t = durationField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), v > 0 else { return nil }
        return Double(min(600, max(1, v)))
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
        clockLabel.stringValue = "● " + RecordMath.hudClockText(elapsedSeconds: elapsed, limitSeconds: limit)
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

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // 高於選區 overlay
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        // canBecomeKey 不覆寫——borderless NSPanel 預設即非 key；不 makeKey、不 activate，
        // 點按鈕靠 NSButton 在 nonactivating panel 上的正常 hit-test（AppKit 對滑鼠事件一律送給
        // 游標下的視窗，與該視窗是否為 key 無關；已查證 nonactivatingPanel 官方文件與已知問題）。
        // durationField 例外：文字輸入需要 key window 才能收到按鍵。becomesKeyOnlyIfNeeded 讓面板
        // 平時維持非 key（不搶前景），只在使用者點進欄位、真的要打字時才允許成為 key——
        // 兩者都要（accessory app 不 activate 就進不了前景，nonactivating panel 天生不搶焦點）。
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

        durationSuffix.textColor = .white
        durationSuffix.font = .systemFont(ofSize: 12, weight: .regular)

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        // 佈局：clockLabel 左、（durationField／durationSuffix，僅 armed）、primaryButton／cancelButton 右
        // （NSStackView，spec 骨架註記）。
        let stack = NSStackView(views: [clockLabel, durationField, durationSuffix, primaryButton, cancelButton])
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
