import AnypaintKit
import CoreGraphics

/// Capture 路由決策的純邏輯：resizeAxis（游標軸向）、toggledTool、hitTextObject。
nonisolated func captureRoutingTests() {
    // SelectionGeometry.resizeAxis：控制點→游標軸向
    T.checkEq("resizeAxis: 左上=NWSE", SelectionGeometry.resizeAxis(for: .topLeft), .nwse)
    T.checkEq("resizeAxis: 右下=NWSE", SelectionGeometry.resizeAxis(for: .bottomRight), .nwse)
    T.checkEq("resizeAxis: 右上=NESW", SelectionGeometry.resizeAxis(for: .topRight), .nesw)
    T.checkEq("resizeAxis: 左下=NESW", SelectionGeometry.resizeAxis(for: .bottomLeft), .nesw)
    T.checkEq("resizeAxis: 左=EW", SelectionGeometry.resizeAxis(for: .left), .ew)
    T.checkEq("resizeAxis: 右=EW", SelectionGeometry.resizeAxis(for: .right), .ew)
    T.checkEq("resizeAxis: 上=NS", SelectionGeometry.resizeAxis(for: .top), .ns)
    T.checkEq("resizeAxis: 下=NS", SelectionGeometry.resizeAxis(for: .bottom), .ns)

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
}
