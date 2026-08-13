import AnypaintKit
import CoreGraphics

/// Capture 路由決策的純邏輯：resizeAxis（游標軸向）、toggledTool、hitTextObject。
nonisolated func captureRoutingTests() {
    // SelectionGeometry.resizeAxis：控制點→游標軸向
    T.checkEq("resizeAxis: 左上=NWSE", SelectionGeometry.resizeAxis(for: SelectionGeometry.ResizeEdge.topLeft), .nwse)
    T.checkEq("resizeAxis: 右下=NWSE", SelectionGeometry.resizeAxis(for: SelectionGeometry.ResizeEdge.bottomRight), .nwse)
    T.checkEq("resizeAxis: 右上=NESW", SelectionGeometry.resizeAxis(for: SelectionGeometry.ResizeEdge.topRight), .nesw)
    T.checkEq("resizeAxis: 左下=NESW", SelectionGeometry.resizeAxis(for: SelectionGeometry.ResizeEdge.bottomLeft), .nesw)
    T.checkEq("resizeAxis: 左=EW", SelectionGeometry.resizeAxis(for: .left), .ew)
    T.checkEq("resizeAxis: 右=EW", SelectionGeometry.resizeAxis(for: .right), .ew)
    T.checkEq("resizeAxis: 上=NS", SelectionGeometry.resizeAxis(for: .top), .ns)
    T.checkEq("resizeAxis: 下=NS", SelectionGeometry.resizeAxis(for: .bottom), .ns)
    // 四角版（標註縮放,只有對角）
    T.checkEq("resizeAxis 角: 左上=NWSE", SelectionGeometry.resizeAxis(for: SelectionGeometry.Corner.topLeft), .nwse)
    T.checkEq("resizeAxis 角: 右上=NESW", SelectionGeometry.resizeAxis(for: SelectionGeometry.Corner.topRight), .nesw)

    // selectToolCursor：角 handle→resize;命中物件→openHand;否則 arrow
    T.checkEq("selCursor: 角→resize", SelectionGeometry.selectToolCursor(cornerAxis: .nwse, hitAnyObject: true), .resize(.nwse))
    T.checkEq("selCursor: 命中物件→openHand", SelectionGeometry.selectToolCursor(cornerAxis: nil, hitAnyObject: true), .openHand)
    T.checkEq("selCursor: 空→arrow", SelectionGeometry.selectToolCursor(cornerAxis: nil, hitAnyObject: false), .arrow)

    // cursorKind 主決策樹（層序）
    func ck(toolbar: Bool = false, text: Bool = false, textHover: Bool = false, select: Bool = false,
            selKind: SelectionGeometry.CursorKind = .arrow, drawing: Bool = false,
            edge: SelectionGeometry.ResizeAxis? = nil, inside: Bool = false) -> SelectionGeometry.CursorKind {
        SelectionGeometry.cursorKind(toolbarHit: toolbar, isTextTool: text, textHover: textHover,
                                     isSelectTool: select, selectCursor: selKind, isDrawingTool: drawing,
                                     edgeAxis: edge, insideSelection: inside)
    }
    T.checkEq("cursor: 工具列→arrow（最優先）", ck(toolbar: true, drawing: true, edge: .ew), .arrow)
    T.checkEq("cursor: 文字工具 hover→openHand", ck(text: true, textHover: true), .openHand)
    T.checkEq("cursor: select 工具→委派 selKind", ck(select: true, selKind: .resize(.nesw)), .resize(.nesw))
    T.checkEq("cursor: 繪製工具→crosshair", ck(drawing: true), .crosshair)
    T.checkEq("cursor: 命中控制點→resize", ck(edge: .ew), .resize(.ew))
    T.checkEq("cursor: 選區內→openHand", ck(inside: true), .openHand)
    T.checkEq("cursor: 預設→crosshair", ck(), .crosshair)

    // AnnotationInput.toggledTool：點當前工具→取消,點別的→切換
    T.checkTrue("toggledTool: 點當前→nil", AnnotationInput.toggledTool(tapped: .rect, active: .rect) == nil)
    T.checkEq("toggledTool: 點別的→切換", AnnotationInput.toggledTool(tapped: .arrow, active: .rect), .arrow)
    T.checkEq("toggledTool: 無當前→切過去", AnnotationInput.toggledTool(tapped: .line, active: nil), .line)

    // AnnotationDocument.hitTextObject：只命中文字物件、由上而下
    let doc = AnnotationDocument()
    let style = AnnotationStyle(color: .red, lineWidth: 4)
    let rectA = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
    let text1 = Annotation(shape: .text(origin: CGPoint(x: 10, y: 10), string: "A"), style: style)
    doc.add(rectA)
    doc.add(text1)
    // 命中文字（在其 bounds 內）
    let hit = doc.hitTextObject(at: CGPoint(x: text1.bounds.midX, y: text1.bounds.midY))
    T.checkEq("hitText: 命中文字物件", hit?.id, text1.id)
    // 點在 rect 上但不在任何文字 → nil（rect 不算文字）
    T.checkTrue("hitText: 非文字物件不算", doc.hitTextObject(at: CGPoint(x: 90, y: 90)) == nil)
    // 空文件 → nil
    T.checkTrue("hitText: 空文件→nil", AnnotationDocument().hitTextObject(at: .zero) == nil)

    // AnnotationDocument.counterNumbersMap：只列 counter、值＝序號
    let cdoc = AnnotationDocument()
    let c1 = Annotation(shape: .counter(center: CGPoint(x: 0, y: 0)), style: style)
    let c2 = Annotation(shape: .counter(center: CGPoint(x: 10, y: 0)), style: style)
    let rr = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 5, height: 5)), style: style)
    cdoc.add(c1); cdoc.add(rr); cdoc.add(c2)
    let map = cdoc.counterNumbersMap()
    T.checkEq("counterMap: 只含 2 個 counter", map.count, 2)
    T.checkEq("counterMap: c1=1", map[c1.id], 1)
    T.checkEq("counterMap: c2=2（跳過中間非 counter）", map[c2.id], 2)
    T.checkTrue("counterMap: 非 counter 不列", map[rr.id] == nil)

    // SelectionOverlayLogic.shouldToggleColorFormat：Shift 上升緣、無其他修飾鍵
    T.checkTrue("toggleFmt: Shift 剛按下→true",
                SelectionOverlayLogic.shouldToggleColorFormat(shiftDown: true, shiftWasDown: false, othersDown: false))
    T.checkTrue("toggleFmt: Shift 持續按住→false（非上升緣）",
                !SelectionOverlayLogic.shouldToggleColorFormat(shiftDown: true, shiftWasDown: true, othersDown: false))
    T.checkTrue("toggleFmt: 同時按其他鍵→false",
                !SelectionOverlayLogic.shouldToggleColorFormat(shiftDown: true, shiftWasDown: false, othersDown: true))
    T.checkTrue("toggleFmt: Shift 放開→false",
                !SelectionOverlayLogic.shouldToggleColorFormat(shiftDown: false, shiftWasDown: true, othersDown: false))

    // SelectionOverlayLogic.shouldGrant：其他視窗有鎖框→不准
    T.checkTrue("grant: 沒有其他視窗→准", SelectionOverlayLogic.shouldGrant(otherFrameLockedFlags: []))
    T.checkTrue("grant: 其他都沒鎖→准", SelectionOverlayLogic.shouldGrant(otherFrameLockedFlags: [false, false]))
    T.checkTrue("grant: 有一個鎖了→不准", !SelectionOverlayLogic.shouldGrant(otherFrameLockedFlags: [false, true]))

    // SelectionOverlayLogic.movedToFront：把符合者移到最前;找不到→原序
    T.checkEq("movedFront: 移到最前", SelectionOverlayLogic.movedToFront([1, 2, 3, 4]) { $0 == 3 }, [3, 1, 2, 4])
    T.checkEq("movedFront: 找不到→原序", SelectionOverlayLogic.movedToFront([1, 2, 3]) { $0 == 9 }, [1, 2, 3])
    T.checkEq("movedFront: 已在最前→不變", SelectionOverlayLogic.movedToFront([1, 2, 3]) { $0 == 1 }, [1, 2, 3])

    // SelectionOverlayLogic.escAction：分層（組字>編輯>選取>取消）
    T.checkEq("esc: 組字中→讓 IME",
              SelectionOverlayLogic.escAction(anyComposing: true, anyEditing: true, anySelection: true), .letIME)
    T.checkEq("esc: 編輯中（未組字）→完成編輯",
              SelectionOverlayLogic.escAction(anyComposing: false, anyEditing: true, anySelection: true), .commitEditing)
    T.checkEq("esc: 有選取→解除選取",
              SelectionOverlayLogic.escAction(anyComposing: false, anyEditing: false, anySelection: true), .deselect)
    T.checkEq("esc: 都沒有→取消",
              SelectionOverlayLogic.escAction(anyComposing: false, anyEditing: false, anySelection: false), .cancel)
}
