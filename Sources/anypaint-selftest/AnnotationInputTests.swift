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
    if case .blur(let r)? = AnnotationInput.twoPointShape(tool: .blur, from: a, to: b, pixelScale: 2) {
        T.checkEq("twoPoint: blur 正規化", r, CGRect(x: 10, y: 10, width: 20, height: 30))
    } else { T.checkTrue("twoPoint: blur", false) }
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

    // textCommitAction：編輯既有＋空→remove;既有＋有字→update;新＋有字→add;新＋空→none
    T.checkEq("textCommit: 既有+空→remove", AnnotationInput.textCommitAction(trimmed: "", hasExistingID: true), .remove)
    T.checkEq("textCommit: 既有+有字→update", AnnotationInput.textCommitAction(trimmed: "hi", hasExistingID: true), .update)
    T.checkEq("textCommit: 新+有字→add", AnnotationInput.textCommitAction(trimmed: "hi", hasExistingID: false), .add)
    T.checkEq("textCommit: 新+空→none", AnnotationInput.textCommitAction(trimmed: "", hasExistingID: false), .none)

    // shapeInSelection：交集→true;無交集→false;無選區→false
    T.checkTrue("inSel: 交集→true",
                AnnotationInput.shapeInSelection(bounds: CGRect(x: 5, y: 5, width: 10, height: 10),
                                                 selection: CGRect(x: 0, y: 0, width: 20, height: 20)))
    T.checkTrue("inSel: 無交集→false",
                !AnnotationInput.shapeInSelection(bounds: CGRect(x: 100, y: 100, width: 10, height: 10),
                                                  selection: CGRect(x: 0, y: 0, width: 20, height: 20)))
    T.checkTrue("inSel: 無選區→false",
                !AnnotationInput.shapeInSelection(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), selection: nil))

    // keyAction：overlay keyDown 路由
    func ka(_ code: UInt16, _ chars: String?, cmd: Bool = false, shift: Bool = false,
            opt: Bool = false, ctrl: Bool = false) -> AnnotationInput.KeyAction {
        AnnotationInput.keyAction(keyCode: code, chars: chars, command: cmd, shift: shift, option: opt, control: ctrl)
    }
    T.checkEq("key: ⌘Z→undo", ka(6, "z", cmd: true), .undo)
    T.checkEq("key: ⌘⇧Z→redo", ka(6, "z", cmd: true, shift: true), .redo)
    T.checkEq("key: ⌘]→bringToFront", ka(30, "]", cmd: true), .bringToFront)
    T.checkEq("key: ⌘[→sendToBack", ka(33, "[", cmd: true), .sendToBack)
    T.checkEq("key: ⌘⌥Z→passthrough（排除 option）", ka(6, "z", cmd: true, opt: true), .passthrough)
    T.checkEq("key: Esc(53)→escape", ka(53, nil), .escape)
    T.checkEq("key: Enter(36)→copy", ka(36, nil), .copy)
    T.checkEq("key: ⇧Enter→paste", ka(36, nil, shift: true), .paste)
    T.checkEq("key: Delete(51)→delete", ka(51, nil), .delete)
    T.checkEq("key: fn+Delete(117)→delete", ka(117, nil), .delete)
    T.checkEq("key: 其他→passthrough", ka(40, "k"), .passthrough)
    T.checkEq("key: 純 z 無⌘→passthrough", ka(6, "z"), .passthrough)
}
