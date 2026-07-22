import AppKit

// MARK: - 滑鼠／滾輪／鍵盤事件

extension SelectionView {
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
        commitTextEditing()   // 重編輯中的原物件在 draw() 被跳過但 hitTest 不跳過：
                              // 編輯器邊緣外右鍵可能命中隱形物件，選「刪除」會對已消失的編輯
                              // 內容做靜默 no-op（總審查 Important）；先落字對齊 mouseDown 慣例。
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
        // 選單收合後：非 select 工具就清選取——chrome 只在 select 工具畫，
        // 留著會變成「看不見的選取」（Esc 隱形層、⌘]/⌘[ 誤動看不見的物件）。
        if activeTool != .select {
            deselect()
            needsDisplay = true
        }
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
        // 比照 undo/redo：刪除可能解鎖框，手動依上次已知的游標位置重算（總審查 Minor）。
        if let hp = hoverPoint { cursor(at: hp).set() }
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
            // 餵 toolbar 用「更新後物件的 style」而非 currentStyle：select 模式下 currentStyle
            // 的顏色可能不是物件本身的顏色（總審查 Minor）；updateWithoutSnapshot 只原地改值，
            // idx 仍指向同一物件。
            toolbar.setStyle(annotations.objects[idx].style)
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
                // 比照 undo/redo：刪除可能解鎖框（annotations 變空），手動依上次已知的
                // 游標位置重算，讓控制點/游標立即復原（總審查 Minor）。
                if let hp = hoverPoint { cursor(at: hp).set() }
            }
        default:
            super.keyDown(with: event)
        }
    }

}
