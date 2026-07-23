import AppKit

// MARK: - 工具列

/// 選取框旁的浮動工具列（兩排）：上排＝標註工具｜undo/redo｜取消/複製，
/// 下排＝樣式（7 色塊＋粗細 pt 數值標籤，選了工具才顯示）。
/// 用一個會「吞掉滑鼠事件」的容器，避免點工具列時誤觸底下的 SelectionView。
final class SelectionToolbar: NSView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 按「貼」＝把目前框選（含標註）直接變成貼圖視窗（spec 截圖完直接貼）。
    var onPin: (() -> Void)?
    /// 按「存」＝把目前框選（含標註）存成 PNG 檔（spec 存檔）。
    var onSave: (() -> Void)?
    /// 按「另存為」＝彈 NSSavePanel 自選位置與檔名（spec 修訂：Save As 慣例）。
    var onSaveAs: (() -> Void)?
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
        let saveButton = NSButton()
        configureSymbolButton(saveButton, "square.and.arrow.down", #selector(saveAction))
        saveButton.toolTip = "儲存到預設資料夾（⌘S）"
        let saveAsButton = NSButton()
        configureSymbolButton(saveAsButton, "square.and.arrow.down.on.square", #selector(saveAsAction))
        saveAsButton.toolTip = "另存為…（⇧⌘S）"
        let pinButton = NSButton()
        configureSymbolButton(pinButton, "pin", #selector(pinAction))
        pinButton.toolTip = "貼上為浮動圖（⇧↩）"
        let confirm = NSButton(title: "複製", target: self, action: #selector(confirmAction))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .small
        confirm.toolTip = "複製到剪貼簿並結束（↩）"
        confirm.keyEquivalent = "\r"   // Enter = 複製
        toolsRow.addArrangedSubview(cancel)
        toolsRow.addArrangedSubview(saveButton)
        toolsRow.addArrangedSubview(saveAsButton)
        toolsRow.addArrangedSubview(pinButton)
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

    /// 覆寫樣式列顯隱（select 工具下：選了物件才出現，spec）。
    /// setActiveTool 的預設規則（tool == nil 才隱藏）對繪製工具已經足夠，
    /// select 工具需要呼叫端依 hasSelection 額外覆寫。
    func setStyleRowVisible(_ visible: Bool) {
        styleRow.isHidden = !visible
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
    @objc private func pinAction() { onPin?() }
    @objc private func saveAction() { onSave?() }
    @objc private func saveAsAction() { onSaveAs?() }
}

