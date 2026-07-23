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

    // 捲動：⌘＝透明度、無修飾＝縮放（等比）。
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            owner?.adjustAlpha(event.scrollingDeltaY * 0.005)
        } else {
            owner?.zoom(by: event.scrollingDeltaY)
        }
    }

    // 雙按偵測放 mouseUp、不碰 mouseDown——isMovableByWindowBackground 的背景拖曳
    // 吃 mouseDown 階段（override 會破壞移窗）；拖曳超過系統閾值時 clickCount 不會到 2。
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .shift {
                owner?.toggleThumbnail()
            } else if mods.isEmpty {
                owner?.close()
                return   // 視窗已關，不再往下傳
            }
        }
        super.mouseUp(with: event)
    }

    // 中鍵（buttonNumber == 2）＝重設；多鍵滑鼠側鍵（3/4…）忽略，degrade 走右鍵選單。
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            owner?.resetSizeAndAlpha()
        } else {
            super.otherMouseUp(with: event)
        }
    }

    // 右鍵選單；⇧+右鍵＝直接 OCR（Snipaste 同款），不顯示選單。
    override func menu(for event: NSEvent) -> NSMenu? {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift {
            owner?.recognizeText()
            return nil
        }
        return owner?.contextMenu()
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
    /// init 當下的顯示尺寸＝中鍵重設的「100%」（不是 image 像素尺寸——Retina 下那會放大兩倍）。
    private let initialSize: CGSize
    /// 縮圖前尺寸；nil＝非縮圖態。
    private var thumbnailRestoreSize: CGSize?
    /// 快速縮圖的長邊上限（spec）。
    static let thumbnailMaxEdge: CGFloat = 120
    /// OCR 結果窗（lazy、一窗一個、close 連動）與辨識中旗標（不疊請求）。
    private var ocrController: OCRResultWindowController?
    private var ocrInFlight = false

    init(image: NSImage, frame: CGRect) {
        self.pinImage = image
        let size = image.size
        self.aspect = size.height > 0 ? size.width / size.height : 1
        self.initialSize = frame.size

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
        let newWidth = max(40, frame.width * factor)
        let newSize = CGSize(width: newWidth, height: newWidth / aspect)
        setFrame(CoordinateUtils.rectResized(frame, to: newSize), display: true, animate: false)
    }

    func adjustAlpha(_ delta: CGFloat) {
        alphaValue = min(1.0, max(0.1, alphaValue + delta))
    }

    /// ⇧+雙按：縮圖 ⇄ 還原（各窗獨立狀態）。已 ≤ 上限且非縮圖態＝不動作、不記 restore。
    func toggleThumbnail() {
        if let restore = thumbnailRestoreSize {
            thumbnailRestoreSize = nil
            setFrame(CoordinateUtils.rectResized(frame, to: restore), display: true, animate: false)
        } else {
            let target = CoordinateUtils.thumbnailSize(for: frame.size,
                                                       maxEdge: PinWindow.thumbnailMaxEdge)
            guard target != frame.size else { return }
            thumbnailRestoreSize = frame.size
            setFrame(CoordinateUtils.rectResized(frame, to: target), display: true, animate: false)
        }
    }

    /// 中鍵/選單：尺寸回初始＋不透明＋脫離縮圖態（使用者決策：一鍵全部歸位）。
    func resetSizeAndAlpha() {
        thumbnailRestoreSize = nil
        alphaValue = 1.0
        setFrame(CoordinateUtils.rectResized(frame, to: initialSize), display: true, animate: false)
    }

    /// ⇧+右鍵/選單：辨識 pinImage 全解析度文字（縮圖態也辨全圖，spec）。
    func recognizeText() {
        guard !ocrInFlight else { return }
        let controller = ocrController ?? OCRResultWindowController()
        ocrController = controller
        controller.present(besideGlobalRect: frame)

        var proposedRect = CGRect(origin: .zero, size: pinImage.size)
        guard let cg = pinImage.cgImage(forProposedRect: &proposedRect,
                                        context: nil, hints: nil) else {
            controller.showText("無法讀取影像")
            return
        }
        ocrInFlight = true
        TextRecognizer.recognize(cgImage: cg) { [weak self] result in
            self?.ocrInFlight = false
            switch result {
            case .success(let lines):
                controller.showText(lines.isEmpty ? "未偵測到文字"
                                                  : TextRecognizer.joinedText(lines))
            case .failure(let error):
                controller.showText("辨識失敗：\(error.localizedDescription)")
            }
        }
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
        add(menu, thumbnailRestoreSize == nil ? "縮圖  ⇧雙按" : "還原縮圖  ⇧雙按",
            #selector(miToggleThumbnail))
        add(menu, "重設大小與透明度  中鍵", #selector(miReset))
        add(menu, "複製文字（OCR）  ⇧右鍵", #selector(miOCR))
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
    @objc private func miToggleThumbnail() { toggleThumbnail() }
    @objc private func miReset() { resetSizeAndAlpha() }
    @objc private func miOCR() { recognizeText() }
    @objc private func miClose() { close() }

    override func close() {
        ocrController?.closeWindow()
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

    /// 關閉所有貼圖（走 close() 讓 OCR 結果窗等附屬資源一併關閉，不留孤兒）。
    func closeAll() {
        let all = windows
        windows.removeAll()
        all.forEach { $0.close() }
    }

    var count: Int { windows.count }
}
