import AppKit

// MARK: - 框選視圖

/// 框選視圖：顯示凍結影像、可拖出/調整選取框，按工具列「複製」才裁切完成。
/// 座標一律用「點、左下原點」，裁切時交給 CoordinateUtils 翻轉成像素。
final class SelectionView: NSView {
    let snapshot: DisplaySnapshot
    let backgroundImage: NSImage

    var selection: CGRect?
    let handleSize: CGFloat = 8
    let minSize: CGFloat = 5

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    enum DragKind {
        case creating(anchor: CGPoint)
        case moving(startMouse: CGPoint, startRect: CGRect)
        case resizing(handle: Handle, startRect: CGRect)
    }
    var drag: DragKind?
    var dragPoint: CGPoint?   // 拖曳中的游標位置（放大鏡用）
    var hoverPoint: CGPoint?  // 尚未框選時的 hover 位置（放大鏡用）
    /// **上次真的畫出去**的十字線位置（已對齊像素格）。
    ///
    /// invalidate 不能只靠「hoverPoint 的前一個值」：hover 與 prime 兩條路徑用不同的
    /// invalidate 方式（局部 vs 全重繪），加上 AppKit 會合併重繪、macOS 會合併 mouseMoved
    /// 事件——這些都會讓「前一個 hoverPoint」跟畫面上實際存在的那條線脫鉤，漏標就留殘影。
    /// 記錄實際畫出的位置，清除就與事件配對完全無關。
    var lastDrawnCrosshair: CGPoint?
    let loupeSide: CGFloat = 110
    let loupeSrcPixels: CGFloat = 22

    /// 看門狗倒數警告秒數（nil = 不顯示）。由 overlay controller 寫入。
    var watchdogWarningSeconds: Int? {
        didSet { if watchdogWarningSeconds != oldValue { needsDisplay = true } }
    }

    // MARK: 標註狀態（階段 2）
    /// 作用中的標註工具（nil＝調框模式）。
    var activeTool: AnnotationTool?
    /// 標註文件（undo/z-order 都在裡面）。
    let annotations = AnnotationDocument()
    /// 拖曳中的暫定形狀——不進 document，mouseUp 位移 ≥3pt 才 add()（總審查裁定的慣例）。
    var provisionalShape: Annotation.Shape?
    var shapeAnchor: CGPoint?
    /// 畫筆/螢光筆的累積點（拖曳中）；mouseUp 成形。
    var strokePoints: [CGPoint] = []
    var currentStyle = AnnotationStyleStore.style(for: .rect)
    /// 滾輪調粗細的累積量（觸控板會送大量小 delta，湊滿閾值才跳一檔）。
    var lineWidthScrollAccum: CGFloat = 0
    /// 有任何標註就鎖框（spec）：控制點隱藏、框不可建/移/縮；undo 清空自動解鎖。
    var frameLocked: Bool { !annotations.isEmpty }

    // MARK: 熱圖形（spec 2026-07-22 修訂）
    /// mouseUp 成功 add() 的物件在解除前是「熱」的：滾輪直接調它的粗細（畫面即時反映）。
    /// mouseDown（任何分支）、undo/redo、切工具／取消工具作用都清除。
    var hotAnnotationID: UUID?
    /// 目前這段熱圖形滾輪調整是否已經 beginChange() 過一次
    /// （首次實際改動才拍快照，整段調整合併一步 undo；不可每格滾動都 push 快照）。
    var hotScrollBegan = false

    func clearHotAnnotation() {
        hotAnnotationID = nil
        hotScrollBegan = false
    }

    // MARK: select 工具（階段 5）
    /// select 工具下正在移動/縮放的物件（mouseDown 命中時記錄起始幾何，mouseUp 清除）。
    enum SelectDrag {
        case moving(id: UUID, startMouse: CGPoint, startShape: Annotation.Shape)
        case resizing(id: UUID, handle: AnnotationHandle, startBounds: CGRect, startShape: Annotation.Shape)
    }
    var selectDrag: SelectDrag?
    /// 首次實際位移才 beginChange()（比照 textDragBegan：整段移動/縮放合併一步 undo）。
    var selectDragBegan = false

    /// 有選取物件（Task 4 keyMonitor 的 Esc 分層依賴）。
    var hasSelection: Bool { annotations.selectedID != nil }

    /// 解除選取＋清熱狀態＋清 select 拖曳狀態（Esc／點空白處／Delete 後共用）。
    func deselect() {
        annotations.selectedID = nil
        clearHotAnnotation()
        selectDrag = nil
        selectDragBegan = false
        if activeTool == .select {
            // select 工具下無選取＝隱藏樣式列（spec：選了繪製工具或選取了物件才出現）；
            // 高度變化要重新定位工具列（比照 onToolSelected 既有做法）。
            toolbar.setStyleRowVisible(false)
            if let sel = selection { layoutToolbar(for: sel) }
        }
        needsDisplay = true
    }

    // MARK: 文字編輯（階段 3；唯一的子 view 特例）
    var textEditor: InlineTextView?
    /// 重編輯中的既有文字物件（渲染時跳過避免重影；commit 時 update/remove）。
    var editingTextID: UUID?
    /// 文字工具 hover 中的既有文字物件（驗收回饋 Fix 2：畫虛線框＋openHand 游標）。
    var hoveredTextID: UUID?
    /// 文字拖移候選：mouseDown 命中既有文字時記錄；≥3pt 才轉為移動，否則 mouseUp＝重編輯
    /// （驗收回饋 Fix 3）。
    var textDragCandidate: (id: UUID, startMouse: CGPoint, startOrigin: CGPoint)?
    var textDragBegan = false   // 首次實際位移才 beginChange（熱圖形滾輪調整同慣例）

    var isEditingText: Bool { textEditor != nil }
    /// 輸入法組字中（注音等 marked text）——此時 Esc 要讓給 IME 清組字，不能當 commit。
    var isComposingText: Bool { textEditor?.hasMarkedText() ?? false }

    // MARK: 取色（spec 2026-07-22 取色器）
    /// 「已複製 #XXXXXX」提示文字（1.5 秒自動清除；顯示中暫代放大鏡色值列內容）。
    var copiedColorText: String?
    private var copiedToastClear: DispatchWorkItem?

    /// 複製色值後顯示短暫提示；新複製會取代舊倒數。
    func showCopiedToast(_ text: String) {
        copiedColorText = text
        copiedToastClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedColorText = nil
            if let p = self.dragPoint ?? self.hoverPoint { self.invalidateLoupe(around: p, and: nil) }
        }
        copiedToastClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: clear)
        if let p = dragPoint ?? hoverPoint { invalidateLoupe(around: p, and: nil) }
    }

    // MARK: 視窗偵測（spec 2026-07-22）
    /// hover 候選框（view 座標；游標下的視窗，無則整螢幕）。
    /// 只在「未框選＋無作用中工具」時有值；單擊（<3pt）＝套用為 selection。
    var windowCandidate: CGRect?

    let toolbar = SelectionToolbar()

    /// 按下「複製」→ 回傳裁切影像。
    var onConfirm: ((NSImage) -> Void)?
    /// 按下「貼」→ 回傳裁切影像＋view 座標的選取框（controller 負責轉全域）。
    var onPin: ((NSImage, CGRect) -> Void)?
    /// 按下「存」→ 回傳裁切影像（AppDelegate 負責寫檔＋剪貼簿）。
    var onSave: ((NSImage) -> Void)?
    /// 按下「另存為」→ 回傳裁切影像（AppDelegate 負責彈對話框＋寫檔）。
    var onSaveAs: ((NSImage) -> Void)?
    /// 按下「存檔並開啟」→ 回傳裁切影像（AppDelegate 負責寫檔＋交給外部 App）。
    var onOpen: ((NSImage) -> Void)?
    /// 按下「複製文字」→ 回傳裁切影像＋view 座標選取框（controller 轉全域，供結果窗定位）。
    var onRecognizeText: ((NSImage, CGRect) -> Void)?
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
        toolbar.onPin = { [weak self] in self?.pinConfirm() }
        toolbar.onSave = { [weak self] in self?.saveConfirm() }
        toolbar.onSaveAs = { [weak self] in self?.saveAsConfirm() }
        toolbar.onOpen = { [weak self] in self?.openConfirm() }
        toolbar.onRecognizeText = { [weak self] in self?.recognizeTextConfirm() }
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
            if tool == .select {
                // setActiveTool 剛把樣式列顯示（tool != nil）；select 工具要依有無選取覆寫
                // （切入 select 當下通常無選取，spec：選了物件才出現）。
                self.toolbar.setStyleRowVisible(self.hasSelection)
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

    // MARK: 調整框幾何

    func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    func clampToBounds(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
        r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
        return r
    }

    func resize(_ start: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
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

    func layoutToolbar(for sel: CGRect) {
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
    /// 供「複製」與看門狗逾時搶救共用——搶救因此自動含標註。
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

    func confirm() {
        commitTextEditing()
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持原行為：取消
            return
        }
        onConfirm?(image)
    }

    /// 「貼」的完成路徑：與 confirm() 同紀律（先落字、同 guard、同失敗行為），
    /// 差別只在把結果連同 view 座標 selection 交給 onPin。
    func pinConfirm() {
        commitTextEditing()
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持與 confirm() 一致：取消
            return
        }
        onPin?(image, sel)
    }

    /// 「存」的完成路徑：與 confirm() 同紀律（先落字、同 guard、同失敗行為）。
    func saveConfirm() {
        commitTextEditing()
        guard hasValidSelection else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持與 confirm() 一致：取消
            return
        }
        onSave?(image)
    }

    /// 「另存為」的完成路徑：與 saveConfirm() 同紀律，差別只在交給 onSaveAs。
    func saveAsConfirm() {
        commitTextEditing()
        guard hasValidSelection else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持與 confirm() 一致：取消
            return
        }
        onSaveAs?(image)
    }

    /// 「存檔並開啟」的完成路徑：與 saveConfirm() 同紀律，差別只在交給 onOpen。
    func openConfirm() {
        commitTextEditing()
        guard hasValidSelection else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持與 confirm() 一致：取消
            return
        }
        onOpen?(image)
    }

    /// 「複製文字」的完成路徑：與 pinConfirm() 同紀律，差別只在交給 onRecognizeText。
    ///
    /// 用 `currentCroppedImage()`（**含標註**）而不是原圖，與其他所有出口一致：
    /// 使用者若先畫了馬賽克，被遮住的內容本來就不該被辨識出來。
    func recognizeTextConfirm() {
        commitTextEditing()
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return }
        guard let image = currentCroppedImage() else {
            onCancel?()   // 有框但裁切失敗 → 維持與 confirm() 一致：取消
            return
        }
        onRecognizeText?(image, sel)
    }

    /// 有效框（controller 監聽器的 ⌘S／⌘O／⌘T 路由依賴）。
    var hasValidSelection: Bool {
        guard let sel = selection else { return false }
        return sel.width > minSize && sel.height > minSize
    }
}
