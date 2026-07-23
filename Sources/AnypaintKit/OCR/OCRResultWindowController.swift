import AppKit

/// OCR 結果視窗本體：Esc 關閉（titled window 預設不吃 Esc，照 PinWindow 同 pattern）。
final class OCRResultWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// OCR 結果視窗：可選取文字＋「複製全部」。一顆貼圖一個（由 PinWindow 持有、關閉連動）。
public final class OCRResultWindowController: NSWindowController {
    private let textView = NSTextView()

    public init() {
        let window = OCRResultWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "複製文字"
        window.isReleasedWhenClosed = false   // 由 PinWindow 持有、可重複 present
        window.level = .floating              // 與貼圖同層，不被一般視窗蓋掉
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.autoresizingMask = [.width]

        let copyButton = NSButton(title: "複製全部", target: self, action: #selector(copyAll))
        copyButton.bezelStyle = .rounded
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(copyButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    /// 開窗（或前置）於 anchor（全域座標）旁，先顯示「辨識中…」。
    public func present(besideGlobalRect anchor: CGRect) {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        window.setFrame(CoordinateUtils.sideRect(beside: anchor, size: window.frame.size,
                                                 in: visible), display: true)
        showText("辨識中…")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 拿不到選取/複製
    }

    public func showText(_ text: String) {
        textView.string = text
    }

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
    }

    public func closeWindow() {
        window?.orderOut(nil)
    }
}
