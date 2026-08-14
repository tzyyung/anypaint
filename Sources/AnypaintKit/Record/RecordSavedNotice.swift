import AppKit

/// 錄影完成的**操作面板**（免通知權限）：螢幕下緣中央顯示「✓ 錄影完成 <檔名>」＋三顆按鈕
/// 〔▶ 播放〕〔在 Finder 顯示〕〔關閉〕。**不自動快關**（20 秒安全逾時，正常靠使用者按按鈕收），
/// 顯示時 activate app 讓按鈕確實可點——解決舊版「點了沒用、很快自動關」。
@MainActor
public final class RecordSavedNotice: NSObject {
    public static let shared = RecordSavedNotice()
    private override init() { super.init() }

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var playButton: NSButton?
    private var revealButton: NSButton?
    private var fileURL: URL?
    private var hideWork: DispatchWorkItem?

    /// 標題文案（純函式,可測）：成功帶檔名;失敗給明確訊息。
    public nonisolated static func message(filename: String?) -> String {
        if let filename { return "✓ 錄影完成：\(filename)" }
        return "⚠︎ 錄影存檔失敗"
    }

    /// 顯示完成面板。`fileURL` 非 nil＝成功（可播放/顯示）；nil＝失敗（只給關閉）。
    public func show(fileURL: URL?, on screen: NSScreen? = nil) {
        self.fileURL = fileURL
        buildIfNeeded()
        guard let p = panel else { return }
        titleLabel?.stringValue = Self.message(filename: fileURL?.lastPathComponent)
        // 失敗時隱藏播放/顯示（沒有檔案可操作）。
        playButton?.isHidden = (fileURL == nil)
        revealButton?.isHidden = (fileURL == nil)

        p.layoutIfNeeded()
        let scr = screen ?? NSScreen.main
        if let vf = scr?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.minY + 90))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)   // 讓按鈕確實可點（accessory app 平時非前景）

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)   // 安全逾時,不是快關
    }

    private func dismiss() { hideWork?.cancel(); panel?.orderOut(nil) }

    @objc private func playTapped() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }   // 用預設播放器（QuickTime 等）開
        dismiss()
    }
    @objc private func revealTapped() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        dismiss()
    }
    @objc private func closeTapped() { dismiss() }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        p.hasShadow = true
        p.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "")
        title.textColor = .white
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        titleLabel = title

        let play = NSButton(title: "▶ 播放", target: self, action: #selector(playTapped))
        play.bezelStyle = .rounded
        playButton = play
        let reveal = NSButton(title: "在 Finder 顯示", target: self, action: #selector(revealTapped))
        reveal.bezelStyle = .rounded
        revealButton = reveal
        let close = NSButton(title: "關閉", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [play, reveal, close])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [title, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: p.contentView!.bounds)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        p.contentView = content
        panel = p
    }
}
