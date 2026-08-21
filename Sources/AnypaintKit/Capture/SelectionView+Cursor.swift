import AppKit

// MARK: - 游標與 hover 追蹤

extension SelectionView {
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

    /// CursorKind（純決策）→ 實際 NSCursor（含系統原生 resize 游標資源）。
    private func nsCursor(for kind: SelectionGeometry.CursorKind) -> NSCursor {
        switch kind {
        case .arrow:     return .arrow
        case .openHand:  return .openHand
        case .crosshair: return .crosshair
        case .resize(.nwse): return Self.cursorNWSE
        case .resize(.nesw): return Self.cursorNESW
        case .resize(.ew):   return Self.cursorEW
        case .resize(.ns):   return Self.cursorNS
        }
    }

    func cursor(at point: CGPoint) -> NSCursor {
        // 鎖框時無控制點、不可移動 → edgeAxis/insideSelection 皆視為無。
        var edgeAxis: SelectionGeometry.ResizeAxis?
        var inside = false
        if let sel = selection, !frameLocked {
            edgeAxis = hitHandle(point, in: sel).map { SelectionGeometry.resizeAxis(for: $0) }
            inside = sel.contains(point)
        }
        let kind = SelectionGeometry.cursorKind(
            toolbarHit: !toolbar.isHidden && toolbar.frame.contains(point),
            isTextTool: activeTool == .text, textHover: hitTextObject(at: point) != nil,
            isSelectTool: activeTool == .select, selectCursor: selectCursorKind(at: point),
            isDrawingTool: activeTool != nil, edgeAxis: edgeAxis, insideSelection: inside)
        return nsCursor(for: kind)
    }

    /// select 工具游標（純決策部分）：選取物件四角 handle＝對角 resize；命中物件＝開手；其餘＝箭頭。
    private func selectCursorKind(at point: CGPoint) -> SelectionGeometry.CursorKind {
        let cornerAxis = annotations.selectedID
            .flatMap { id in annotations.objects.first(where: { $0.id == id }) }
            .flatMap { hitAnnotationHandle(point, for: $0) }
            .map { SelectionGeometry.resizeAxis(for: $0) }
        return SelectionGeometry.selectToolCursor(cornerAxis: cornerAxis,
                                                  hitAnyObject: annotations.hitTest(at: point) != nil)
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
        // 進入 overlay 本身就是互動：重置看門狗，也讓 controller 立刻清掉**其他螢幕**的
        // hover 狀態（否則要等到本螢幕第一次 mouseMoved，那期間兩個螢幕會同時亮候選）。
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        hoverPoint = p
        updateWindowCandidate(at: p)
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
        // 懸停標註 → 記錄以顯示鎖/解鎖鈕（含鎖定的,才能解鎖）。不限工具（即選即編下畫圖工具也要能鎖）。
        // 用 annotationHover（圖形 ∪ 鎖鈕範圍）→ 移向鎖鈕途中不脫離,鎖鈕構得到。變化才重繪。
        let newAnnHover = annotationHover(at: p)
        if newAnnHover != hoveredAnnotationID {
            hoveredAnnotationID = newAnnHover
            needsDisplay = true
        }
        updateWindowCandidate(at: p)
        let prev = hoverPoint
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: p) }
    }
    override func mouseExited(with event: NSEvent) {
        if hoveredTextID != nil {
            hoveredTextID = nil
            needsDisplay = true
        }
        if hoveredAnnotationID != nil {
            hoveredAnnotationID = nil
            needsDisplay = true
        }
        if windowCandidate != nil {
            windowCandidate = nil
            needsDisplay = true
        }
        let prev = hoverPoint
        hoverPoint = nil
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: nil) }
    }

    /// 清掉本 view 的 hover 類狀態：視窗候選、十字線、放大鏡。
    ///
    /// 多螢幕用：滑鼠只有一個，這些東西**全域只該有一份**。由 controller 在每次互動時
    /// 統一保證，不依賴 mouseExited 的事件配對。
    ///
    /// 註（2026-07-28）：這個機制原本是為了修「雙螢幕各自 focus 一個視窗」而加的，
    /// 但方向錯了、加了也沒解決——**真正的現象是「兩個螢幕各自產生一個選區」**
    /// （先在左螢幕點選一個視窗，再到右螢幕點選另一個），那是選區不唯一的問題，
    /// 已由 `SelectionOverlayController.grantExclusiveSelection` 處理。
    /// 這裡保留是因為 hover 狀態全域唯一本身仍然成立（滑鼠只有一個）。
    func clearHoverState() {
        guard windowCandidate != nil || hoverPoint != nil else { return }
        windowCandidate = nil
        hoverPoint = nil
        // 候選框是大面積，直接全重繪——涵蓋十字線與放大鏡的清除，不必再算局部 dirty。
        // hoverPoint 歸 nil 後 activeLoupePoint 回 nil，draw 會順手清掉 lastDrawnCrosshair。
        needsDisplay = true
    }

    /// 放棄本 view 的選區（另一個螢幕取得獨佔權時由 controller 呼叫）。
    ///
    /// 呼叫端已用 `frameLocked` 擋掉「有標註」的情況，所以這裡不會丟掉標註——
    /// 也因此不需要清 annotations（此時它必為空）。
    func relinquishSelection() {
        guard selection != nil else { return }
        selection = nil
        windowCandidate = nil
        toolbar.isHidden = true   // 選區沒了工具列不該留在畫面上
        needsDisplay = true
    }

    /// 視窗偵測候選計算（mouseMoved／mouseEntered／primeHoverState 共用）。
    func updateWindowCandidate(at p: CGPoint) {
        if activeTool == nil, selection == nil {
            let origin = snapshot.frameGlobal.origin
            let globalP = CGPoint(x: p.x + origin.x, y: p.y + origin.y)
            // 候選框的座標轉換＋跨螢幕 clamp 抽到 SelectionGeometry.windowCandidate（可測）。
            let hit = WindowDetector.hitTest(point: globalP, windows: snapshot.windows)
            let newCandidate = SelectionGeometry.windowCandidate(hit: hit, frameOrigin: origin, viewBounds: bounds)
            if newCandidate != windowCandidate {
                windowCandidate = newCandidate
                needsDisplay = true
            }
        } else if windowCandidate != nil {
            windowCandidate = nil
            needsDisplay = true
        }
    }

    /// overlay 剛顯示、游標已在本螢幕內：先算一次 hover 狀態（放大鏡＋視窗候選）——
    /// 修「喚出後不動滑鼠直接單擊無效」的第一擊死區（總審查 Important）。
    func primeHoverState() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return }
        hoverPoint = p
        updateWindowCandidate(at: p)
        needsDisplay = true
    }
}
