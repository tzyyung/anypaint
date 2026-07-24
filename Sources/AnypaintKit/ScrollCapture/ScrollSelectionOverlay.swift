import AppKit

// MARK: - Overlay 視窗

/// 蓋滿單一螢幕的 borderless overlay 視窗——沿用 SelectionOverlayWindow 成例
/// （SelectionOverlayController.swift:6-30），但不共用類別：底下是活畫面，不放快照。
final class ScrollSelectionWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = ScrollSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        setFrame(screen.frame, display: true)
    }

    // 同 SelectionOverlayWindow：selecting/armed 階段要收得到 keyDown（Esc 取消）。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var selectionView: ScrollSelectionView? { contentView as? ScrollSelectionView }
}

// MARK: - 協調者

@MainActor
public final class ScrollSelectionOverlayController {
    public var onSelectionLocked: ((CGRect, NSScreen) -> Void)?
    public var onSelectionChanged: ((CGRect) -> Void)?
    public var onCancelRequested: (() -> Void)?
    public private(set) var selectionGlobal: CGRect = .zero

    private var window: ScrollSelectionWindow?

    /// selecting：建 panel（同 SelectionOverlayWindow 配置）＋ ScrollSelectionView，全螢幕拉框。
    public func present(on screen: NSScreen) {
        dismiss()
        let window = ScrollSelectionWindow(screen: screen)
        window.selectionView?.onSelectionLocked = { [weak self, weak window] rect in
            guard let self, let window else { return }
            let global = CoordinateUtils.globalRect(selection: rect, windowOrigin: window.frame.origin)
            self.selectionGlobal = global
            self.onSelectionLocked?(global, screen)
        }
        window.selectionView?.onSelectionChanged = { [weak self, weak window] rect in
            guard let self, let window else { return }
            let global = CoordinateUtils.globalRect(selection: rect, windowOrigin: window.frame.origin)
            self.selectionGlobal = global
            self.onSelectionChanged?(global)
        }
        window.selectionView?.onCancelRequested = { [weak self] in self?.onCancelRequested?() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSCursor.crosshair.set()
        self.window = window
    }

    /// capturing：放行滑鼠／滾輪給底下的活畫面；view 淡出遮罩只剩框線。
    public func enterCapturing() {
        window?.ignoresMouseEvents = true
        window?.selectionView?.mode = .capturing
    }

    public func dismiss() {
        window?.orderOut(nil)
        window = nil
        selectionGlobal = .zero
        NSCursor.arrow.set()
        onSelectionLocked = nil
        onSelectionChanged = nil
        onCancelRequested = nil
    }
}

// MARK: - 極簡選區 View

/// 極簡選區 view：mouseDown 起框、mouseDragged 調整、mouseUp 鎖定；armed 既有框可拖移／
/// 邊角縮放（命中半徑 ~6pt）。無標註、無放大鏡；單螢幕 clamp 在自身 bounds＝screen.frame 內。
final class ScrollSelectionView: NSView {
    enum Mode { case selecting, armed, capturing }
    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(startMouse: CGPoint, startRect: CGRect)
        case resizing(handle: Handle, startRect: CGRect)
    }

    /// selecting→armed 由 view 自己在鎖定時翻轉；capturing 由 controller.enterCapturing() 寫入。
    var mode: Mode = .selecting { didSet { needsDisplay = true } }
    private(set) var selection: CGRect?
    private var drag: Drag?

    private let handleSize: CGFloat = 8
    private let hitRadius: CGFloat = 6
    private let minSize: CGFloat = 5

    var onSelectionLocked: ((CGRect) -> Void)?
    var onSelectionChanged: ((CGRect) -> Void)?
    var onCancelRequested: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: 拖曳幾何

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
        let r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return clampToBounds(r)
    }
    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }
    private func hitHandle(_ point: CGPoint, in r: CGRect) -> Handle? {
        for (i, p) in handlePoints(r).enumerated() {
            let box = CGRect(x: p.x - hitRadius, y: p.y - hitRadius, width: hitRadius * 2, height: hitRadius * 2)
            if box.contains(point) { return Handle.allCases[i] }
        }
        return nil
    }

    // MARK: 滑鼠

    override func mouseDown(with event: NSEvent) {
        guard mode != .capturing else { return }
        let p = clampPoint(convert(event.locationInWindow, from: nil))
        if mode == .armed {
            // 既有框：只能拖移／邊角縮放，空白處按下不建新框（鎖定後改框走 Esc 重來，spec 極簡版）。
            guard let sel = selection else { return }
            if let h = hitHandle(p, in: sel) {
                drag = .resizing(handle: h, startRect: sel)
            } else if sel.contains(p) {
                drag = .moving(startMouse: p, startRect: sel)
            }
            return
        }
        // mode == .selecting：空白處按下開新框。
        drag = .creating(anchor: p)
        selection = CGRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let currentDrag = drag else { return }
        let p = clampPoint(convert(event.locationInWindow, from: nil))
        switch currentDrag {
        case .creating(let anchor):
            selection = CoordinateUtils.rect(from: anchor, to: p)
        case .moving(let startMouse, let startRect):
            var r = startRect
            r.origin.x += p.x - startMouse.x
            r.origin.y += p.y - startMouse.y
            selection = clampToBounds(r)
        case .resizing(let handle, let startRect):
            selection = resize(startRect, handle: handle, to: p)
        }
        needsDisplay = true
        // armed 中調框才回報 onSelectionChanged；selecting 階段的拉框在 mouseUp 一次性鎖定。
        if mode == .armed, let sel = selection { onSelectionChanged?(sel) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let currentDrag = drag else { return }
        drag = nil
        if case .creating = currentDrag {
            guard let sel = selection, sel.width > minSize, sel.height > minSize else {
                selection = nil
                needsDisplay = true
                return
            }
            mode = .armed
            onSelectionLocked?(sel)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard mode != .capturing else { super.keyDown(with: event); return }
        if event.keyCode == 53 {   // Esc（capturing 後 Session 接手，overlay 不再處理）
            onCancelRequested?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        guard let sel = selection, sel.width > 0, sel.height > 0 else {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            return
        }
        if mode == .capturing {
            drawCapturingFrame(sel)
            return
        }
        // 半透明遮罩＋選區鏤空（even-odd：整張 bounds 疊選區框，交集扣掉）。
        let mask = NSBezierPath(rect: bounds)
        mask.appendRect(sel)
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        mask.fill()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 1.5
        border.stroke()

        drawSizeBadge(for: sel)

        if mode == .armed {
            NSColor.controlAccentColor.setFill()
            NSColor.white.setStroke()
            for p in handlePoints(sel) {
                let h = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
                let path = NSBezierPath(rect: h)
                path.fill()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// capturing：遮罩淡出只剩框線（底下 app 收滾輪）；框線 2px、留 8pt 呼吸邊避免壓到內容視覺。
    private func drawCapturingFrame(_ sel: CGRect) {
        let breathing = sel.insetBy(dx: -8, dy: -8)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: breathing)
        path.lineWidth = 2
        path.stroke()
    }

    /// 選取框上方「寬 × 高（點）」尺寸標籤；上方空間不足就移進框內頂端。
    private func drawSizeBadge(for rect: CGRect) {
        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
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
        var y = rect.maxY + 4
        if y + bh > bounds.height { y = rect.maxY - bh - 4 }
        x = min(max(0, x), bounds.width - bw)
        y = min(max(0, y), bounds.height - bh)
        let badge = CGRect(x: x, y: y, width: bw, height: bh)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        str.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad))
    }
}
