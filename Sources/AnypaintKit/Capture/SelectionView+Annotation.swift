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
        autoSelectAfterDraw(id: a.id)   // 畫完自動選取→立刻可拖節點
    }

    /// 畫完圖形後自動選取它——**工具保持不變**（可連續畫），但把剛畫的設為選取,
    /// 控制點/節點直接可拖（點控制點＝編輯、點空白＝畫下一個）。保留 hotAnnotationID（滾輪調粗細）。
    func autoSelectAfterDraw(id: UUID) {
        annotations.selectedID = id
        selectedPolygonNode = nil
        refreshTransformActions()
        if let sel = selection { layoutToolbar(for: sel) }
        needsDisplay = true
    }

    /// 嘗試抓取「目前選取圖形」的節點/控制點開始編輯（任何工具下都可,畫完直接微調用）。
    /// 抓到＝設好 selectDrag 並回 true；沒抓到回 false（呼叫端續走畫新圖形）。鎖定則不給抓。
    func tryGrabSelectedHandle(at p: CGPoint) -> Bool {
        guard let selID = annotations.selectedID, !isLocked(selID),
              let selected = annotations.objects.first(where: { $0.id == selID }) else { return false }
        if let nodeIndex = hitPolygonNode(p, for: selected) {
            selectedPolygonNode = nodeIndex
            selectDrag = .draggingNode(id: selID, index: nodeIndex, startShape: selected.shape)
            hotAnnotationID = selID
            return true
        }
        // callout 尾巴頂點優先於縮放 handle（頂點常落在縮放框邊附近，先讓拖尾巴贏）。
        if hitCalloutTail(p, for: selected) {
            selectDrag = .draggingCalloutTail(id: selID, startShape: selected.shape)
            hotAnnotationID = selID
            return true
        }
        if editablePolygon(of: selected) == nil, let handle = hitAnnotationHandle(p, for: selected) {
            selectDrag = .resizing(id: selID, handle: handle, startBounds: selected.bounds, startShape: selected.shape)
            hotAnnotationID = selID
            return true
        }
        return false
    }

    /// 畫圖工具下：先讓「編輯/改選既有圖形」優先（統一模型：點控制點＝編輯、點到圖形＝改選）。
    /// 回 true＝已處理（不要畫新的）；回 false＝點在空白,清掉選取,呼叫端去畫新圖形。
    func selectOrEditExistingBeforeDraw(at p: CGPoint) -> Bool {
        if tryGrabSelectedHandle(at: p) { needsDisplay = true; return true }
        // 只有「未鎖定」的圖形會攔截來改選/編輯；鎖定的穿透 → 可在其上繼續畫（要解鎖用選取工具）。
        if annotations.hitTestAll(at: p).contains(where: { !isLocked($0.id) }) {
            selectAnnotation(at: p, allowMoveStart: true, includeLocked: false)
            return true
        }
        // 空白或只有鎖定圖形 → 要畫新的：先清掉目前選取（控制點消失）。
        if annotations.selectedID != nil { annotations.selectedID = nil; selectedPolygonNode = nil; refreshTransformActions() }
        return false
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

    // MARK: 鎖定（滑鼠移到圖形上出現鎖/解鎖鈕；鎖上不可動,預設解鎖）

    /// 目前該顯示鎖/解鎖鈕的標註（懸停的＋選中的，去重）。
    /// 該顯示鎖/解鎖鈕的標註：**所有鎖定的**（常駐 🔒＝狀態一目了然、點它解鎖）＋**選取中**那個
    /// （未鎖＝🔓 可上鎖）。不用 hover（重疊會跳、小鈕構不到,實機教訓）；鎖定用常駐徽章＝決定性。
    func lockIconTargets() -> [UUID] {
        var ids = annotations.objects.compactMap { isLocked($0.id) ? $0.id : nil }
        if let s = annotations.selectedID, !ids.contains(s) { ids.append(s) }
        return ids
    }

    /// 鎖/解鎖鈕的位置（標註外框右上角外側；夾進畫面）。繪製與命中共用。
    func annotationLockIconRect(for annotation: Annotation) -> CGRect {
        let b = annotation.bounds
        let size: CGFloat = 24
        var r = CGRect(x: b.maxX - size / 2, y: b.maxY + 4, width: size, height: size)
        r.origin.x = min(max(2, r.origin.x), bounds.width - size - 2)
        r.origin.y = min(max(2, r.origin.y), bounds.height - size - 2)
        return r
    }

    /// 命中鎖/解鎖鈕 → 回該標註 id（選取中那個）。
    func hitLockIcon(at p: CGPoint) -> UUID? {
        for id in lockIconTargets() {
            guard let ann = annotations.objects.first(where: { $0.id == id }) else { continue }
            if annotationLockIconRect(for: ann).contains(p) { return id }
        }
        return nil
    }

    /// 切換鎖定：**維持選取**（鎖定後鎖鈕仍在,可再解鎖；但控制點隱藏、不可拖）。
    func toggleLock(_ id: UUID) {
        if lockedAnnotations.contains(id) { lockedAnnotations.remove(id) }
        else { lockedAnnotations.insert(id) }
        annotations.selectedID = id      // 確保仍選中（鎖鈕綁在選取上）
        selectedPolygonNode = nil
        selectDrag = nil
        refreshTransformActions()
        needsDisplay = true
    }

    /// 點選圖形（決定性）：命中最上層；若目前選中的就在命中清單→再點循環到下層（重疊選取）。
    /// 鎖定的也選得到（才能解鎖）,但不進移動候選（不可拖）。
    /// includeLocked=false（畫圖工具用）：鎖定的視為穿透,不攔截,好在其上繼續畫。
    func selectAnnotation(at p: CGPoint, allowMoveStart: Bool, includeLocked: Bool = true) {
        var hits = annotations.hitTestAll(at: p)
        if !includeLocked { hits = hits.filter { !isLocked($0.id) } }
        guard let chosenID = AnnotationInput.nextSelection(hits: hits.map(\.id),
                                                           current: annotations.selectedID),
              let chosen = hits.first(where: { $0.id == chosenID }) else { deselect(); return }
        annotations.selectedID = chosen.id
        selectedPolygonNode = nil
        hotAnnotationID = chosen.id
        toolbar.setStyle(chosen.style)
        if activeTool == .select { toolbar.setStyleRowVisible(true) }
        if allowMoveStart, !isLocked(chosen.id) {
            selectDrag = .moving(id: chosen.id, startMouse: p, startShape: chosen.shape)
        }
        refreshTransformActions()
        if let sel = selection { layoutToolbar(for: sel) }
        needsDisplay = true
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

    /// 就地換底圖：把 corrected（snapshot.scale 像素）嵌進整螢幕**透明**畫布中央,
    /// selection＝該影像區,清標註,存一層 surface undo。畫布用 clear 填 → 保留 corrected 的透明
    /// （裁切去背要靠這個；螢幕擷取那份不透明,嵌進去仍不透明）。
    func replaceSurface(with corrected: CGImage) {
        let scale = snapshot.scale
        let fullW = snapshot.cgImage.width, fullH = snapshot.cgImage.height
        guard let ctx = CGContext(
            data: nil, width: fullW, height: fullH, bitsPerComponent: 8, bytesPerRow: 0,
            space: snapshot.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: fullW, height: fullH))   // 透明底,不是暗底
        let cw = min(corrected.width, fullW), ch = min(corrected.height, fullH)
        let ox = (fullW - cw) / 2, oy = (fullH - ch) / 2   // ctx 左下原點
        ctx.interpolationQuality = .high
        ctx.draw(corrected, in: CGRect(x: ox, y: oy, width: cw, height: ch))
        guard let newFull = ctx.makeImage() else { return }

        surfaceUndoStack.append(SurfaceState(snapshot: snapshot, backgroundImage: backgroundImage,
                                             objects: annotations.snapshotObjects(), selection: selection,
                                             hasAlpha: surfaceHasAlpha))
        surfaceHasAlpha = true
        snapshot = DisplaySnapshot(displayID: snapshot.displayID, cgImage: newFull, screen: snapshot.screen,
                                   frameGlobal: snapshot.frameGlobal, scale: scale, windows: [])
        backgroundImage = NSImage(cgImage: newFull, size: snapshot.pointSize)
        annotations.restore(objects: [])
        lockedAnnotations.removeAll()   // 標註已清空,鎖定狀態一併清
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
        surfaceHasAlpha = s.hasAlpha
        selectedPolygonNode = nil
        if let sel = selection { layoutToolbar(for: sel) }
        syncUndoButtons()
        needsDisplay = true
        return true
    }

    // MARK: 美化背景（#1 Backdrop）

    /// 目前框選（含標註）合成成一張像素圖——美化的來源。沒有有效框回 nil。
    private func compositedSelectionImage() -> CGImage? {
        guard let sel = selection, sel.width > minSize, sel.height > minSize else { return nil }
        let pixelRect = CoordinateUtils.pixelCropRect(
            selection: sel, displayPointSize: bounds.size, scale: snapshot.scale)
        guard let cropped = snapshot.cgImage.cropping(to: pixelRect) else { return nil }
        if annotations.isEmpty { return cropped }
        return AnnotationRenderer.composite(
            objects: annotations.objects, overCropped: cropped, selection: sel,
            scale: snapshot.scale, counterNumbers: counterNumbersMap(),
            sourceProvider: frozenImageProvider()) ?? cropped
    }

    /// 開啟美化：合成來源、開面板、套一次預設預覽。已在美化中／無有效框＝忽略。
    func beginBackdrop() {
        guard !isBackdropActive else { return }
        commitTextEditing()
        guard let source = compositedSelectionImage() else { NSSound.beep(); return }
        backdropSource = source
        backdropPreviewApplied = false
        let panel = BackdropPanel(initial: BackdropStyle())
        panel.onStyleChanged = { [weak self] style in self?.applyBackdropPreview(style) }
        panel.onCommit = { [weak self] in self?.commitBackdrop() }
        panel.onCancel = { [weak self] in self?.cancelBackdrop() }
        addSubview(panel)
        backdropPanel = panel
        applyBackdropPreview(panel.style)   // 套初始預覽
        layoutBackdropPanel()               // 位置只擺這一次（開啟後固定，見下）
    }

    /// 依 style 重套預覽：從來源重算 backdrop → 換底圖。前一層預覽先 revert,只留一層 undo。
    /// **不重新定位面板**：邊距一變選區尺寸就變→工具列移位，若面板跟著移，拖 slider 時會在
    /// 游標下抖動、根本調不動（實機回報 2026-08-21）。面板位置在 beginBackdrop 定一次就固定。
    func applyBackdropPreview(_ style: BackdropStyle) {
        guard let source = backdropSource else { return }
        if backdropPreviewApplied { revertSurface() }   // 退掉上一層預覽,避免堆疊
        guard let out = BackdropRenderer.render(source: source, style: style, scale: snapshot.scale) else {
            NSSound.beep(); return
        }
        replaceSurface(with: out)
        backdropPreviewApplied = true
    }

    /// 完成美化：留下目前結果（surface 上那層 undo 保留→可 ⌘Z 還原），收面板。
    func commitBackdrop() {
        teardownBackdrop()
    }

    /// 取消美化：退掉預覽那層（回到美化前），收面板。
    func cancelBackdrop() {
        if backdropPreviewApplied { revertSurface() }
        teardownBackdrop()
    }

    private func teardownBackdrop() {
        backdropPanel?.removeFromSuperview()
        backdropPanel = nil
        backdropSource = nil
        backdropPreviewApplied = false
        needsDisplay = true
    }

    /// 面板固定在畫面左下角（開啟時擺一次就不動）。
    /// 錨左下角而不是跟工具列：美化會改選區尺寸→工具列會移位；選區/工具列都在畫面中央，
    /// 左下角是穩定且不會被撞到的位置，拖 slider 時面板不動才調得動。
    private func layoutBackdropPanel() {
        guard let panel = backdropPanel else { return }
        let size = panel.fittingSize
        panel.frame = CGRect(x: 16, y: 16, width: size.width, height: size.height)
    }

    /// 命中既有文字物件（由上到下找第一個）；點擊路由與 hover 提示共用（驗收回饋 Fix 2；
    /// threshold 統一 4，與 hover 虛線框 inset 一致——清理項）。
    func hitTextObject(at p: CGPoint) -> Annotation? {
        annotations.hitTextObject(at: p, threshold: 4)
    }

    /// 命中既有 callout 的本體（由上而下找第一個 body 命中的）；供雙擊編輯內嵌文字。
    func hitCalloutObject(at p: CGPoint) -> Annotation? {
        for a in annotations.objects.reversed() {
            if case .callout(let body, _, _) = a.shape, body.contains(p) { return a }
        }
        return nil
    }

    /// select 工具 mouseDown 路由：命中已選取物件的四角 handle → 進入縮放；
    /// 命中物件本體（含新命中）→ 選取＋進入移動候選；未命中 → 解除選取。
    func handleSelectDown(at p: CGPoint) {
        // 目前選取圖形的節點/控制點優先（鎖定不給拖）。
        if tryGrabSelectedHandle(at: p) { return }
        // 點到圖形（含鎖定的,才能解鎖）→ 選取；重疊時再點循環到下層；鎖定的不進移動。空白→解除選取。
        selectAnnotation(at: p, allowMoveStart: true)
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

    /// 開 callout 內嵌文字編輯器：定位在 body 的文字矩形、多行換行。無有效文字矩形＝不開。
    func openCalloutEditor(for annotation: Annotation) {
        guard case .callout(let body, _, let string) = annotation.shape else { return }
        let rect = AnnotationGeometry.calloutTextRect(body: body)
        guard rect.width > 1, rect.height > 1 else { return }
        commitTextEditing()   // 一次只開一個
        let color = NSColor(cgColor: annotation.style.color.cgColor) ?? .white
        let editor = InlineTextView.makeWrapped(rect: rect, fontSize: annotation.style.textFontSize,
                                                color: color, initialString: string)
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        addSubview(editor)
        textEditor = editor
        editingCalloutID = annotation.id
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    /// 完成文字編輯：非空→入庫（新建 add／重編輯 update，各一步 undo）；
    /// 空字串→丟棄（重編輯＝刪除原物件）。callout 內嵌文字＝寫回 string（空字串保留框）。
    /// 結束後 first responder 還給自己。
    func commitTextEditing() {
        guard let editor = textEditor else { return }
        // callout 內嵌文字：寫回 string（不刪框；空字串＝清掉字但留框）。
        if let cid = editingCalloutID {
            let raw = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let obj = annotations.objects.first(where: { $0.id == cid }),
               case .callout(_, _, let old) = obj.shape, old != raw {
                annotations.update(id: cid) { a in
                    if case .callout(let b, let t, _) = a.shape { a.shape = .callout(body: b, tail: t, string: raw) }
                }
            }
            editor.removeFromSuperview()
            textEditor = nil
            editingCalloutID = nil
            window?.makeFirstResponder(self)
            syncUndoButtons()
            needsDisplay = true
            return
        }
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
