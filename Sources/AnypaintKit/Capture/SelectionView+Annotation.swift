import AppKit

// MARK: - 標註操作與文字編輯

extension SelectionView {
    // MARK: 標註操作

    func makeShape(tool: AnnotationTool, from a: CGPoint, to b: CGPoint) -> Annotation.Shape {
        // 純邏輯抽到 AnnotationInput.twoPointShape（可測）；snapshot.scale 是唯一的 view 相依。
        guard let shape = AnnotationInput.twoPointShape(tool: tool, from: a, to: b,
                                                        pixelScale: snapshot.scale) else {
            preconditionFailure("此工具不走兩點成形")
        }
        return shape
    }

    /// 序號：點擊即生成下一號（編號渲染時算）；框外不入庫；進熱狀態（滾輪調大小）。
    func addCounter(at p: CGPoint) {
        let a = Annotation(shape: .counter(center: p), style: currentStyle)
        guard AnnotationInput.shapeInSelection(bounds: a.bounds, selection: selection) else { return }
        annotations.add(a)
        syncUndoButtons()
        hotAnnotationID = a.id
        needsDisplay = true
    }

    /// 多邊形成形收尾：≥3 點且框內才入庫；清空 draft。
    func finishPolygonDraft() {
        defer { polygonDraft = []; needsDisplay = true }
        guard PolygonBuilder.canFinish(points: polygonDraft) else { return }
        let a = Annotation(shape: .polygon(points: polygonDraft, closed: true), style: currentStyle)
        guard AnnotationInput.shapeInSelection(bounds: a.bounds, selection: selection) else { return }
        annotations.add(a)
        syncUndoButtons()
        hotAnnotationID = a.id
    }

    /// 雙擊選中多邊形的邊 → 在該邊插入新節點（一步 undo）。非多邊形或離邊太遠＝不動作。
    func insertPolygonNodeIfHit(at p: CGPoint) {
        guard let selID = annotations.selectedID,
              let selected = annotations.objects.first(where: { $0.id == selID }),
              let poly = editablePolygon(of: selected),
              let edge = poly.nearestEdge(to: p),
              edge.distance <= handleSize + 4 else { return }
        let inserted = poly.insertingNode(at: edge.index, point: p)
        annotations.update(id: selID) { a in
            a.shape = .polygon(points: inserted.points, closed: inserted.closed)
        }
        selectedPolygonNode = edge.index + 1   // 新節點選中，可立即拖或 Delete
        syncUndoButtons()
        needsDisplay = true
    }

    /// 刪除多邊形目前選中的節點（保底 ≥3 點，一步 undo）。回傳是否有刪（供 Delete 路由決定是否改刪整個物件）。
    @discardableResult
    func deleteSelectedPolygonNodeIfAny() -> Bool {
        guard let idx = selectedPolygonNode,
              let selID = annotations.selectedID,
              let selected = annotations.objects.first(where: { $0.id == selID }),
              let poly = editablePolygon(of: selected) else { return false }
        let removed = poly.removingNode(idx)
        guard removed.points.count != poly.points.count else { return false }   // 3 點時擋下＝不算刪
        annotations.update(id: selID) { a in
            a.shape = .polygon(points: removed.points, closed: removed.closed)
        }
        selectedPolygonNode = nil
        syncUndoButtons()
        needsDisplay = true
        return true
    }

    // MARK: 影像轉換（非矩形裁切／透視校正）——就地換底圖,可 undo

    /// 選中的封閉多邊形（≥3 點）＝裁切/透視的輸入；沒有就 nil。
    func selectedClosedPolygon() -> (id: UUID, poly: EditablePolygon)? {
        guard let id = annotations.selectedID,
              let a = annotations.objects.first(where: { $0.id == id }),
              let poly = editablePolygon(of: a), poly.closed, poly.points.count >= 3 else { return nil }
        return (id, poly)
    }

    var canCropToPolygon: Bool { selectedClosedPolygon() != nil }
    var canPerspectiveCorrect: Bool { selectedClosedPolygon()?.poly.points.count == 4 }

    private func toImagePixels(_ pts: [CGPoint]) -> [CGPoint] {
        pts.map { ImageTransform.imagePixel(viewPoint: $0, viewHeight: bounds.height, scale: snapshot.scale) }
    }

    /// 非矩形裁切：選中多邊形遮罩底圖 → 去背新圖 → 換底圖。
    func cropToSelectedPolygon() {
        guard let s = selectedClosedPolygon() else { return }
        guard let cropped = ImageTransform.maskedCrop(source: snapshot.cgImage,
                                                      imagePolygon: toImagePixels(s.poly.points)) else {
            NSSound.beep(); return
        }
        replaceSurface(with: cropped)
    }

    /// 透視校正：選中的 4 角 quad → 拉直 → 換底圖。
    func perspectiveCorrectSelected() {
        guard let s = selectedClosedPolygon(), s.poly.points.count == 4 else { return }
        let ordered = ImageTransform.orderedCorners(toImagePixels(s.poly.points))
        guard let corrected = ImageTransform.perspectiveCorrect(source: snapshot.cgImage,
                                                                imageCorners: ordered) else {
            NSSound.beep(); return
        }
        replaceSurface(with: corrected)
    }

    /// 就地換底圖：把 corrected（snapshot.scale 像素）嵌進整螢幕暗底畫布中央,
    /// selection＝該影像區,清標註,存一層 surface undo。
    func replaceSurface(with corrected: CGImage) {
        let scale = snapshot.scale
        let fullW = snapshot.cgImage.width, fullH = snapshot.cgImage.height
        guard let ctx = CGContext(
            data: nil, width: fullW, height: fullH, bitsPerComponent: 8, bytesPerRow: 0,
            space: snapshot.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        let cw = min(corrected.width, fullW), ch = min(corrected.height, fullH)
        let ox = (fullW - cw) / 2, oy = (fullH - ch) / 2   // ctx 左下原點
        ctx.interpolationQuality = .high
        ctx.draw(corrected, in: CGRect(x: ox, y: oy, width: cw, height: ch))
        guard let newFull = ctx.makeImage() else { return }

        surfaceUndoStack.append(SurfaceState(snapshot: snapshot, backgroundImage: backgroundImage,
                                             objects: annotations.snapshotObjects(), selection: selection))
        snapshot = DisplaySnapshot(displayID: snapshot.displayID, cgImage: newFull, screen: snapshot.screen,
                                   frameGlobal: snapshot.frameGlobal, scale: scale, windows: [])
        backgroundImage = NSImage(cgImage: newFull, size: snapshot.pointSize)
        annotations.restore(objects: [])
        selection = CGRect(x: CGFloat(ox) / scale, y: CGFloat(oy) / scale,
                           width: CGFloat(cw) / scale, height: CGFloat(ch) / scale)
        selectedPolygonNode = nil
        selectDrag = nil
        activeTool = nil
        toolbar.setActiveTool(nil)
        toolbar.setStyleRowVisible(false)
        clearHotAnnotation()
        if let sel = selection { layoutToolbar(for: sel) }
        toolbar.isHidden = false
        syncUndoButtons()
        needsDisplay = true
    }

    /// 回退一層 surface（⌘Z 在標註 undo 用盡後）。回傳是否有回退。
    @discardableResult
    func revertSurface() -> Bool {
        guard let s = surfaceUndoStack.popLast() else { return false }
        snapshot = s.snapshot
        backgroundImage = s.backgroundImage
        annotations.restore(objects: s.objects)
        selection = s.selection
        selectedPolygonNode = nil
        if let sel = selection { layoutToolbar(for: sel) }
        syncUndoButtons()
        needsDisplay = true
        return true
    }

    /// 命中既有文字物件（由上到下找第一個）；點擊路由與 hover 提示共用（驗收回饋 Fix 2；
    /// threshold 統一 4，與 hover 虛線框 inset 一致——清理項）。
    func hitTextObject(at p: CGPoint) -> Annotation? {
        annotations.hitTextObject(at: p, threshold: 4)
    }

    /// select 工具 mouseDown 路由：命中已選取物件的四角 handle → 進入縮放；
    /// 命中物件本體（含新命中）→ 選取＋進入移動候選；未命中 → 解除選取。
    func handleSelectDown(at p: CGPoint) {
        // 已選取多邊形：角點節點優先於整體縮放——命中節點就各自拖那一點。
        if let selID = annotations.selectedID,
           let selected = annotations.objects.first(where: { $0.id == selID }),
           let nodeIndex = hitPolygonNode(p, for: selected) {
            selectedPolygonNode = nodeIndex
            selectDrag = .draggingNode(id: selID, index: nodeIndex, startShape: selected.shape)
            hotAnnotationID = selID
            return
        }
        if let selID = annotations.selectedID,
           let selected = annotations.objects.first(where: { $0.id == selID }),
           editablePolygon(of: selected) == nil,   // 多邊形不走 bbox 縮放（改用節點）
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
        selectedPolygonNode = nil   // 點到物件本體（非節點）＝清掉節點選取
        hotAnnotationID = hit.id   // 重設熱狀態（同上）
        toolbar.setStyle(hit.style)
        toolbar.setStyleRowVisible(true)   // 選取了物件＝樣式列出現（spec）
        if let sel = selection { layoutToolbar(for: sel) }   // 高度變化要重新定位工具列
        selectDrag = .moving(id: hit.id, startMouse: p, startShape: hit.shape)
        refreshTransformActions()   // 選到多邊形→顯示裁切/拉直
        needsDisplay = true
    }

    /// 文字：在點擊處開新編輯器。命中既有文字的情況已在 mouseDown 分流成拖曳候選
    /// （驗收回饋 Fix 3：mouseDown 命中既有文字時不會呼叫這裡），這裡只處理「沒命中」。
    func handleTextClick(at p: CGPoint) {
        // 框外不開新編輯器：文字輸入成本高，不能等 commit 才靜默丟棄。
        guard let sel = selection, sel.contains(p) else { return }
        openTextEditor(origin: p, initialString: "", existing: nil)
    }

    func openTextEditor(origin: CGPoint, initialString: String, existing: Annotation?) {
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
        switch AnnotationInput.textCommitAction(trimmed: string, hasExistingID: editingTextID != nil) {
        case .remove:
            if let id = editingTextID { annotations.remove(id: id) }
        case .update:
            if let id = editingTextID {
                annotations.update(id: id) { a in
                    if case .text(let o, _) = a.shape { a.shape = .text(origin: o, string: string) }
                }
            }
        case .add:
            let a = Annotation(shape: .text(origin: origin, string: string), style: currentStyle)
            if AnnotationInput.shapeInSelection(bounds: a.bounds, selection: selection) {   // 框外不入庫
                annotations.add(a)
                hotAnnotationID = a.id
            }
        case .none:
            break
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingTextID = nil
        window?.makeFirstResponder(self)   // 還 first responder：Esc/Enter/⌘Z 恢復由本 view 處理
        syncUndoButtons()
        needsDisplay = true
    }

    func undoAnnotation() {
        commitTextEditing()   // 編輯中按 undo/redo：先落字，避免 update(id:) 對已消失物件靜默 no-op 丟字
        // 拖曳中 undo/redo：先終止 in-flight 拖曳，否則後續 drag 事件會在無快照覆蓋下裸改物件
        // （總審查 Important：undo 彈掉 beginChange 快照後，mouseDragged 仍會用 updateWithoutSnapshot 續改）。
        selectDrag = nil
        selectDragBegan = false
        textDragCandidate = nil
        textDragBegan = false
        // 標註 undo 用盡後,⌘Z 再按＝回退一層影像轉換（換底圖）。
        guard annotations.canUndo else {
            if revertSurface() { clearHotAnnotation() }
            return
        }
        annotations.undo()
        clearHotAnnotation()   // spec：undo/redo 清除熱狀態
        syncUndoButtons()
        needsDisplay = true
        // invalidateCursorRects 已證實對此 view 是 no-op（無 mouseMoved 觸發游標重算），
        // 改在此手動依上次已知的游標位置重算，讓解鎖後控制點/游標立即復原。
        if let hp = hoverPoint { cursor(at: hp).set() }
    }

    func redoAnnotation() {
        commitTextEditing()   // 編輯中按 undo/redo：先落字，避免 update(id:) 對已消失物件靜默 no-op 丟字
        // 拖曳中 undo/redo：先終止 in-flight 拖曳，理由同 undoAnnotation()。
        selectDrag = nil
        selectDragBegan = false
        textDragCandidate = nil
        textDragBegan = false
        guard annotations.canRedo else { return }
        annotations.redo()
        clearHotAnnotation()
        syncUndoButtons()
        needsDisplay = true
        if let hp = hoverPoint { cursor(at: hp).set() }
    }

    func syncUndoButtons() {
        // canUndo 也涵蓋「回退影像轉換」——標註空但有 surface 可退時,undo 仍可按。
        toolbar.setUndoState(canUndo: annotations.canUndo || !surfaceUndoStack.isEmpty,
                             canRedo: annotations.canRedo)
        refreshTransformActions()
    }

    /// 依目前選取狀態刷新「裁切／拉直」動作鈕顯隱。顯隱改變工具列寬度 → 重新 layout
    /// （否則新現身的鈕在固定寬工具列裡被壓成 0 寬，見實機教訓）。
    func refreshTransformActions() {
        toolbar.setTransformActions(canCrop: canCropToPolygon, canPerspective: canPerspectiveCorrect)
        if let sel = selection { layoutToolbar(for: sel) }
    }

    /// 序號編號查表（渲染時算、不存死——刪除/undo 天然正確）。
    func counterNumbersMap() -> [UUID: Int] { annotations.counterNumbersMap() }

    /// 馬賽克取樣：view 點座標矩形 → 原始凍結影像該區像素圖（非破壞鐵則：永遠取原始底圖）。
    /// 先與可視範圍（view bounds）取交集：矩形超出底圖（多螢幕拖過邊界）時只取交集，
    /// 並把交集矩形一併回傳給 renderer，避免縮小的 crop 被拉伸鋪滿整個原始 rect（總審查 Minor）。
    /// 交集為空＝完全在畫面外＝回 nil，renderer 走灰佔位路徑。
    func frozenImageProvider() -> (CGRect) -> (image: CGImage, drawRect: CGRect)? {
        { [snapshot, boundsSize = bounds.size] rect in
            let clamped = rect.intersection(CGRect(origin: .zero, size: boundsSize))
            guard !clamped.isEmpty else { return nil }
            let pixelRect = CoordinateUtils.pixelCropRect(
                selection: clamped, displayPointSize: boundsSize, scale: snapshot.scale)
            guard let cropped = snapshot.cgImage.cropping(to: pixelRect) else { return nil }
            return (image: cropped, drawRect: clamped)
        }
    }

}
