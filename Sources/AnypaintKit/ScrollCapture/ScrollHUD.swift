import AppKit

/// HUD 浮層：進度/提示＋按鈕。生產級四件套（spec §6，缺一有坑）：
/// nonactivatingPanel（不搶前景）、canBecomeKey=false（borderless NSPanel 預設即非 key，維持即可，
/// 不覆寫）、collectionBehavior 三件套（fullscreen app 上也顯示）、level 高於選區 overlay
/// （.screenSaver + 1）。繼承 NSObject 只為了給 NSButton 當 target-action 的接收者
/// （純 Swift class 無法作為 Objective-C selector 訊息目標）。
@MainActor
public final class ScrollHUDController: NSObject {
    public enum Mode { case armed, capturing }

    public var onStart: (() -> Void)?
    public var onDone: (() -> Void)?
    public var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "開始", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var mode: Mode = .armed

    public override init() { super.init() }

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

    /// GuidanceMessage → 繁中文案（spec §10 逐字）＋語氣色（警告黃／錯誤紅／中性白）。
    public func update(message: GuidanceMessage) {
        label.stringValue = text(for: message)
        label.textColor = tone(for: message)
    }

    public func dismiss() {
        panel?.orderOut(nil)
        onStart = nil
        onDone = nil
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

        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        // 佈局：label 左、primaryButton／cancelButton 右（NSStackView，spec 骨架註記）。
        let stack = NSStackView(views: [label, primaryButton, cancelButton])
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

    /// armed → primary=「開始」；capturing → primary=「完成」（spec 骨架註記）。
    private func configure(mode: Mode) {
        self.mode = mode
        switch mode {
        case .armed:
            primaryButton.title = "開始"
            label.stringValue = "拖曳調整選區，按「開始」開始滾動擷取"
        case .capturing:
            primaryButton.title = "完成"
        }
    }

    @objc private func primaryTapped() {
        switch mode {
        case .armed: onStart?()
        case .capturing: onDone?()
        }
    }
    @objc private func cancelTapped() { onCancel?() }

    private func tone(for m: GuidanceMessage) -> NSColor {
        switch m {
        case .slowDown, .hardToMatch, .mouseOutside: return .systemYellow
        case .gapNotStitched: return .systemRed
        case .progress, .backscrollTrimming, .backscrollAtOrigin, .bottomProbing, .deadReckoning:
            return .white
        }
    }
}

/// GuidanceMessage → 文案對照（spec §10 逐字）。
private func text(for m: GuidanceMessage) -> String {
    switch m {
    case .progress(let px): return "已拼接 \(px) px"
    case .slowDown: return "捲慢一點，重疊區太少"
    case .gapNotStitched: return "捲太快，這段沒接上——回捲到斷點附近再往下慢慢捲"
    case .mouseOutside: return "滑鼠留在框內才收得到滾輪"
    case .backscrollTrimming: return "回捲中——長圖尾端同步撤回"
    case .backscrollAtOrigin: return "已回到起點，再往上不會拼入"
    case .hardToMatch: return "這段內容不好辨識，慢慢捲"
    case .bottomProbing: return "已到底部，收尾中…"
    case .deadReckoning: return "空白區段以捲動量推算"
    }
}
