import AppKit

/// 錄影/存檔完成的**畫面上**提示浮窗（免通知權限）：螢幕下緣中央短暫顯示「✓ 已存 <檔名>」，
/// 點一下在 Finder 顯示,數秒後自動消失。解決「錄完什麼表示都沒有,不知道完成沒」。
@MainActor
public final class RecordSavedNotice: NSObject {
    public static let shared = RecordSavedNotice()
    private override init() { super.init() }

    private var panel: NSPanel?
    private var fileURL: URL?
    private var hideWork: DispatchWorkItem?

    /// 提示文案（純函式,可測）：成功帶檔名;失敗給明確訊息。
    public nonisolated static func message(filename: String?) -> String {
        if let filename { return "✓ 錄影已存：\(filename)　點此在 Finder 顯示" }
        return "⚠︎ 錄影存檔失敗"
    }

    /// 顯示提示。`fileURL` 非 nil＝成功（可點擊顯示）；nil＝失敗。`seconds` 後自動消失。
    public func show(fileURL: URL?, on screen: NSScreen? = nil, seconds: Double = 5) {
        self.fileURL = fileURL
        let text = Self.message(filename: fileURL?.lastPathComponent)
        let scr = screen ?? NSScreen.main
        buildIfNeeded()
        guard let p = panel, let label = p.contentView?.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        label.stringValue = text
        p.setContentSize(NSSize(width: max(240, label.intrinsicContentSize.width + 40), height: 40))
        if let vf = scr?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.minY + 80))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func dismiss() { panel?.orderOut(nil) }

    @objc private func clicked() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        dismiss()
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        p.hasShadow = true
        p.isReleasedWhenClosed = false

        // 整片可點：用一個透明按鈕鋪滿,點擊在 Finder 顯示。
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(clicked)
        button.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: p.contentView!.bounds)
        content.addSubview(button)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        ])
        p.contentView = content
        panel = p
    }
}
