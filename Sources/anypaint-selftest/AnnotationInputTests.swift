import AnypaintKit
import CoreGraphics

/// AnnotationInput：兩點成形 + 滾輪調粗細累加器（原內嵌在 SelectionView，抽出後可測）。
nonisolated func annotationInputTests() {
    let a = CGPoint(x: 30, y: 40), b = CGPoint(x: 10, y: 10)

    // twoPointShape：各兩點工具對應正確 shape;反向拖曳的 rect 類正規化
    if case .rect(let r)? = AnnotationInput.twoPointShape(tool: .rect, from: a, to: b, pixelScale: 2) {
        T.checkEq("twoPoint: rect 正規化", r, CGRect(x: 10, y: 10, width: 20, height: 30))
    } else { T.checkTrue("twoPoint: rect", false) }
    if case .ellipse? = AnnotationInput.twoPointShape(tool: .ellipse, from: a, to: b, pixelScale: 2) {
        T.checkTrue("twoPoint: ellipse", true)
    } else { T.checkTrue("twoPoint: ellipse", false) }
    if case .line(let f, let t)? = AnnotationInput.twoPointShape(tool: .line, from: a, to: b, pixelScale: 2) {
        T.checkTrue("twoPoint: line 不正規化(保留起訖)", f == a && t == b)
    } else { T.checkTrue("twoPoint: line", false) }
    if case .arrow? = AnnotationInput.twoPointShape(tool: .arrow, from: a, to: b, pixelScale: 2) {
        T.checkTrue("twoPoint: arrow", true)
    } else { T.checkTrue("twoPoint: arrow", false) }
    if case .pixelate? = AnnotationInput.twoPointShape(tool: .pixelate, from: a, to: b, pixelScale: 2) {
        T.checkTrue("twoPoint: pixelate", true)
    } else { T.checkTrue("twoPoint: pixelate", false) }
    // measure：保留起訖 + pixelScale 綁進 shape
    if case .measure(let f, let t, let sc)? = AnnotationInput.twoPointShape(tool: .measure, from: a, to: b, pixelScale: 2) {
        T.checkTrue("twoPoint: measure 保留起訖", f == a && t == b)
        T.checkEq("twoPoint: measure 綁 pixelScale", sc, 2)
    } else { T.checkTrue("twoPoint: measure", false) }
    // 非兩點成形工具 → nil
    for tool in [AnnotationTool.text, .counter, .freehand, .highlighter, .select] {
        T.checkTrue("twoPoint: \(tool.rawValue)→nil",
                    AnnotationInput.twoPointShape(tool: tool, from: a, to: b, pixelScale: 2) == nil)
    }

    // stepsFromScroll：累加到門檻才動一格,剩餘留到下次
    let r1 = AnnotationInput.stepsFromScroll(accum: 0, delta: 12, step: 5)
    T.checkEq("scroll: 12/5→2 格", r1.steps, 2)
    T.checkEq("scroll: 剩餘 2", r1.newAccum, 2)
    // 未達門檻 → 0 格、全累積
    let r2 = AnnotationInput.stepsFromScroll(accum: 0, delta: 3, step: 5)
    T.checkEq("scroll: 3<5→0 格", r2.steps, 0)
    T.checkEq("scroll: 累積 3", r2.newAccum, 3)
    // 接續上次剩餘：3+3=6→1 格、剩 1
    let r3 = AnnotationInput.stepsFromScroll(accum: 3, delta: 3, step: 5)
    T.checkEq("scroll: 接續剩餘→1 格", r3.steps, 1)
    T.checkEq("scroll: 剩 1", r3.newAccum, 1)
    // 負向
    let r4 = AnnotationInput.stepsFromScroll(accum: 0, delta: -11, step: 5)
    T.checkEq("scroll: -11→-2 格", r4.steps, -2)
    T.checkEq("scroll: 負向剩餘 -1", r4.newAccum, -1)
}
