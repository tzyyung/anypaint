import AppKit

/// 載入 macOS 原生游標資源（`cursor.pdf` + `info.plist` 的 hotspot），讓 resize 游標
/// 與系統完全一致、四個方向風格統一。這不是私有 API，只是讀系統框架裡 world-readable
/// 的資源檔（app 非 sandbox 可讀）；找不到就回 nil 由呼叫端 fallback。
enum NativeCursors {
    private static let base = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"

    static func load(_ name: String) -> NSCursor? {
        let dir = "\(base)/\(name)"
        guard let image = NSImage(contentsOfFile: "\(dir)/cursor.pdf"),
              let info = NSDictionary(contentsOfFile: "\(dir)/info.plist"),
              let hotx = (info["hotx"] as? NSNumber)?.doubleValue,
              let hoty = (info["hoty"] as? NSNumber)?.doubleValue
        else { return nil }
        return NSCursor(image: image, hotSpot: NSPoint(x: hotx, y: hoty))
    }
}

// MARK: - 工具列

/// 選取框旁的浮動工具列。用一個會「吞掉滑鼠事件」的容器，避免點工具列時
/// 誤觸底下的 SelectionView 而開始新框選。目前只有擷取/取消 + 尺寸；
/// 之後 annotation 階段會在這排上加標註工具。
final class SelectionToolbar: NSView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 6

        let cancel = makeButton("取消", #selector(cancelAction))
        let confirm = makeButton("擷取", #selector(confirmAction))
        confirm.keyEquivalent = "\r"   // Enter = 擷取

        let stack = NSStackView(views: [cancel, confirm])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    private func makeButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    // 吞掉滑鼠事件，別穿透到底下的 SelectionView。
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    // 工具列上游標顯示箭頭（非十字）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

    @objc private func confirmAction() { onConfirm?() }
    @objc private func cancelAction() { onCancel?() }
}

// MARK: - 框選視圖

/// 框選視圖：顯示凍結影像、可拖出/調整選取框，按工具列「擷取」才裁切完成。
/// 座標一律用「點、左下原點」，裁切時交給 CoordinateUtils 翻轉成像素。
final class SelectionView: NSView {
    private let snapshot: DisplaySnapshot
    private let backgroundImage: NSImage

    private var selection: CGRect?
    private let handleSize: CGFloat = 8
    private let minSize: CGFloat = 5

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private enum DragKind {
        case creating(anchor: CGPoint)
        case moving(startMouse: CGPoint, startRect: CGRect)
        case resizing(handle: Handle, startRect: CGRect)
    }
    private var drag: DragKind?
    private var dragPoint: CGPoint?   // 拖曳中的游標位置（放大鏡用）
    private var hoverPoint: CGPoint?  // 尚未框選時的 hover 位置（放大鏡用）
    private let loupeSide: CGFloat = 110
    private let loupeSrcPixels: CGFloat = 22

    private let toolbar = SelectionToolbar()

    /// 按下「擷取」→ 回傳裁切影像。
    var onConfirm: ((NSImage) -> Void)?
    /// 取消（Esc / 右鍵 / 工具列取消）。
    var onCancel: (() -> Void)?
    /// 任何互動 → 通知 controller 重置看門狗。
    var onInteraction: (() -> Void)?

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        self.backgroundImage = NSImage(cgImage: snapshot.cgImage, size: snapshot.pointSize)
        super.init(frame: CGRect(origin: .zero, size: snapshot.pointSize))

        toolbar.isHidden = true
        toolbar.onConfirm = { [weak self] in self?.confirm() }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(toolbar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // 讓「第一下點擊」就直接當成拖曳起點，而非被拿去啟動視窗而吞掉
    //（否則要先點一下、第二下才拖得動）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 依滑鼠位置顯示對應游標。角落用 SF Symbol 當對角游標（公開 API，無私有游標；
    // 參考 capso 的 cursorForHandle）；邊用系統 resize 游標；框內移動手；工具列箭頭。
    // 四個 handle 游標全用系統原生資源（同源、風格一致）；載入失敗才 fallback。
    private static func symbolCursor(_ name: String) -> NSCursor {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
        }
        return .crosshair
    }
    private static let cursorNWSE = NativeCursors.load("resizenorthwestsoutheast")
        ?? symbolCursor("arrow.up.left.and.arrow.down.right")   // ↖↘
    private static let cursorNESW = NativeCursors.load("resizenortheastsouthwest")
        ?? symbolCursor("arrow.up.right.and.arrow.down.left")   // ↗↙
    private static let cursorEW = NativeCursors.load("resizeeastwest") ?? .resizeLeftRight
    private static let cursorNS = NativeCursors.load("resizenorthsouth") ?? .resizeUpDown

    private func cursor(at point: CGPoint) -> NSCursor {
        if !toolbar.isHidden, toolbar.frame.contains(point) { return .arrow }
        if let sel = selection {
            if let h = hitHandle(point, in: sel) {
                switch h {
                case .topLeft, .bottomRight: return Self.cursorNWSE
                case .topRight, .bottomLeft: return Self.cursorNESW
                case .left, .right:          return Self.cursorEW
                case .top, .bottom:          return Self.cursorNS
                }
            }
            if sel.contains(point) { return .openHand }
        }
        return .crosshair
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: nil, and: p) }
    }
    override func mouseMoved(with event: NSEvent) {
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        let prev = hoverPoint
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: p) }
    }
    override func mouseExited(with event: NSEvent) {
        let prev = hoverPoint
        hoverPoint = nil
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: nil) }
    }

    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let rect = selection, rect.width > 0, rect.height > 0 {
            backgroundImage.draw(in: rect, from: rect, operation: .copy, fraction: 1.0)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()

            // 即時尺寸標籤（拖曳/調整時每次重繪就更新）
            drawSizeBadge(for: rect)

            // 拖曳中不畫控制點（畫面乾淨）；靜止時畫 8 個控制點
            if drag == nil {
                NSColor.controlAccentColor.setFill()
                NSColor.white.setStroke()
                for p in handlePoints(rect) {
                    let h = handleRect(at: p)
                    let hp = NSBezierPath(rect: h)
                    hp.fill()
                    hp.lineWidth = 1
                    hp.stroke()
                }
            }
        }

        // 放大鏡準星：hover（未框選）或拖曳時顯示，方便像素級對齊
        if let lp = activeLoupePoint() {
            drawLoupe(at: lp)
        }
    }

    private func loupeRect(at p: CGPoint) -> CGRect {
        let side = loupeSide
        var lx = p.x + 16
        var ly = p.y - 16 - side
        if lx + side > bounds.width { lx = p.x - 16 - side }
        if ly < 0 { ly = p.y + 16 }
        lx = min(max(0, lx), bounds.width - side)
        ly = min(max(0, ly), bounds.height - side)
        return CGRect(x: lx, y: ly, width: side, height: side)
    }

    /// 放大鏡顯示點：拖曳中→拖曳點；尚未框選→hover 點；已框選靜止→不顯示（免擋控制點）。
    private func activeLoupePoint() -> CGPoint? {
        if drag != nil { return dragPoint }
        if selection == nil { return hoverPoint }
        return nil
    }

    private func invalidateLoupe(around a: CGPoint?, and b: CGPoint?) {
        var dirty = CGRect.null
        for p in [a, b].compactMap({ $0 }) {
            dirty = dirty.union(loupeRect(at: p).insetBy(dx: -12, dy: -28))
        }
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    /// 放大鏡：裁游標周圍一小塊原始像素、最近鄰放大畫在游標旁，中央十字準星 + 座標。
    private func drawLoupe(at p: CGPoint) {
        let side = loupeSide
        let srcPixels = loupeSrcPixels
        let scale = snapshot.scale
        let imgW = CGFloat(snapshot.cgImage.width)
        let imgH = CGFloat(snapshot.cgImage.height)

        // 游標對應的原圖像素座標（左上原點）
        let cx = p.x * scale
        let cyTop = (bounds.height - p.y) * scale
        let src = CGRect(x: cx - srcPixels / 2, y: cyTop - srcPixels / 2,
                         width: srcPixels, height: srcPixels)

        let loupe = loupeRect(at: p)

        guard let ctx = NSGraphicsContext.current else { return }

        // 底色
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(rect: loupe).fill()

        // 放大內容（裁與影像交集，最近鄰）
        let clamped = src.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH)).integral
        if clamped.width >= 1, clamped.height >= 1,
           let crop = snapshot.cgImage.cropping(to: clamped) {
            ctx.saveGraphicsState()
            NSBezierPath(rect: loupe).addClip()
            ctx.imageInterpolation = .none
            // clamped(左上像素) 映射到 loupe(左下點) 的目標矩形
            let tx = loupe.minX + (clamped.minX - src.minX) / srcPixels * side
            let th = clamped.height / srcPixels * side
            let ty = loupe.maxY - (clamped.maxY - src.minY) / srcPixels * side
            let tw = clamped.width / srcPixels * side
            NSImage(cgImage: crop, size: NSSize(width: clamped.width, height: clamped.height))
                .draw(in: CGRect(x: tx, y: ty, width: tw, height: th))
            ctx.restoreGraphicsState()
        }

        // 中央「單一像素」方塊 + 十字準星（游標永遠在 loupe 正中央）
        let px = side / srcPixels
        let center = CGPoint(x: loupe.midX, y: loupe.midY)
        NSColor.controlAccentColor.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: loupe.minX, y: center.y)); cross.line(to: CGPoint(x: loupe.maxX, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: loupe.minY)); cross.line(to: CGPoint(x: center.x, y: loupe.maxY))
        cross.lineWidth = 1
        cross.stroke()
        let pixelBox = CGRect(x: center.x - px / 2, y: center.y - px / 2, width: px, height: px)
        NSBezierPath(rect: pixelBox).stroke()

        // 邊框
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: loupe.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // 座標文字
        let coord = NSAttributedString(
            string: "\(Int(cx)), \(Int(cyTop))",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.white])
        let cs = coord.size()
        let cbg = CGRect(x: loupe.minX, y: loupe.minY - cs.height - 2, width: max(side, cs.width + 8), height: cs.height + 3)
        if cbg.minY >= 0 {
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(rect: cbg).fill()
            coord.draw(at: CGPoint(x: cbg.minX + 4, y: cbg.minY + 1))
        }
    }

    /// 在選取框上方畫「寬 × 高（像素）」小標籤；上方空間不足就畫在框內頂端。
    private func drawSizeBadge(for rect: CGRect) {
        let w = Int((rect.width * snapshot.scale).rounded())
        let h = Int((rect.height * snapshot.scale).rounded())
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "\(w) × \(h)", attributes: attrs)
        let pad: CGFloat = 4
        let textSize = str.size()
        let bw = textSize.width + pad * 2
        let bh = textSize.height + pad * 2

        var x = rect.minX
        var y = rect.maxY + 4                       // 框上方（非翻轉座標：maxY 是上緣）
        if y + bh > bounds.height { y = rect.maxY - bh - 4 }  // 貼近螢幕頂 → 移進框內
        x = min(max(0, x), bounds.width - bw)
        y = min(max(0, y), bounds.height - bh)

        let badge = CGRect(x: x, y: y, width: bw, height: bh)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        str.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad))
    }

    // MARK: 控制點幾何

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }
    private func handleRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
    }
    private func hitHandle(_ point: CGPoint, in r: CGRect) -> Handle? {
        let pts = handlePoints(r)
        for (i, p) in pts.enumerated() {
            if handleRect(at: p).insetBy(dx: -4, dy: -4).contains(point) {
                return Handle.allCases[i]
            }
        }
        return nil
    }

    // MARK: 滑鼠

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        dragPoint = p
        if let sel = selection {
            if let h = hitHandle(p, in: sel) {
                drag = .resizing(handle: h, startRect: sel)
                return
            }
            if sel.contains(p) {
                drag = .moving(startMouse: p, startRect: sel)
                return
            }
        }
        // 空白處按下 → 開新框
        drag = .creating(anchor: p)
        selection = CGRect(origin: p, size: .zero)
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        onInteraction?()
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragPoint = p
        switch drag {
        case .creating(let anchor):
            selection = CoordinateUtils.rect(from: anchor, to: p)
        case .moving(let startMouse, let startRect):
            var r = startRect
            r.origin.x += p.x - startMouse.x
            r.origin.y += p.y - startMouse.y
            selection = clampToBounds(r)
        case .resizing(let handle, let startRect):
            selection = resize(startRect, handle: handle, to: clampPoint(p))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onInteraction?()
        drag = nil
        dragPoint = nil
        if let sel = selection, sel.width > minSize, sel.height > minSize {
            layoutToolbar(for: sel)
            toolbar.isHidden = false
        } else {
            selection = nil
            toolbar.isHidden = true
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // 捲動也算互動（重置看門狗），事件本身照常往下傳。
    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onInteraction?()
        switch event.keyCode {
        case 53:            // Esc → 取消
            onCancel?()
        case 36, 76:        // Return / Enter → 擷取
            confirm()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: 調整框幾何

    private func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private func clampToBounds(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
        r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
        return r
    }

    private func resize(_ start: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .topLeft:     minX = p.x; maxY = p.y
        case .top:         maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom:      minY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .left:        minX = p.x
        }
        // 允許拖過頭翻轉，用 min/max 正規化
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: 工具列定位

    private func layoutToolbar(for sel: CGRect) {
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        let margin: CGFloat = 8
        // 預設放選取框下方、靠右對齊；下方空間不足就放上方
        var x = sel.maxX - size.width
        var y = sel.minY - margin - size.height
        if y < 0 { y = sel.maxY + margin }                 // 貼近底部 → 放上方
        if y + size.height > bounds.height { y = sel.minY - margin - size.height }
        x = min(max(0, x), bounds.width - size.width)
        y = min(max(0, y), bounds.height - size.height)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: 完成擷取

    private func confirm() {
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return }
        let pixelRect = CoordinateUtils.pixelCropRect(
            selection: sel, displayPointSize: bounds.size, scale: snapshot.scale)
        guard let cropped = snapshot.cgImage.cropping(to: pixelRect) else {
            onCancel?(); return
        }
        let pointSize = NSSize(width: pixelRect.width / snapshot.scale,
                               height: pixelRect.height / snapshot.scale)
        onConfirm?(NSImage(cgImage: cropped, size: pointSize))
    }
}

// MARK: - Overlay 視窗

/// 蓋滿單一螢幕的 borderless overlay 視窗（NSPanel + .nonactivatingPanel）。
final class SelectionOverlayWindow: NSPanel {
    init(snapshot: DisplaySnapshot) {
        super.init(
            contentRect: snapshot.frameGlobal,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true      // 確保 hover 時就收得到 mouseMoved（放大鏡/游標）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = SelectionView(snapshot: snapshot)
        setFrame(snapshot.frameGlobal, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var selectionView: SelectionView? { contentView as? SelectionView }
}

// MARK: - 協調者

/// 協調多螢幕 overlay：單飛、不疊加、多條逃生路徑 + 免按鍵看門狗（互動即重置、秒數可設）。
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var onSelect: ((NSImage) -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?
    private var watchdog: DispatchWorkItem?

    private(set) var isActive = false

    func present(snapshots: [DisplaySnapshot],
                 onSelect: @escaping (NSImage) -> Void,
                 onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onSelect = onSelect
        self.onCancel = onCancel

        NSApp.activate(ignoringOtherApps: true)
        for snapshot in snapshots {
            let window = SelectionOverlayWindow(snapshot: snapshot)
            window.selectionView?.onConfirm = { [weak self] image in self?.finish(with: image) }
            window.selectionView?.onCancel = { [weak self] in self?.cancel() }
            window.selectionView?.onInteraction = { [weak self] in self?.armWatchdog() }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)   // 逃生路 1：keyDown/Esc 收得到
            windows.append(window)
        }

        // 逃生路 2：本地事件監聽，Esc 一律取消
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.armWatchdog()          // 任何鍵都算互動（含工具列有焦點時）
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }
        // 逃生路 5：看門狗（免按鍵），互動即重置，秒數可在設定頁調
        armWatchdog()
        NSCursor.crosshair.set()
    }

    /// 逃生路 3：外部（再按截圖快鍵）取消目前框選。
    func cancelIfActive() {
        guard isActive else { return }
        cancel()
    }

    /// 重置看門狗：只在「無互動」達設定秒數才強制解除，正常調整框不會被打斷。
    private func armWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            NSLog("anypaint: 框選看門狗逾時（無互動），強制解除")
            self.cancel()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.overlayWatchdogSeconds, execute: work)
    }

    private func finish(with image: NSImage) {
        let handler = onSelect
        dismiss()
        handler?(image)
    }

    private func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    private func dismiss() {
        watchdog?.cancel(); watchdog = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.arrow.set()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onSelect = nil
        onCancel = nil
        isActive = false
    }
}

// 逃生路 4（保留）：SelectionView 右鍵 = 取消。
