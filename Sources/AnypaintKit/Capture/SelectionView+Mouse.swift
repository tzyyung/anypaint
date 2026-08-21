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
            // 鎖/解鎖鈕優先於一切（任何工具下都可點，即選即編下畫圖工具也能鎖/解鎖）。
            if let lockID = hitLockIcon(at: p) { toggleLock(lockID); return }
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
            case .rect, .ellipse, .line, .arrow, .pixelate, .blur, .spotlight, .measure, .roundedRect, .callout:
                // 統一模型：點控制點＝編輯、點到圖形＝改選、點空白才畫新的。
                if selectOrEditExistingBeforeDraw(at: p) { return }
                shapeAnchor = p
                provisionalShape = makeShape(tool: tool, from: p, to: p)
                needsDisplay = true
            case .freehand, .highlighter:
                if selectOrEditExistingBeforeDraw(at: p) { return }
                strokePoints = [p]
                provisionalShape = (tool == .freehand) ? .freehand(points: strokePoints)
                                                       : .highlighter(points: strokePoints)
                needsDisplay = true
            case .polygon:
                // 成形中不搶點；draft 空時允許先編輯剛畫好的多邊形節點（點控制點＝編輯）。
                if polygonDraft.isEmpty, tryGrabSelectedHandle(at: p) { needsDisplay = true; return }
                // 逐點成形：雙擊收尾（≥3 點）；否則依 PolygonBuilder 決策加點/收尾/忽略。
                if event.clickCount == 2, PolygonBuilder.canFinish(points: polygonDraft) {
                    finishPolygonDraft()
                } else {
                    switch PolygonBuilder.clickAction(points: polygonDraft, newPoint: p, closeThreshold: 8) {
                    case .addPoint(let np): polygonDraft.append(np); needsDisplay = true
                    case .close: finishPolygonDraft()
                    case .ignore: break
                    }
                }
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
        // 空白處按下 → 開新框。拉框與「單擊套用視窗候選」都走這條（單擊在 mouseUp 才判定），
        // 所以選區獨佔權只要在這裡要一次。被拒絕（其他螢幕已有標註）就什麼都不做。
        guard onRequestExclusiveSelection?() ?? true else { return }
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
            case .draggingNode(let id, let index, let startShape):
                guard case .polygon(let pts, let closed) = startShape else { break }
                if selectDragBegan || p != pts[index] {
                    if !selectDragBegan {
                        annotations.beginChange()
                        selectDragBegan = true
                        syncUndoButtons()
                    }
                    let moved = EditablePolygon(points: pts, closed: closed).movingNode(index, to: p)
                    annotations.updateWithoutSnapshot(id: id) { a in
                        a.shape = .polygon(points: moved.points, closed: moved.closed)
                    }
                    NSCursor.closedHand.set()   // 拖節點中＝握拳（對應 hover 的開手）
                    needsDisplay = true
                }
            case .draggingCalloutTail(let id, let startShape):
                guard case .callout(let body, let tail) = startShape else { break }
                if selectDragBegan || p != tail {
                    if !selectDragBegan {
                        annotations.beginChange()
                        selectDragBegan = true
                        syncUndoButtons()
                    }
                    annotations.updateWithoutSnapshot(id: id) { a in
                        a.shape = .callout(body: body, tail: p)   // body 不動，只移尾端
                    }
                    NSCursor.closedHand.set()
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
        // 編輯拖曳（移動/縮放/節點）收尾——任何工具都可能（統一模型：畫圖工具下也能編輯既有圖形）。
        if selectDragBegan {
            syncUndoButtons()
            selectDrag = nil
            selectDragBegan = false
            needsDisplay = true
            return
        }
        // 抓了 handle/選了圖形但沒真的拖（純點一下）：非 select 工具要在這清掉 selectDrag,
        // 否則殘留會讓下一次拖曳誤動到它。select 工具則往下走它自己的收尾（含雙擊重編輯）。
        if selectDrag != nil, activeTool != .select {
            selectDrag = nil
            needsDisplay = true
            return
        }
        // select 工具收尾：清拖曳狀態＋同步 undo 按鈕；雙擊命中既有文字物件＝重編輯
        // （select 工具的入口，spec 原文）。
        if activeTool == .select {
            if selectDragBegan { syncUndoButtons() }
            selectDrag = nil
            selectDragBegan = false
            if event.clickCount == 2, let hit = hitTextObject(at: p),
               case .text(let origin, let string) = hit.shape {
                openTextEditor(origin: origin, initialString: string, existing: hit)
            } else if event.clickCount == 2 {
                insertPolygonNodeIfHit(at: p)   // 雙擊選中多邊形的邊 → 插節點
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
                autoSelectAfterDraw(id: annotation.id)   // 畫完自動選取
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
                    autoSelectAfterDraw(id: annotation.id)   // 畫完自動選取→立刻可拖角/邊
                }
            }
            shapeAnchor = nil
            provisionalShape = nil
            dragPoint = nil
            needsDisplay = true
            return
        }
        let creatingAnchor: CGPoint? = {
            if case .creating(let a) = drag { return a }
            return nil
        }()
        drag = nil
        dragPoint = nil
        if let sel = selection, sel.width > minSize, sel.height > minSize {
            layoutToolbar(for: sel)
            toolbar.isHidden = false
        } else if let anchor = creatingAnchor, let candidate = windowCandidate,
                  abs(p.x - anchor.x) < 3, abs(p.y - anchor.y) < 3,
                  candidate.width > minSize, candidate.height > minSize {
            // 單擊（<3pt，沿用專案慣例）＝套用游標下的視窗/整螢幕候選框（spec 視窗偵測）；
            // 之後與手動框選完全相同（可調整、可標註、三條完成鏈）。
            selection = candidate
            windowCandidate = nil
            layoutToolbar(for: candidate)
            toolbar.isHidden = false
        } else {
            selection = nil
            toolbar.isHidden = true
        }
        needsDisplay = true
    }

    // 右鍵＝一律開選單（慣例）。命中圖形→鎖定/z-order/刪除；空白→取消截圖（＋全部解鎖）。
    // **不再裸擊取消**：右鍵想開鎖定選單卻差幾像素點到空白就整張標註全沒的地雷（改成選單裡按）。
    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        commitTextEditing()   // 重編輯中的原物件在 draw() 被跳過但 hitTest 不跳過：
                              // 編輯器邊緣外右鍵可能命中隱形物件，選「刪除」會對已消失的編輯
                              // 內容做靜默 no-op（總審查 Important）；先落字對齊 mouseDown 慣例。
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = annotations.hitTest(at: p) else {
            // 空白：開選單（保留「取消截圖」逃生路徑,但要在選單裡按,不會誤觸）。
            let menu = NSMenu()
            if !lockedAnnotations.isEmpty {
                menu.addItem(makeContextMenuItem(title: "全部解鎖", action: #selector(contextUnlockAll)))
                menu.addItem(.separator())
            }
            menu.addItem(makeContextMenuItem(title: "取消截圖", action: #selector(contextCancel)))
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        annotations.selectedID = hit.id
        needsDisplay = true
        let menu = NSMenu()
        // 鎖定/解鎖：右鍵是解鎖「畫圖工具下穿透的鎖定圖形」的可靠出口（左鍵穿透去畫,不搶）。
        menu.addItem(makeContextMenuItem(title: isLocked(hit.id) ? "解鎖" : "鎖定",
                                         action: #selector(contextToggleLock)))
        menu.addItem(.separator())
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

    @objc private func contextToggleLock() {
        guard let id = annotations.selectedID else { return }
        toggleLock(id)   // 維持選取（若之後非 select 工具,rightMouseDown 收尾會 deselect）
    }
    @objc private func contextCancel() { onCancel?() }
    @objc private func contextUnlockAll() {
        lockedAnnotations.removeAll()
        refreshTransformActions()
        needsDisplay = true
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
        let r = AnnotationInput.stepsFromScroll(accum: lineWidthScrollAccum,
                                                delta: event.scrollingDeltaY, step: 5)
        lineWidthScrollAccum = r.newAccum
        if r.steps != 0 {
            let unit = r.steps > 0 ? 1 : -1
            for _ in 0..<abs(r.steps) { adjustLineWidth(by: unit) }
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
        // 路由（keyCode+修飾鍵→意圖）抽到 AnnotationInput.keyAction（可測）；view 狀態分支留在這裡。
        let m = event.modifierFlags
        switch AnnotationInput.keyAction(keyCode: event.keyCode, chars: event.charactersIgnoringModifiers,
                                         command: m.contains(.command), shift: m.contains(.shift),
                                         option: m.contains(.option), control: m.contains(.control)) {
        case .undo: undoAnnotation()
        case .redo: redoAnnotation()
        case .bringToFront:
            if let id = annotations.selectedID { annotations.bringToFront(id: id); syncUndoButtons(); needsDisplay = true }
        case .sendToBack:
            if let id = annotations.selectedID { annotations.sendToBack(id: id); syncUndoButtons(); needsDisplay = true }
        case .escape:        // 分層：多邊形成形中取消 draft → 編輯中完成編輯 → 有選取解除選取 → 否則取消（spec）
            if !polygonDraft.isEmpty { polygonDraft = []; needsDisplay = true }
            else if isEditingText { commitTextEditing() }
            else if hasSelection { deselect() }
            else { onCancel?() }
        case .copy: confirm()
        case .paste: pinConfirm()   // Shift+Enter → 貼（spec 截圖完直接貼）
        case .delete:
            // 多邊形選中節點優先：刪節點（保底 ≥3）；沒有選中節點才刪整個物件。
            if deleteSelectedPolygonNodeIfAny() {
                if let hp = hoverPoint { cursor(at: hp).set() }
            } else if let id = annotations.selectedID {
                annotations.remove(id: id); deselect(); syncUndoButtons(); needsDisplay = true
                // 刪除可能解鎖框（annotations 變空）→ 依上次游標位置重算,讓控制點/游標立即復原。
                if let hp = hoverPoint { cursor(at: hp).set() }
            }
        case .passthrough: super.keyDown(with: event)
        }
    }

    /// 取色（由 controller 的事件監聽器路由，不走 keyDown——nonactivating panel
    /// 被點擊前收不到 responder 事件；Shift 切換同理，見 SelectionOverlayController）。
    /// 放大鏡顯示中把「目前顯示格式」的色值寫進剪貼簿。
    func copyLoupeColor() {
        guard let p = activeLoupePoint() else { return }
        onInteraction?()
        copyColor(at: p)
    }

    /// 取放大鏡準星像素的色值寫進剪貼簿——格式跟著目前顯示（Shift 切換）。
    /// 座標換算與 drawLoupe 共用 samplePixelCoord——準星顯示哪個像素就取哪個。
    private func copyColor(at p: CGPoint) {
        let sp = samplePixelCoord(at: p)
        guard let rgb = ColorSampler.sampleRGB(image: snapshot.cgImage, x: sp.x, y: sp.y) else { return }
        let text = AppSettings.colorPickerShowsRGB
            ? ColorSampler.rgbString(r: rgb.r, g: rgb.g, b: rgb.b)
            : ColorSampler.hexString(r: rgb.r, g: rgb.g, b: rgb.b)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showCopiedToast("已複製 \(text)")
    }


}
