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
    /// 按「存檔並開啟」＝存到預設資料夾後交給系統預設圖片程式（在那裡繼續標註）。
    var onOpen: (() -> Void)?
    /// 按「複製文字」＝辨識框內文字／QR 並複製（Shottr 同款的一步到位）。
    var onRecognizeText: (() -> Void)?
    /// 點工具按鈕；再點一次作用中的工具＝取消作用（回傳 nil）。
    var onToolSelected: ((AnnotationTool?) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?
    /// 按「裁切」＝把選中的封閉多邊形外裁掉（去背），換成編輯中的新底圖。
    var onCrop: (() -> Void)?
    /// 按「拉直」＝把選中的 4 角多邊形透視校正成正矩形，換成編輯中的新底圖。
    var onPerspective: (() -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [AnnotationColor: NSButton] = [:]
    /// 控件 → 說明文字。hover 時查這張表填 hintLabel。
    private var hints: [NSView: String] = [:]
    /// 沒 hover 任何按鈕時的預設說明——說明列高度固定，空著也是空著，
    /// 不如拿來當「接下來能做什麼」的指引。
    private static let defaultHint = "選一個工具開始標註，或直接按「複製」（↩）"

    /// hover 說明列：滑鼠移到哪顆鈕，就在工具列底部顯示它是做什麼的。
    ///
    /// **不靠系統 tooltip**：一來 overlay 是 `.screenSaver` level 的 nonactivating panel，
    /// tooltip 自己也是視窗，會不會被蓋住我無法在這裡自證（搜尋也沒找到明確結論）；
    /// 二來系統 tooltip 要停留一兩秒才浮出，對這種一整排的小圖示太慢。
    /// 固定高度＝有沒有文字都不會讓工具列忽高忽低。
    /// toolTip 仍照樣設——原生若有效就是附贈，不衝突。
    private let hintLabel: NSTextField = {
        let l = NSTextField(labelWithString: SelectionToolbar.defaultHint)
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor(white: 1, alpha: 0.75)
        l.lineBreakMode = .byTruncatingTail
        l.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return l
    }()
    /// 粗細數值標籤（spec 2026-07-22 修訂：三檔按鈕改連續值，工具列只顯示目前 pt 數）。
    private let lineWidthLabel: NSTextField = {
        let l = NSTextField(labelWithString: "4 pt")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .white
        return l
    }()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    /// 線條粗細加減鈕（上下箭頭；滾輪之外的另一種調法）。
    private let lineWidthStepper = NSStepper()
    /// 影像轉換動作鈕（選中封閉多邊形才顯示；4 角時才顯示「拉直」）。
    private let cropButton = NSButton(title: "裁切", target: nil, action: nil)
    private let perspectiveButton = NSButton(title: "拉直", target: nil, action: nil)
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
        let symbols: [(AnnotationTool, String, String)] = [
            (.select, "cursorarrow", "選取：點已畫好的標註來搬移、改樣式或刪除"),
            (.rect, "rectangle", "矩形"), (.ellipse, "circle", "橢圓"),
            (.line, "line.diagonal", "直線"), (.arrow, "arrow.up.right", "箭頭"),
            (.freehand, "pencil", "畫筆：手繪線條"),
            (.highlighter, "highlighter", "螢光筆：半透明色塊"),
            (.pixelate, "squareshape.split.3x3", "馬賽克：遮住敏感內容"),
            (.text, "textformat", "文字：點一下開始輸入"),
            (.counter, "1.circle", "序號：依序編號的圓圈"),
            (.measure, "ruler", "測量：拖出範圍量像素——斜拉另給對角線長度，細長條只給單邊"),
            (.polygon, "pentagon", "多邊形：逐點點擊圈出斜的區塊，點回起點或雙擊收尾")
        ]
        for (tool, symbol, help) in symbols {
            let b = NSButton()
            configureSymbolButton(b, symbol, #selector(toolTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            setHelp(help, for: b)
            toolButtons[tool] = b
            toolsRow.addArrangedSubview(b)
        }
        toolsRow.addArrangedSubview(separator())
        configureSymbolButton(undoButton, "arrow.uturn.backward", #selector(undoTapped))
        configureSymbolButton(redoButton, "arrow.uturn.forward", #selector(redoTapped))
        setHelp("復原上一步（⌘Z）", for: undoButton)
        setHelp("重做（⇧⌘Z）", for: redoButton)
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        toolsRow.addArrangedSubview(undoButton)
        toolsRow.addArrangedSubview(redoButton)
        toolsRow.addArrangedSubview(separator())
        // 影像轉換動作（選中封閉多邊形才顯示）——擺在裁切/存檔動作那側。
        for (b, sel, help) in [
            (cropButton, #selector(cropAction), "把選中的封閉多邊形外裁掉（去背），換成編輯中的新底圖"),
            (perspectiveButton, #selector(perspectiveAction), "把選中的 4 角多邊形透視校正拉直成正矩形，換成新底圖")
        ] {
            b.target = self; b.action = sel
            b.bezelStyle = .rounded; b.controlSize = .small
            b.isHidden = true
            setHelp(help, for: b)
            toolsRow.addArrangedSubview(b)
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        setHelp("放棄這次截圖（Esc）", for: cancel)
        // 「取出內容」而非「輸出檔案」——所以擺在存檔那組之前，不混在一起。
        let ocrButton = NSButton()
        configureSymbolButton(ocrButton, "text.viewfinder", #selector(recognizeTextAction))
        setHelp("辨識框內文字並複製；框到 QR 碼則複製其內容（⌘T）", for: ocrButton)
        let saveButton = NSButton()
        configureSymbolButton(saveButton, "square.and.arrow.down", #selector(saveAction))
        setHelp("儲存到預設資料夾（⌘S）", for: saveButton)
        let saveAsButton = NSButton()
        configureSymbolButton(saveAsButton, "square.and.arrow.down.on.square", #selector(saveAsAction))
        setHelp("另存為…自選位置與檔名（⇧⌘S）", for: saveAsButton)
        // 緊鄰存/另存：三顆同屬「落成檔案」語意。symbol 名已實測可解析（macOS 14 最低）。
        let openButton = NSButton()
        configureSymbolButton(openButton, "arrow.up.forward.app", #selector(openAction))
        setHelp("存檔並用外部 App 開啟，在那裡繼續編輯（⌘O）", for: openButton)
        let pinButton = NSButton()
        configureSymbolButton(pinButton, "pin", #selector(pinAction))
        setHelp("貼成螢幕上的浮動圖（⇧↩）", for: pinButton)
        let confirm = NSButton(title: "複製", target: self, action: #selector(confirmAction))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .small
        setHelp("複製到剪貼簿並結束（↩）", for: confirm)
        confirm.keyEquivalent = "\r"   // Enter = 複製
        toolsRow.addArrangedSubview(cancel)
        toolsRow.addArrangedSubview(ocrButton)
        toolsRow.addArrangedSubview(saveButton)
        toolsRow.addArrangedSubview(saveAsButton)
        toolsRow.addArrangedSubview(openButton)
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
            setHelp(color.displayName, for: b)
            colorButtons[color] = b
            styleRow.addArrangedSubview(b)
        }
        styleRow.addArrangedSubview(separator())
        // 滾輪調粗細是隱藏功能（SelectionView.scrollWheel，工具作用中每 5 單位 ±1pt），
        // 不寫出來沒人會發現。
        setHelp("線條粗細——滾動滑鼠滾輪，或按右側上下鈕調整", for: lineWidthLabel)
        styleRow.addArrangedSubview(lineWidthLabel)
        lineWidthStepper.minValue = Double(AnnotationStyle.clampLineWidth(1))
        lineWidthStepper.maxValue = Double(AnnotationStyle.clampLineWidth(24))
        lineWidthStepper.increment = 1
        lineWidthStepper.valueWraps = false
        lineWidthStepper.integerValue = Int(currentStyle.lineWidth.rounded())
        lineWidthStepper.target = self
        lineWidthStepper.action = #selector(lineWidthStepped)
        setHelp("線條粗細加減（上下鈕）", for: lineWidthStepper)
        styleRow.addArrangedSubview(lineWidthStepper)
        styleRow.isHidden = true

        let stack = NSStackView(views: [toolsRow, styleRow, hintLabel])
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

    /// 說明文字設一次、兩處生效：系統 tooltip 與工具列自己的 hover 說明列。
    private func setHelp(_ text: String, for view: NSView) {
        view.toolTip = text
        hints[view] = text
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
        lineWidthStepper.integerValue = Int(style.lineWidth.rounded())
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
        let newTool = AnnotationInput.toggledTool(tapped: tool, active: activeTool)
        setActiveTool(newTool)
        onToolSelected?(newTool)
    }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func cropAction() { onCrop?() }
    @objc private func perspectiveAction() { onPerspective?() }

    /// 依目前選取狀態顯示/隱藏影像轉換動作鈕（選中封閉多邊形＝可裁切；4 角＝可拉直）。
    func setTransformActions(canCrop: Bool, canPerspective: Bool) {
        cropButton.isHidden = !canCrop
        perspectiveButton.isHidden = !canPerspective
    }
    @objc private func lineWidthStepped(_ sender: NSStepper) {
        currentStyle.lineWidth = AnnotationStyle.clampLineWidth(CGFloat(sender.integerValue))
        setStyle(currentStyle)            // 同步標籤/夾限
        onStyleChanged?(currentStyle)     // 套到選取的圖形＋記住供下次畫（見 SelectionView）
    }
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
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        updateHint(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        updateHint(with: event)
    }
    /// 離開工具列就清空——否則說明會留在最後一顆鈕上，看起來像目前狀態。
    override func mouseExited(with event: NSEvent) {
        hintLabel.stringValue = Self.defaultHint
    }

    /// 找滑鼠底下註冊過說明的控件。
    /// 不用 `hitTest(_:)`：它收的是 **superview** 座標系的點，在這裡很容易傳錯座標而靜默失效；
    /// 直接對每個控件換算明確得多，而且控件只有二十來個，每次移動的成本可忽略。
    private func updateHint(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (view, text) in hints {
            guard !view.isHiddenOrHasHiddenAncestor else { continue }   // 樣式列收起時色塊不算數
            if view.bounds.contains(view.convert(point, from: self)) {
                hintLabel.stringValue = text
                return
            }
        }
        hintLabel.stringValue = Self.defaultHint
    }

    @objc private func confirmAction() { onConfirm?() }
    @objc private func cancelAction() { onCancel?() }
    @objc private func pinAction() { onPin?() }
    @objc private func saveAction() { onSave?() }
    @objc private func saveAsAction() { onSaveAs?() }
    @objc private func openAction() { onOpen?() }
    @objc private func recognizeTextAction() { onRecognizeText?() }
}

