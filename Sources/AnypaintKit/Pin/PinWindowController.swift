import AppKit

/// 貼圖視窗裡負責畫圖的視圖：把影像等比填滿視窗（視窗縮放 → 圖跟著縮放）。
final class PinContentView: NSView {
    let image: NSImage
    weak var owner: PinWindow?

    init(image: NSImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }

    // 捲動縮放（等比）。
    override func scrollWheel(with event: NSEvent) {
        owner?.zoom(by: event.scrollingDeltaY)
    }

    // 右鍵選單。
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }
}

/// 一個貼圖浮動視窗：置頂、可拖曳、可縮放、可調透明度。
///
/// 安全設計（參考 macshot / better-shot）：**MVP 刻意不做 click-through**。
/// 讓 pin 視窗永遠吃得到滑鼠，就不可能出現「整片吞掉輸入又關不掉」的鎖死。
/// 未來若要 click-through，需照 capso 的做法把關閉鈕放到另一個永遠可點的子視窗，
/// 而非讓承載關閉功能的視窗本身變穿透。
final class PinWindow: NSPanel {
    private let aspect: CGFloat
    private let pinImage: NSImage
    weak var controller: PinWindowController?

    init(image: NSImage, frame: CGRect) {
        self.pinImage = image
        let size = image.size
        self.aspect = size.height > 0 ? size.width / size.height : 1

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating                       // 置頂，浮在一般視窗之上
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true       // 拖曳整片圖即可移動
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true            // 捲動縮放不必搶焦點
        isReleasedWhenClosed = false             // 由 controller 明確持有與釋放

        let content = PinContentView(image: image)
        content.owner = self
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 互動

    /// 捲動縮放（維持等比、以中心為錨點）。
    func zoom(by deltaY: CGFloat) {
        let factor = 1 + (deltaY * 0.005)
        var f = frame
        let newWidth = max(40, f.width * factor)
        let newHeight = newWidth / aspect
        f.origin.x -= (newWidth - f.width) / 2
        f.origin.y -= (newHeight - f.height) / 2
        f.size = CGSize(width: newWidth, height: newHeight)
        setFrame(f, display: true, animate: false)
    }

    private func adjustAlpha(_ delta: CGFloat) {
        alphaValue = min(1.0, max(0.1, alphaValue + delta))
    }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([pinImage])
    }

    // Esc（透過 responder chain 的標準取消動作）→ 關閉。
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:            // Esc → 關閉
            close()
        default:
            switch event.charactersIgnoringModifiers {
            case "c": copyToPasteboard()
            case "[": adjustAlpha(-0.1)
            case "]": adjustAlpha(0.1)
            case "0": alphaValue = 1.0
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: - 右鍵選單

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "複製圖片  c", #selector(miCopy))
        add(menu, "還原透明度  0", #selector(miResetAlpha))
        menu.addItem(.separator())
        add(menu, "關閉此貼圖  esc", #selector(miClose))
        return menu
    }
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }
    @objc private func miCopy() { copyToPasteboard() }
    @objc private func miResetAlpha() { alphaValue = 1.0 }
    @objc private func miClose() { close() }

    override func close() {
        controller?.forget(self)
        super.close()
    }
}

/// 管理所有貼圖視窗。單一職責：建立/追蹤/整批操作貼圖。
final class PinWindowController {
    private var windows: [PinWindow] = []

    /// 在指定螢幕座標（點、左下原點）貼一張圖（置中、超螢幕先縮）。
    func pin(image: NSImage, at point: CGPoint) {
        let capped = cappedImage(image)
        show(PinWindow(image: capped,
                       frame: CoordinateUtils.centeredRect(at: point, size: capped.size)))
    }

    /// 貼到指定全域框（截圖完直接貼）：蓋在原框選位置。
    /// 不套 cappedImage——框選必然 ≤ 螢幕大小（spec）。
    func pin(image: NSImage, frame: CGRect) {
        show(PinWindow(image: image, frame: frame))
    }

    private func show(_ window: PinWindow) {
        window.controller = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.append(window)
    }

    /// 若圖比螢幕還大，初始尺寸縮到可視範圍內（不改原圖，只調顯示尺寸）。
    private func cappedImage(_ image: NSImage) -> NSImage {
        guard let screen = NSScreen.main else { return image }
        let maxW = screen.visibleFrame.width * 0.9
        let maxH = screen.visibleFrame.height * 0.9
        let s = image.size
        guard s.width > maxW || s.height > maxH, s.width > 0, s.height > 0 else { return image }
        let scale = min(maxW / s.width, maxH / s.height)
        let resized = NSImage(size: NSSize(width: s.width * scale, height: s.height * scale))
        resized.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: resized.size))
        resized.unlockFocus()
        return resized
    }

    func forget(_ window: PinWindow) {
        windows.removeAll { $0 === window }
    }

    /// 關閉所有貼圖。
    func closeAll() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    var count: Int { windows.count }
}
