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
        guard let sel = selection, a.bounds.intersects(sel) else { return }
        annotations.add(a)
        syncUndoButtons()
        hotAnnotationID = a.id
        needsDisplay = true
    }

    /// 命中既有文字物件（由上到下找第一個）；點擊路由與 hover 提示共用（驗收回饋 Fix 2；
    /// threshold 統一 4，與 hover 虛線框 inset 一致——清理項）。
    func hitTextObject(at p: CGPoint) -> Annotation? {
        annotations.objects.reversed().first(where: {
            if case .text = $0.shape { return $0.hitTest(p, threshold: 4) } else { return false }
        })
    }

    /// select 工具 mouseDown 路由：命中已選取物件的四角 handle → 進入縮放；
    /// 命中物件本體（含新命中）→ 選取＋進入移動候選；未命中 → 解除選取。
    func handleSelectDown(at p: CGPoint) {
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
        toolbar.setStyleRowVisible(true)   // 選取了物件＝樣式列出現（spec）
        if let sel = selection { layoutToolbar(for: sel) }   // 高度變化要重新定位工具列
        selectDrag = .moving(id: hit.id, startMouse: p, startShape: hit.shape)
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

    func undoAnnotation() {
        commitTextEditing()   // 編輯中按 undo/redo：先落字，避免 update(id:) 對已消失物件靜默 no-op 丟字
        // 拖曳中 undo/redo：先終止 in-flight 拖曳，否則後續 drag 事件會在無快照覆蓋下裸改物件
        // （總審查 Important：undo 彈掉 beginChange 快照後，mouseDragged 仍會用 updateWithoutSnapshot 續改）。
        selectDrag = nil
        selectDragBegan = false
        textDragCandidate = nil
        textDragBegan = false
        guard annotations.canUndo else { return }
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
        toolbar.setUndoState(canUndo: annotations.canUndo, canRedo: annotations.canRedo)
    }

    /// 序號編號查表（渲染時算、不存死——刪除/undo 天然正確）。
    func counterNumbersMap() -> [UUID: Int] {
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
