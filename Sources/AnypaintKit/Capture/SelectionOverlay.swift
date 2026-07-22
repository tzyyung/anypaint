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

/// 選取框旁的浮動工具列（兩排）：上排＝標註工具｜undo/redo｜取消/擷取，
/// 下排＝樣式（7 色塊＋粗細 pt 數值標籤，選了工具才顯示）。
/// 用一個會「吞掉滑鼠事件」的容器，避免點工具列時誤觸底下的 SelectionView。
final class SelectionToolbar: NSView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 點工具按鈕；再點一次作用中的工具＝取消作用（回傳 nil）。
    var onToolSelected: ((AnnotationTool?) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [AnnotationColor: NSButton] = [:]
    /// 粗細數值標籤（spec 2026-07-22 修訂：三檔按鈕改連續值，工具列只顯示目前 pt 數）。
    private let lineWidthLabel: NSTextField = {
        let l = NSTextField(labelWithString: "4 pt")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .white
        return l
    }()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let styleRow = NSStackView()
    private var activeTool: AnnotationTool?
    private var currentStyle = AnnotationStyle(color: .red, lineWidth: 4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 6
        buildRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    private func buildRows() {
        // 上排：工具（SF Symbol；階段 3–5 加工具時在這張表補 symbol）
        let toolsRow = NSStackView()
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 4
        let symbols: [(AnnotationTool, String)] = [
            (.select, "cursorarrow"),
            (.rect, "rectangle"), (.ellipse, "circle"),
            (.line, "line.diagonal"), (.arrow, "arrow.up.right"),
            (.freehand, "pencil"), (.highlighter, "highlighter"), (.pixelate, "squareshape.split.3x3"),
            (.text, "textformat"), (.counter, "1.circle")
        ]
        for (tool, symbol) in symbols {
            let b = NSButton()
            configureSymbolButton(b, symbol, #selector(toolTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            toolButtons[tool] = b
            toolsRow.addArrangedSubview(b)
        }
        toolsRow.addArrangedSubview(separator())
        configureSymbolButton(undoButton, "arrow.uturn.backward", #selector(undoTapped))
        configureSymbolButton(redoButton, "arrow.uturn.forward", #selector(redoTapped))
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        toolsRow.addArrangedSubview(undoButton)
        toolsRow.addArrangedSubview(redoButton)
        toolsRow.addArrangedSubview(separator())
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let confirm = NSButton(title: "擷取", target: self, action: #selector(confirmAction))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .small
        confirm.keyEquivalent = "\r"   // Enter = 擷取
        toolsRow.addArrangedSubview(cancel)
        toolsRow.addArrangedSubview(confirm)

        // 下排：色盤＋粗細（選了工具才顯示）
        styleRow.orientation = .horizontal
        styleRow.spacing = 4
        for color in AnnotationColor.allCases {
            let b = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = color.cgColor
            b.layer?.cornerRadius = 3
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor   // 選中框用強調色（白色塊也看得到）
            b.identifier = NSUserInterfaceItemIdentifier(color.rawValue)
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons[color] = b
            styleRow.addArrangedSubview(b)
        }
        styleRow.addArrangedSubview(separator())
        styleRow.addArrangedSubview(lineWidthLabel)
        styleRow.isHidden = true

        let stack = NSStackView(views: [toolsRow, styleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
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

    private func configureSymbolButton(_ b: NSButton, _ name: String, _ action: Selector) {
        b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        b.target = self
        b.action = action
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.contentTintColor = .white
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    // MARK: 外部狀態同步

    func setActiveTool(_ tool: AnnotationTool?) {
        activeTool = tool
        for (t, b) in toolButtons {
            b.layer?.backgroundColor = (t == tool)
                ? NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
                : NSColor.clear.cgColor
        }
        styleRow.isHidden = (tool == nil)
    }

    func setStyle(_ style: AnnotationStyle) {
        currentStyle = style
        for (c, b) in colorButtons { b.layer?.borderWidth = (c == style.color) ? 2 : 0 }
        lineWidthLabel.stringValue = "\(Int(style.lineWidth.rounded())) pt"
    }

    func setUndoState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    // MARK: 按鈕動作

    @objc private func toolTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let tool = AnnotationTool(rawValue: id) else { return }
        let newTool: AnnotationTool? = (tool == activeTool) ? nil : tool
        setActiveTool(newTool)
        onToolSelected?(newTool)
    }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func colorTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let color = AnnotationColor(rawValue: id) else { return }
        currentStyle.color = color
        setStyle(currentStyle)
        onStyleChanged?(currentStyle)
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

    /// 看門狗倒數警告秒數（nil = 不顯示）。由 overlay controller 寫入。
    var watchdogWarningSeconds: Int? {
        didSet { if watchdogWarningSeconds != oldValue { needsDisplay = true } }
    }

    // MARK: 標註狀態（階段 2）
    /// 作用中的標註工具（nil＝調框模式）。
    private var activeTool: AnnotationTool?
    /// 標註文件（undo/z-order 都在裡面）。
    private let annotations = AnnotationDocument()
    /// 拖曳中的暫定形狀——不進 document，mouseUp 位移 ≥3pt 才 add()（總審查裁定的慣例）。
    private var provisionalShape: Annotation.Shape?
    private var shapeAnchor: CGPoint?
    /// 畫筆/螢光筆的累積點（拖曳中）；mouseUp 成形。
    private var strokePoints: [CGPoint] = []
    private var currentStyle = AnnotationStyleStore.style(for: .rect)
    /// 滾輪調粗細的累積量（觸控板會送大量小 delta，湊滿閾值才跳一檔）。
    private var lineWidthScrollAccum: CGFloat = 0
    /// 有任何標註就鎖框（spec）：控制點隱藏、框不可建/移/縮；undo 清空自動解鎖。
    private var frameLocked: Bool { !annotations.isEmpty }

    // MARK: 熱圖形（spec 2026-07-22 修訂）
    /// mouseUp 成功 add() 的物件在解除前是「熱」的：滾輪直接調它的粗細（畫面即時反映）。
    /// mouseDown（任何分支）、undo/redo、切工具／取消工具作用都清除。
    private var hotAnnotationID: UUID?
    /// 目前這段熱圖形滾輪調整是否已經 beginChange() 過一次
    /// （首次實際改動才拍快照，整段調整合併一步 undo；不可每格滾動都 push 快照）。
    private var hotScrollBegan = false

    private func clearHotAnnotation() {
        hotAnnotationID = nil
        hotScrollBegan = false
    }

    // MARK: select 工具（階段 5）
    /// select 工具下正在移動/縮放的物件（mouseDown 命中時記錄起始幾何，mouseUp 清除）。
    private enum SelectDrag {
        case moving(id: UUID, startMouse: CGPoint, startShape: Annotation.Shape)
        case resizing(id: UUID, handle: AnnotationHandle, startBounds: CGRect, startShape: Annotation.Shape)
    }
    private var selectDrag: SelectDrag?
    /// 首次實際位移才 beginChange()（比照 textDragBegan：整段移動/縮放合併一步 undo）。
    private var selectDragBegan = false

    /// 有選取物件（Task 4 keyMonitor 的 Esc 分層依賴）。
    var hasSelection: Bool { annotations.selectedID != nil }

    /// 解除選取＋清熱狀態＋清 select 拖曳狀態（Esc／點空白處／Delete 後共用）。
    func deselect() {
        annotations.selectedID = nil
        clearHotAnnotation()
        selectDrag = nil
        needsDisplay = true
    }

    // MARK: 文字編輯（階段 3；唯一的子 view 特例）
    private var textEditor: InlineTextView?
    /// 重編輯中的既有文字物件（渲染時跳過避免重影；commit 時 update/remove）。
    private var editingTextID: UUID?
    /// 文字工具 hover 中的既有文字物件（驗收回饋 Fix 2：畫虛線框＋openHand 游標）。
    private var hoveredTextID: UUID?
    /// 文字拖移候選：mouseDown 命中既有文字時記錄；≥3pt 才轉為移動，否則 mouseUp＝重編輯
    /// （驗收回饋 Fix 3）。
    private var textDragCandidate: (id: UUID, startMouse: CGPoint, startOrigin: CGPoint)?
    private var textDragBegan = false   // 首次實際位移才 beginChange（熱圖形滾輪調整同慣例）

    var isEditingText: Bool { textEditor != nil }
    /// 輸入法組字中（注音等 marked text）——此時 Esc 要讓給 IME 清組字，不能當 commit。
    var isComposingText: Bool { textEditor?.hasMarkedText() ?? false }

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
        toolbar.onToolSelected = { [weak self] tool in
            guard let self else { return }
            self.commitTextEditing()   // 編輯中切工具＝先落字，避免編輯器與工具狀態不同步
            self.activeTool = tool
            if tool != .select { self.deselect() }   // 切離 select（含取消作用）＝清選取，
                                                     // 否則殘留的隱形選取會劣化 Esc 並讓 Delete 靜默刪物件
            self.clearHotAnnotation()   // 切工具或取消作用 → 解除熱狀態（spec）
            self.hoveredTextID = nil    // 切工具 → 清 hover 提示（驗收回饋 Fix 2）
            if let tool {
                self.currentStyle = AnnotationStyleStore.style(for: tool)
                self.toolbar.setStyle(self.currentStyle)
            }
            self.onInteraction?()
            // 樣式列顯隱改變工具列高度 → 重新定位
            if let sel = self.selection { self.layoutToolbar(for: sel) }
            self.needsDisplay = true
        }
        toolbar.onStyleChanged = { [weak self] style in
            guard let self else { return }
            self.currentStyle = style
            if self.activeTool == .select {
                // select＋有選取＝改選取物件本身的樣式（單發快照），不寫入每工具記憶（spec）。
                if let id = self.annotations.selectedID {
                    self.annotations.update(id: id) { $0.style = style }
                    self.syncUndoButtons()
                    self.needsDisplay = true
                }
            } else if let tool = self.activeTool {
                AnnotationStyleStore.save(style, for: tool)
            }
            self.onInteraction?()
        }
        toolbar.onUndo = { [weak self] in self?.undoAnnotation() }
        toolbar.onRedo = { [weak self] in self?.redoAnnotation() }
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
        // 文字工具懸浮在既有文字上＝可拖曳移動，用開手游標提示（驗收回饋 Fix 2）。
        if activeTool == .text, hitTextObject(at: point) != nil { return .openHand }
        if activeTool == .select { return selectCursor(at: point) }
        if activeTool != nil { return .crosshair }   // 繪製工具＝十字線（spec）
        if let sel = selection, !frameLocked {       // 鎖框時無控制點、不可移動
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

    /// select 工具游標：選取物件的四角 handle＝對角 resize；物件本體＝開手；其餘＝箭頭（spec）。
    private func selectCursor(at point: CGPoint) -> NSCursor {
        if let selID = annotations.selectedID,
           let selected = annotations.objects.first(where: { $0.id == selID }),
           let handle = hitAnnotationHandle(point, for: selected) {
            switch handle {
            case .topLeft, .bottomRight: return Self.cursorNWSE
            case .topRight, .bottomLeft: return Self.cursorNESW
            }
        }
        if annotations.hitTest(at: point) != nil { return .openHand }
        return .arrow
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
        // 文字工具 hover 既有文字 → 記錄以畫虛線框（驗收回饋 Fix 2）；變化才重繪。
        let newHover = (activeTool == .text) ? hitTextObject(at: p)?.id : nil
        if newHover != hoveredTextID {
            hoveredTextID = newHover
            needsDisplay = true
        }
        let prev = hoverPoint
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: p) }
    }
    override func mouseExited(with event: NSEvent) {
        if hoveredTextID != nil {
            hoveredTextID = nil
            needsDisplay = true
        }
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

            // 標註（含拖曳中的暫定形狀）疊在亮區上、裁到框內——畫面上看得到的
            // 才會被擷取（所見即所存；框外部分匯出時被裁掉，乾脆不畫）。
            if !annotations.isEmpty || provisionalShape != nil {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                if let cg = NSGraphicsContext.current?.cgContext {
                    AnnotationRenderer.render(
                        annotations.objects.filter { $0.id != editingTextID },
                        in: cg, counterNumbers: counterNumbersMap(), sourceProvider: frozenImageProvider())
                    if let shape = provisionalShape {
                        AnnotationRenderer.render(
                            [Annotation(shape: shape, style: currentStyle)], in: cg, sourceProvider: frozenImageProvider())
                    }
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            }

            // 文字工具 hover 既有文字 → 白色虛線框提示（拖曳中不畫，避免視覺干擾；
            // 驗收回饋 Fix 2）。
            if let hoveredID = hoveredTextID, textDragCandidate == nil,
               let obj = annotations.objects.first(where: { $0.id == hoveredID }) {
                let box = obj.bounds.insetBy(dx: -4, dy: -4)
                let hoverPath = NSBezierPath(rect: box)
                hoverPath.setLineDash([4, 3], count: 2, phase: 0)
                hoverPath.lineWidth = 1
                NSColor.white.setStroke()
                hoverPath.stroke()
            }

            // select 工具：選取物件的 chrome——白色虛線框＋（可縮放時）四角 handle，
            // 拖曳中隱藏 handle（畫面乾淨，比照框選 handle 的既有慣例）。
            if activeTool == .select, let selID = annotations.selectedID,
               let selected = annotations.objects.first(where: { $0.id == selID }) {
                let chrome = selected.bounds.insetBy(dx: -4, dy: -4)
                let chromePath = NSBezierPath(rect: chrome)
                chromePath.setLineDash([4, 3], count: 2, phase: 0)
                chromePath.lineWidth = 1
                NSColor.white.setStroke()
                chromePath.stroke()
                if selected.isCornerResizable, selectDrag == nil {
                    NSColor.controlAccentColor.setFill()
                    NSColor.white.setStroke()
                    for (_, hp) in annotationHandlePoints(chrome) {
                        let h = handleRect(at: hp)
                        let path = NSBezierPath(rect: h)
                        path.fill()
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
            }

            // 拖曳中不畫控制點（畫面乾淨）；靜止時畫 8 個控制點
            if drag == nil, !frameLocked {
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

        if let secs = watchdogWarningSeconds { drawWatchdogBanner(seconds: secs) }
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

    /// 放大鏡顯示點：任何拖曳中（調框或畫標註）→拖曳點；尚未框選→hover 點；其餘不顯示。
    private func activeLoupePoint() -> CGPoint? {
        if drag != nil || shapeAnchor != nil { return dragPoint }
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

    /// 看門狗倒數橫幅：置頂中央、醒目紅底。任何輸入會讓 controller 清掉它。
    private func drawWatchdogBanner(seconds: Int) {
        let text = "無操作，\(seconds) 秒後自動取消——動一下滑鼠即繼續" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 14
        let rect = CGRect(x: (bounds.width - size.width) / 2 - pad,
                          y: bounds.height - 80,
                          width: size.width + pad * 2,
                          height: size.height + 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.1, alpha: 0.9).setFill()
        path.fill()
        text.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 8), withAttributes: attrs)
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

    // MARK: select 工具：選取物件的四角 handle（僅 isCornerResizable 物件；比照框選 handle 樣式）

    private enum AnnotationHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    private func annotationHandlePoints(_ r: CGRect) -> [(AnnotationHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottomRight, CGPoint(x: r.maxX, y: r.minY))]
    }
    /// 命中選取物件的縮放 handle（chrome＝bounds 外擴 4pt，與 draw() 畫的虛線框同一矩形）。
    private func hitAnnotationHandle(_ point: CGPoint, for annotation: Annotation) -> AnnotationHandle? {
        guard annotation.isCornerResizable else { return nil }
        let chrome = annotation.bounds.insetBy(dx: -4, dy: -4)
        for (handle, p) in annotationHandlePoints(chrome) {
            if handleRect(at: p).insetBy(dx: -4, dy: -4).contains(point) { return handle }
        }
        return nil
    }
    /// 由拖出的四角 handle 算新 bounds；允許拖過頭翻轉，用 min/max 正規化（比照既有 resize 慣例）。
    private func resizeAnnotationBounds(_ start: CGRect, handle: AnnotationHandle, to p: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .topLeft:     minX = p.x; maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .bottomRight: maxX = p.x; minY = p.y
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: 滑鼠

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        clearHotAnnotation()   // 任何 mouseDown 分支都解除熱狀態（spec）
        let p = convert(event.locationInWindow, from: nil)
        dragPoint = p
        // 編輯中點擊＝先完成目前編輯；若同一下點在「另一個既有文字」上，
        // 直接落入下方文字路由接手（換編輯/拖移那一個），不用再點第二下。
        // 點在其他地方則維持「第一下只結束編輯」——避免點外面收尾時誤開新編輯器。
        if isEditingText {
            let previousEditingID = editingTextID
            commitTextEditing()
            if activeTool == .text, let hit = hitTextObject(at: p), hit.id != previousEditingID {
                // 不 return：往下走 .text 路由
            } else {
                return
            }
        }
        // 標註工具作用中 → 依工具型態路由
        if let tool = activeTool, selection != nil {
            switch tool {
            case .select:
                handleSelectDown(at: p)
            case .counter:
                addCounter(at: p)
            case .text:
                // 命中既有文字＝記錄拖移候選、不開編輯器（驗收回饋 Fix 3）；
                // 沒命中才維持原本「框內開新編輯器」。
                if let hit = hitTextObject(at: p), case .text(let origin, _) = hit.shape {
                    textDragCandidate = (id: hit.id, startMouse: p, startOrigin: origin)
                } else {
                    handleTextClick(at: p)
                }
            case .rect, .ellipse, .line, .arrow, .pixelate:
                shapeAnchor = p
                provisionalShape = makeShape(tool: tool, from: p, to: p)
                needsDisplay = true
            case .freehand, .highlighter:
                strokePoints = [p]
                provisionalShape = (tool == .freehand) ? .freehand(points: strokePoints)
                                                       : .highlighter(points: strokePoints)
                needsDisplay = true
            }
            return
        }
        // 有標註鎖框：不建新框、不移動、不縮放
        if frameLocked { return }
        if let sel = selection {
            if let h = hitHandle(p, in: sel) {
                annotations.clearRedo()   // 框幾何變動：舊 redo 的座標語意已失效（spec）
                drag = .resizing(handle: h, startRect: sel)
                return
            }
            if sel.contains(p) {
                annotations.clearRedo()
                drag = .moving(startMouse: p, startRect: sel)
                return
            }
        }
        // 空白處按下 → 開新框
        annotations.clearRedo()
        drag = .creating(anchor: p)
        selection = CGRect(origin: p, size: .zero)
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        dragPoint = p
        // 文字拖移候選：≥3pt 才轉為真正移動（驗收回饋 Fix 3；防誤點沿用形狀成形的慣例）。
        if let candidate = textDragCandidate {
            let dx = p.x - candidate.startMouse.x
            let dy = p.y - candidate.startMouse.y
            if textDragBegan || abs(dx) >= 3 || abs(dy) >= 3 {
                if !textDragBegan {
                    annotations.beginChange()   // 首次實際位移才拍快照，整段拖移合併一步 undo
                    textDragBegan = true
                    syncUndoButtons()
                }
                let newOrigin = CGPoint(x: candidate.startOrigin.x + dx, y: candidate.startOrigin.y + dy)
                annotations.updateWithoutSnapshot(id: candidate.id) { a in
                    if case .text(_, let string) = a.shape {
                        a.shape = .text(origin: newOrigin, string: string)
                    }
                }
                NSCursor.closedHand.set()
                needsDisplay = true
            }
            return
        }
        // select 工具：移動/縮放——首次實際位移才 beginChange()，之後 updateWithoutSnapshot；
        // 兩者都每次從 mouseDown 時保存的 startShape 出發，避免累積誤差（spec）。
        if let sd = selectDrag {
            switch sd {
            case .moving(let id, let startMouse, let startShape):
                let delta = CGVector(dx: p.x - startMouse.x, dy: p.y - startMouse.y)
                if selectDragBegan || delta.dx != 0 || delta.dy != 0 {
                    if !selectDragBegan {
                        annotations.beginChange()
                        selectDragBegan = true
                        syncUndoButtons()
                    }
                    annotations.updateWithoutSnapshot(id: id) { a in
                        a.shape = startShape
                        a.move(by: delta)
                    }
                    NSCursor.closedHand.set()
                    needsDisplay = true
                }
            case .resizing(let id, let handle, let startBounds, let startShape):
                let newBounds = resizeAnnotationBounds(startBounds, handle: handle, to: p)
                if selectDragBegan || newBounds != startBounds {
                    if !selectDragBegan {
                        annotations.beginChange()
                        selectDragBegan = true
                        syncUndoButtons()
                    }
                    annotations.updateWithoutSnapshot(id: id) { a in
                        a.shape = startShape
                        a.scaled(from: startBounds, to: newBounds)
                    }
                    needsDisplay = true
                }
            }
            return
        }
        if let tool = activeTool, !strokePoints.isEmpty,
           tool == .freehand || tool == .highlighter {
            strokePoints.append(p)
            provisionalShape = (tool == .freehand) ? .freehand(points: strokePoints)
                                                   : .highlighter(points: strokePoints)
            needsDisplay = true
            return
        }
        if let tool = activeTool, let anchor = shapeAnchor {
            provisionalShape = makeShape(tool: tool, from: anchor, to: p)
            needsDisplay = true
            return
        }
        guard let drag else { return }
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
        let p = convert(event.locationInWindow, from: nil)
        // select 工具收尾：清拖曳狀態＋同步 undo 按鈕；雙擊命中既有文字物件＝重編輯
        // （select 工具的入口，spec 原文）。
        if activeTool == .select {
            if selectDragBegan { syncUndoButtons() }
            selectDrag = nil
            selectDragBegan = false
            if event.clickCount == 2, let hit = hitTextObject(at: p),
               case .text(let origin, let string) = hit.shape {
                openTextEditor(origin: origin, initialString: string, existing: hit)
            }
            needsDisplay = true
            return
        }
        // 文字拖移候選收尾（驗收回饋 Fix 3）：有實際位移＝完成移動（進熱狀態，滾輪可調字級）；
        // 沒動過＝當成一般點擊，走原本的重編輯路徑。
        if let candidate = textDragCandidate {
            if textDragBegan {
                hotAnnotationID = candidate.id
                syncUndoButtons()
            } else if let obj = annotations.objects.first(where: { $0.id == candidate.id }),
                      case .text(let origin, let string) = obj.shape {
                openTextEditor(origin: origin, initialString: string, existing: obj)
            }
            textDragCandidate = nil
            textDragBegan = false
            needsDisplay = true
            return
        }
        if let tool = activeTool, !strokePoints.isEmpty,
           tool == .freehand || tool == .highlighter {
            defer { strokePoints = []; provisionalShape = nil; dragPoint = nil
                    needsDisplay = true }
            let first = strokePoints[0]
            guard strokePoints.count > 1,
                  strokePoints.contains(where: { abs($0.x - first.x) >= 3 || abs($0.y - first.y) >= 3 })
            else { return }
            let shape: Annotation.Shape = (tool == .freehand)
                ? .freehand(points: strokePoints) : .highlighter(points: strokePoints)
            let annotation = Annotation(shape: shape, style: currentStyle)
            let half = annotation.effectiveStrokeWidth / 2
            if let sel = selection,
               annotation.bounds.insetBy(dx: -half, dy: -half).intersects(sel) {
                annotations.add(annotation)
                syncUndoButtons()
                hotAnnotationID = annotation.id
            }
            return
        }
        if let tool = activeTool, let anchor = shapeAnchor {
            // ≥3pt 才成形（spec：防誤點）；add() 自帶 undo 快照
            if abs(p.x - anchor.x) >= 3 || abs(p.y - anchor.y) >= 3 {
                let annotation = Annotation(shape: makeShape(tool: tool, from: anchor, to: p),
                                            style: currentStyle)
                // 只收與框相交的標註：框外暗區拖出的標註被 clip 看不見、卻會無聲鎖框
                //（總審查 Important）。用相交而非起點判定——從框外畫進框內的箭頭仍合法。
                let half = currentStyle.lineWidth / 2
                if let sel = selection,
                   annotation.bounds.insetBy(dx: -half, dy: -half).intersects(sel) {
                    annotations.add(annotation)
                    syncUndoButtons()
                    hotAnnotationID = annotation.id   // 剛畫完的圖形進入熱狀態（spec）
                }
            }
            shapeAnchor = nil
            provisionalShape = nil
            dragPoint = nil
            needsDisplay = true
            return
        }
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
    }

    // 右鍵：命中任一標註物件（不限已選取、不限目前工具）→ 選取它並彈出 z-order/刪除選單；
    // 空白處＝維持既有逃生路徑（onCancel，一個字不能動）。
    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = annotations.hitTest(at: p) else {
            onCancel?()
            return
        }
        annotations.selectedID = hit.id
        needsDisplay = true
        let menu = NSMenu()
        menu.addItem(makeContextMenuItem(title: "移到最前", action: #selector(contextBringToFront)))
        menu.addItem(makeContextMenuItem(title: "移到最後", action: #selector(contextSendToBack)))
        menu.addItem(makeContextMenuItem(title: "刪除", action: #selector(contextDelete)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeContextMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextBringToFront() {
        guard let id = annotations.selectedID else { return }
        annotations.bringToFront(id: id)
        syncUndoButtons()
        needsDisplay = true
    }
    @objc private func contextSendToBack() {
        guard let id = annotations.selectedID else { return }
        annotations.sendToBack(id: id)
        syncUndoButtons()
        needsDisplay = true
    }
    @objc private func contextDelete() {
        guard let id = annotations.selectedID else { return }
        annotations.remove(id: id)
        deselect()
        syncUndoButtons()
        needsDisplay = true
    }

    // 捲動也算互動（重置看門狗）。標註工具作用中：滾輪調整粗細（每 5 單位一步、一步 ±1pt），
    // 事件吞掉不往下傳；未作用時照常傳遞。
    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        if isEditingText { return }   // 編輯中的滾輪不調粗細也不傳遞（IME/文字編輯器已在處理）
        guard activeTool != nil else {
            super.scrollWheel(with: event)
            return
        }
        lineWidthScrollAccum += event.scrollingDeltaY
        let step: CGFloat = 5
        while lineWidthScrollAccum >= step {
            lineWidthScrollAccum -= step
            adjustLineWidth(by: 1)
        }
        while lineWidthScrollAccum <= -step {
            lineWidthScrollAccum += step
            adjustLineWidth(by: -1)
        }
    }

    /// 粗細調整（spec 2026-07-22 修訂：連續值，一步 ±1pt，clamp 1–24）。
    /// 有熱圖形＝優先改它（畫面即時反映、整段合併一步 undo）；否則只改 currentStyle
    /// （含拖曳中的 provisional 形狀，因為 draw() 用 currentStyle 畫它）。
    /// 兩種情況都同步 currentStyle、AnnotationStyleStore.save、toolbar.setStyle、needsDisplay。
    private func adjustLineWidth(by delta: Int) {
        if let hotID = hotAnnotationID,
           let idx = annotations.objects.firstIndex(where: { $0.id == hotID }) {
            let current = annotations.objects[idx].style.lineWidth
            let newWidth = AnnotationStyle.clampLineWidth(current + CGFloat(delta))
            guard newWidth != current else { return }
            // 首次實際改動才 beginChange()（拍一次快照）；之後同一段調整都用
            // updateWithoutSnapshot，不可每格滾動都 push 快照。
            if !hotScrollBegan {
                annotations.beginChange()
                hotScrollBegan = true
            }
            annotations.updateWithoutSnapshot(id: hotID) { $0.style.lineWidth = newWidth }
            currentStyle.lineWidth = newWidth
            // select 模式調的是選取物件本身的樣式，不寫入每工具記憶（spec）。
            if let tool = activeTool, tool != .select { AnnotationStyleStore.save(currentStyle, for: tool) }
            toolbar.setStyle(currentStyle)
            syncUndoButtons()   // beginChange 改變了 canUndo
            needsDisplay = true
        } else {
            let current = currentStyle.lineWidth
            let newWidth = AnnotationStyle.clampLineWidth(current + CGFloat(delta))
            guard newWidth != current else { return }
            currentStyle.lineWidth = newWidth
            if let tool = activeTool, tool != .select { AnnotationStyleStore.save(currentStyle, for: tool) }
            toolbar.setStyle(currentStyle)
            needsDisplay = true   // 拖曳中的暫定形狀即時反映新粗細
        }
    }

    override func keyDown(with event: NSEvent) {
        onInteraction?()
        // ⌘Z / ⌘⇧Z：標註 undo/redo（手動攔，不經 menu——overlay 是 nonactivating panel）
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                redoAnnotation()
            } else {
                undoAnnotation()
            }
            return
        }
        // ⌘] / ⌘[：選取物件移到最前/最後（比照 ⌘Z 的修飾鍵排除法）
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers, chars == "]" || chars == "[" {
            if let id = annotations.selectedID {
                if chars == "]" { annotations.bringToFront(id: id) } else { annotations.sendToBack(id: id) }
                syncUndoButtons()
                needsDisplay = true
            }
            return
        }
        switch event.keyCode {
        case 53:            // Esc → 分層：編輯中完成編輯 → 有選取解除選取 → 否則取消（spec）
            if isEditingText {
                commitTextEditing()
            } else if hasSelection {
                deselect()
            } else {
                onCancel?()
            }
        case 36, 76:        // Return / Enter → 擷取
            confirm()
        case 51, 117:       // Delete / fn+Delete → 移除選取物件
            if let id = annotations.selectedID {
                annotations.remove(id: id)
                deselect()
                syncUndoButtons()
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: 標註操作

    private func makeShape(tool: AnnotationTool, from a: CGPoint, to b: CGPoint) -> Annotation.Shape {
        switch tool {
        case .rect:    return .rect(CoordinateUtils.rect(from: a, to: b))
        case .ellipse: return .ellipse(CoordinateUtils.rect(from: a, to: b))
        case .line:    return .line(from: a, to: b)
        case .arrow:   return .arrow(from: a, to: b)
        case .pixelate: return .pixelate(rect: CoordinateUtils.rect(from: a, to: b))
        case .text, .counter, .freehand, .highlighter, .select:
            preconditionFailure("此工具不走兩點成形")
        }
    }

    /// 序號：點擊即生成下一號（編號渲染時算）；框外不入庫；進熱狀態（滾輪調大小）。
    private func addCounter(at p: CGPoint) {
        let a = Annotation(shape: .counter(center: p), style: currentStyle)
        guard let sel = selection, a.bounds.intersects(sel) else { return }
        annotations.add(a)
        syncUndoButtons()
        hotAnnotationID = a.id
        needsDisplay = true
    }

    /// 命中既有文字物件（由上到下找第一個）；點擊路由與 hover 提示共用（驗收回饋 Fix 2；
    /// threshold 統一 4，與 hover 虛線框 inset 一致——清理項）。
    private func hitTextObject(at p: CGPoint) -> Annotation? {
        annotations.objects.reversed().first(where: {
            if case .text = $0.shape { return $0.hitTest(p, threshold: 4) } else { return false }
        })
    }

    /// select 工具 mouseDown 路由：命中已選取物件的四角 handle → 進入縮放；
    /// 命中物件本體（含新命中）→ 選取＋進入移動候選；未命中 → 解除選取。
    private func handleSelectDown(at p: CGPoint) {
        if let selID = annotations.selectedID,
           let selected = annotations.objects.first(where: { $0.id == selID }),
           let handle = hitAnnotationHandle(p, for: selected) {
            selectDrag = .resizing(id: selID, handle: handle, startBounds: selected.bounds, startShape: selected.shape)
            hotAnnotationID = selID   // 重設熱狀態（mouseDown 開頭 clearHotAnnotation 已清，spec）
            return
        }
        guard let hit = annotations.hitTest(at: p) else {
            deselect()
            return
        }
        annotations.selectedID = hit.id
        hotAnnotationID = hit.id   // 重設熱狀態（同上）
        toolbar.setStyle(hit.style)
        selectDrag = .moving(id: hit.id, startMouse: p, startShape: hit.shape)
        needsDisplay = true
    }

    /// 文字：在點擊處開新編輯器。命中既有文字的情況已在 mouseDown 分流成拖曳候選
    /// （驗收回饋 Fix 3：mouseDown 命中既有文字時不會呼叫這裡），這裡只處理「沒命中」。
    private func handleTextClick(at p: CGPoint) {
        // 框外不開新編輯器：文字輸入成本高，不能等 commit 才靜默丟棄。
        guard let sel = selection, sel.contains(p) else { return }
        openTextEditor(origin: p, initialString: "", existing: nil)
    }

    private func openTextEditor(origin: CGPoint, initialString: String, existing: Annotation?) {
        commitTextEditing()   // 保險：一次只開一個
        let style = existing?.style ?? currentStyle
        let fontSize = style.textFontSize
        let color = NSColor(cgColor: style.color.cgColor) ?? .white
        let editor = InlineTextView.make(origin: origin, fontSize: fontSize,
                                         color: color, initialString: initialString)
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        addSubview(editor)
        textEditor = editor
        editingTextID = existing?.id
        window?.makeFirstResponder(editor)
        needsDisplay = true   // 重編輯時 draw 要立刻跳過原物件
    }

    /// 完成文字編輯：非空→入庫（新建 add／重編輯 update，各一步 undo）；
    /// 空字串→丟棄（重編輯＝刪除原物件）。結束後 first responder 還給自己。
    func commitTextEditing() {
        guard let editor = textEditor else { return }
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editor.textOrigin   // 驗收回饋 Fix 1：直接讀 make() 記錄的值，不從 frame 反推
        if let id = editingTextID {
            if string.isEmpty {
                annotations.remove(id: id)
            } else {
                annotations.update(id: id) { a in
                    if case .text(let o, _) = a.shape { a.shape = .text(origin: o, string: string) }
                }
            }
        } else if !string.isEmpty {
            let a = Annotation(shape: .text(origin: origin, string: string), style: currentStyle)
            if let sel = selection, a.bounds.intersects(sel) {   // 框外不入庫 guard 沿用
                annotations.add(a)
                hotAnnotationID = a.id
            }
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingTextID = nil
        window?.makeFirstResponder(self)   // 還 first responder：Esc/Enter/⌘Z 恢復由本 view 處理
        syncUndoButtons()
        needsDisplay = true
    }

    private func undoAnnotation() {
        commitTextEditing()   // 編輯中按 undo/redo：先落字，避免 update(id:) 對已消失物件靜默 no-op 丟字
        guard annotations.canUndo else { return }
        annotations.undo()
        clearHotAnnotation()   // spec：undo/redo 清除熱狀態
        syncUndoButtons()
        needsDisplay = true
        // invalidateCursorRects 已證實對此 view 是 no-op（無 mouseMoved 觸發游標重算），
        // 改在此手動依上次已知的游標位置重算，讓解鎖後控制點/游標立即復原。
        if let hp = hoverPoint { cursor(at: hp).set() }
    }

    private func redoAnnotation() {
        commitTextEditing()   // 編輯中按 undo/redo：先落字，避免 update(id:) 對已消失物件靜默 no-op 丟字
        guard annotations.canRedo else { return }
        annotations.redo()
        clearHotAnnotation()
        syncUndoButtons()
        needsDisplay = true
        if let hp = hoverPoint { cursor(at: hp).set() }
    }

    private func syncUndoButtons() {
        toolbar.setUndoState(canUndo: annotations.canUndo, canRedo: annotations.canRedo)
    }

    /// 序號編號查表（渲染時算、不存死——刪除/undo 天然正確）。
    private func counterNumbersMap() -> [UUID: Int] {
        var m: [UUID: Int] = [:]
        for a in annotations.objects {
            if case .counter = a.shape, let n = annotations.counterNumber(for: a.id) {
                m[a.id] = n
            }
        }
        return m
    }

    /// 馬賽克取樣：view 點座標矩形 → 原始凍結影像該區像素圖（非破壞鐵則：永遠取原始底圖）。
    /// 先與可視範圍（view bounds）取交集：矩形超出底圖（多螢幕拖過邊界）時只取交集，
    /// 並把交集矩形一併回傳給 renderer，避免縮小的 crop 被拉伸鋪滿整個原始 rect（總審查 Minor）。
    /// 交集為空＝完全在畫面外＝回 nil，renderer 走灰佔位路徑。
    private func frozenImageProvider() -> (CGRect) -> (image: CGImage, drawRect: CGRect)? {
        { [snapshot, boundsSize = bounds.size] rect in
            let clamped = rect.intersection(CGRect(origin: .zero, size: boundsSize))
            guard !clamped.isEmpty else { return nil }
            let pixelRect = CoordinateUtils.pixelCropRect(
                selection: clamped, displayPointSize: boundsSize, scale: snapshot.scale)
            guard let cropped = snapshot.cgImage.cropping(to: pixelRect) else { return nil }
            return (image: cropped, drawRect: clamped)
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

    /// 目前有效框的輸出影像（有標註就合成進去）；沒有有效框回 nil。
    /// 供「擷取」與看門狗逾時搶救共用——搶救因此自動含標註。
    func currentCroppedImage() -> NSImage? {
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return nil }
        let pixelRect = CoordinateUtils.pixelCropRect(
            selection: sel, displayPointSize: bounds.size, scale: snapshot.scale)
        guard let cropped = snapshot.cgImage.cropping(to: pixelRect) else { return nil }
        let final: CGImage
        if annotations.isEmpty {
            final = cropped
        } else if let composed = AnnotationRenderer.composite(
            objects: annotations.objects, overCropped: cropped,
            selection: sel, scale: snapshot.scale, counterNumbers: counterNumbersMap(), sourceProvider: frozenImageProvider()) {
            final = composed
        } else {
            NSLog("anypaint: 標註合成失敗，改輸出未標註裁切圖")
            final = cropped
        }
        let pointSize = NSSize(width: pixelRect.width / snapshot.scale,
                               height: pixelRect.height / snapshot.scale)
        return NSImage(cgImage: final, size: pointSize)
    }

    private func confirm() {
        commitTextEditing()
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持原行為：取消
            return
        }
        onConfirm?(image)
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

/// 協調多螢幕 overlay：單飛、不疊加、多條逃生路徑 + 免按鍵看門狗
/// （所有輸入即重置、觸發前倒數警告、逾時搶救存剪貼簿、0=關閉、秒數可設）。
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var onSelect: ((NSImage) -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?
    private var watchdogWarn: DispatchWorkItem?
    private var watchdogFire: DispatchWorkItem?
    private var warningTimer: Timer?
    private var warningRemaining = 0
    /// 觸發前多久開始倒數警告（spec 定 15 秒；最小可設秒數 60 > 15，不會交叉）。
    private let warningLead: TimeInterval = 15
    /// 上次重排看門狗的時間（防抖用）。
    private var lastArmUptimeNs: UInt64 = 0
    /// 最後一個有互動（滑鼠/鍵盤/滾輪）的視窗——看門狗逾時搶救取像時優先用它（Task 4）。
    private weak var lastInteractedWindow: SelectionOverlayWindow?

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
            window.selectionView?.onInteraction = { [weak self, weak window] in
                self?.armWatchdog()
                self?.lastInteractedWindow = window   // 搶救歸屬：記錄最後互動的視窗（Task 4）
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)   // 逃生路 1：keyDown/Esc 收得到
            windows.append(window)
        }

        // 逃生路 2：本地事件監聽——Esc 分層（組字讓位 → 編輯中先完成編輯 →
        // 有選取先解除選取 → 否則取消；Task 4 新增「解除選取」這一層）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.armWatchdog()          // 任何鍵都算互動（含文字編輯中打字）
            if event.keyCode == 53 {
                let views = (self?.windows ?? []).compactMap { $0.selectionView }
                // Esc 分層：有 view 在文字編輯中 → 一次完成「全部」視窗的編輯
                //（多螢幕各開一個編輯器也保證最多兩下 Esc 離開）；否則取消 overlay。
                let editing = views.filter { $0.isEditingText }
                // IME 組字中（注音打到一半）：把 Esc 讓給輸入法清組字，
                // 下一下 Esc 才輪到「完成編輯」——否則未組完的符號會被烙進字串。
                if editing.contains(where: { $0.isComposingText }) {
                    return event
                }
                if !editing.isEmpty {
                    editing.forEach { $0.commitTextEditing() }
                    return nil
                }
                // 有任一視窗選取著物件（select 工具）→ 先解除選取，Esc 不直接取消整個 overlay。
                if views.contains(where: { $0.hasSelection }) {
                    views.forEach { $0.deselect() }
                    return nil
                }
                self?.cancel()
                return nil
            }
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

    /// 重置看門狗：只在「無任何互動」達設定秒數才強制解除。
    /// 觸發前 warningLead 秒顯示倒數橫幅；秒數設 0 = 使用者選擇關閉，不排程。
    private func armWatchdog() {
        // 高頻互動（mouseMoved 等）防抖：0.5 秒內已排程且未在倒數警告中就不重排，
        // 避免堆積大量已取消的 work item（總審查建議）。誤差 ≤0.5 秒對 60 秒級逾時無感；
        // 倒數警告顯示中（warningTimer != nil）一律立即重排，橫幅才會即時消失。
        let now = DispatchTime.now().uptimeNanoseconds
        if warningTimer == nil, watchdogFire != nil, now &- lastArmUptimeNs < 500_000_000 { return }
        lastArmUptimeNs = now
        clearWatchdog()
        let total = AppSettings.overlayWatchdogSeconds
        guard total > 0 else { return }   // 0 = 關閉（使用者明確選擇）
        let warn = DispatchWorkItem { [weak self] in self?.beginWarningCountdown() }
        let fire = DispatchWorkItem { [weak self] in self?.watchdogDidFire() }
        watchdogWarn = warn
        watchdogFire = fire
        DispatchQueue.main.asyncAfter(deadline: .now() + total - warningLead, execute: warn)
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: fire)
    }

    private func clearWatchdog() {
        watchdogWarn?.cancel(); watchdogWarn = nil
        watchdogFire?.cancel(); watchdogFire = nil
        warningTimer?.invalidate(); warningTimer = nil
        setWarning(nil)
    }

    private func beginWarningCountdown() {
        warningRemaining = Int(warningLead)
        setWarning(warningRemaining)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.isActive else { t.invalidate(); return }
            self.warningRemaining -= 1
            if self.warningRemaining > 0 {
                self.setWarning(self.warningRemaining)
            } else {
                t.invalidate()   // 歸零後由 watchdogFire 收尾
            }
        }
        // .common：事件追蹤（拖曳）期間也要跳；預設模式會停擺。
        RunLoop.main.add(timer, forMode: .common)
        warningTimer = timer
    }

    private func setWarning(_ seconds: Int?) {
        for window in windows { window.selectionView?.watchdogWarningSeconds = seconds }
    }

    private func watchdogDidFire() {
        guard isActive else { return }
        // 搶救：有有效框就把目前內容存進剪貼簿再解除（走 finish 同一條路，
        // 效果等同擷取＝複製到剪貼簿），沒有就純取消。免輸入保證不變。
        // 搶救前先把編輯中的文字落定（影像才會與所見一致；使用者已缺席，盡力保留）。
        windows.compactMap { $0.selectionView }.forEach { $0.commitTextEditing() }
        // 取像順序：使用者最後互動的視窗優先（Task 4 搶救歸屬），nil 或已不在 windows 裡
        // 才 fallback 回原本的快照順序第一個。
        var candidates = windows.compactMap { $0.selectionView }
        if let lastView = lastInteractedWindow?.selectionView,
           let idx = candidates.firstIndex(where: { $0 === lastView }) {
            candidates.remove(at: idx)
            candidates.insert(lastView, at: 0)
        }
        if let image = candidates.compactMap({ $0.currentCroppedImage() }).first {
            NSLog("anypaint: 框選看門狗逾時，已把目前框選內容存入剪貼簿（搶救）")
            finish(with: image)
        } else {
            NSLog("anypaint: 框選看門狗逾時（無互動），強制解除")
            cancel()
        }
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
        clearWatchdog()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.arrow.set()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        lastInteractedWindow = nil
        onSelect = nil
        onCancel = nil
        isActive = false
    }
}

// 逃生路 4（保留）：SelectionView 右鍵在空白處＝取消；命中物件則改彈出 z-order/刪除選單
// （Task 4），空白處的取消路徑本身未動。
