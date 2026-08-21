import AppKit

// MARK: - 框選視圖

/// 框選視圖：顯示凍結影像、可拖出/調整選取框，按工具列「複製」才裁切完成。
/// 座標一律用「點、左下原點」，裁切時交給 CoordinateUtils 翻轉成像素。
final class SelectionView: NSView {
    // 影像轉換（裁切/透視）會就地換底圖 → 可變（見 replaceSurface）。
    var snapshot: DisplaySnapshot
    var backgroundImage: NSImage

    /// 影像轉換的 surface undo：換底圖前存下整個編輯狀態,⌘Z 在標註 undo 用盡後回退到這裡。
    struct SurfaceState {
        let snapshot: DisplaySnapshot
        let backgroundImage: NSImage
        let objects: [Annotation]
        let selection: CGRect?
        let hasAlpha: Bool
    }
    var surfaceUndoStack: [SurfaceState] = []
    /// 目前底圖是否含透明（裁切去背後為 true）→ draw 在選區內先鋪棋盤格,讓透明處看得出來,
    /// 且複製/存檔會保留透明（螢幕原始快照不透明,恆 false）。
    var surfaceHasAlpha = false

    var selection: CGRect?
    let handleSize: CGFloat = 8
    let minSize: CGFloat = 5

    // 8 向控制點語意與 SelectionGeometry.ResizeEdge 相同（順序也一致）→ typealias,零轉換。
    typealias Handle = SelectionGeometry.ResizeEdge
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
    /// 多邊形成形中的暫存點（空＝未在成形）；逐點點擊、點回起點或雙擊收尾。
    var polygonDraft: [CGPoint] = []
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
        /// 多邊形單一節點拖曳（角點各自拖，非整體縮放）。
        case draggingNode(id: UUID, index: Int, startShape: Annotation.Shape)
    }
    var selectDrag: SelectDrag?
    /// 首次實際位移才 beginChange()（比照 textDragBegan：整段移動/縮放合併一步 undo）。
    var selectDragBegan = false
    /// 目前選中的多邊形節點索引（供 Delete 刪該節點；deselect 時清）。
    var selectedPolygonNode: Int?

    /// 被鎖定（不可移動/縮放/編輯）的標註 id。預設解鎖（不在集合內＝可動）。
    /// view 端狀態,不進標註 undo（鎖定是編輯輔助,不是內容）。
    var lockedAnnotations: Set<UUID> = []
    func isLocked(_ id: UUID) -> Bool { lockedAnnotations.contains(id) }

    /// 有選取物件（Task 4 keyMonitor 的 Esc 分層依賴）。
    var hasSelection: Bool { annotations.selectedID != nil }

    /// 解除選取＋清熱狀態＋清 select 拖曳狀態（Esc／點空白處／Delete 後共用）。
    func deselect() {
        annotations.selectedID = nil
        clearHotAnnotation()
        selectDrag = nil
        selectDragBegan = false
        selectedPolygonNode = nil
        refreshTransformActions()   // 解除選取→隱藏裁切/拉直
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
    /// 要開新框前向 controller 索取「選區獨佔權」，回傳是否允許。
    ///
    /// **選區全域唯一**：一次截圖只該有一個選區。原本多螢幕下可以在左螢幕選一個視窗、
    /// 移到右螢幕再選一個，兩個都亮著——使用者無從得知 Enter 會複製哪一個
    /// （controller 的完成鏈是用「最後互動的視窗」決定，行為確定但看不出來）。
    /// controller 在允許時會順手清掉其他螢幕的選區；若其他螢幕已經畫了標註則拒絕，
    /// 比照同螢幕的 frameLocked——不讓標註被無聲丟掉。
    /// 單螢幕時永遠允許（沒有其他 view）。
    var onRequestExclusiveSelection: (() -> Bool)?

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
        toolbar.onCrop = { [weak self] in self?.cropToSelectedPolygon() }
        toolbar.onPerspective = { [weak self] in self?.perspectiveCorrectSelected() }
        toolbar.onToolSelected = { [weak self] tool in
            guard let self else { return }
            self.commitTextEditing()   // 編輯中切工具＝先落字，避免編輯器與工具狀態不同步
            if !self.polygonDraft.isEmpty { self.polygonDraft = [] }   // 切工具＝放棄未收尾的多邊形
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
            // 有選取的圖形 → 直接改它的樣式（任何工具下,單發快照 undo）。統一模型：畫完仍選中,
            // 改色/粗細就該套到它,不必先切「選取」。
            if let id = self.annotations.selectedID, !self.isLocked(id) {
                self.annotations.update(id: id) { $0.style = style }
                self.syncUndoButtons()
                self.needsDisplay = true
            }
            // 畫圖工具：也記住供下次畫（不覆蓋已套到選取物件那步）。
            if let tool = self.activeTool, tool != .select {
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

    // 純幾何委派給 SelectionGeometry（可單元測試）；這裡只補上 view 的 bounds。
    func clampPoint(_ p: CGPoint) -> CGPoint { SelectionGeometry.clampPoint(p, in: bounds.size) }
    func clampToBounds(_ r: CGRect) -> CGRect { SelectionGeometry.clampRectOrigin(r, in: bounds.size) }
    func resize(_ start: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        SelectionGeometry.resized(start, edge: handle, to: p)
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
        SelectionGeometry.isValidSelectionSize(selection, minSize: minSize)
    }
}
