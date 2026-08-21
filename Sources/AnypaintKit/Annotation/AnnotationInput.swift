import Foundation
import CoreGraphics

/// 標註工具的**輸入邏輯純函式**（無 AppKit、無 view 狀態,selftest 可測）。
/// 原本內嵌在 `SelectionView`（internal NSView，測不到）的 mouseDrag 兩點成形與滾輪調粗細累加。
public enum AnnotationInput {

    /// 兩點成形：把「工具 + 起點 + 終點（+ 量測用 pixelScale）」對應到 `Annotation.Shape`。
    /// 非兩點成形的工具（text/counter/freehand/highlighter/select）回 nil（呼叫端據此 precondition）。
    public static func twoPointShape(tool: AnnotationTool, from a: CGPoint, to b: CGPoint,
                                     pixelScale: CGFloat) -> Annotation.Shape? {
        switch tool {
        case .rect:     return .rect(CoordinateUtils.rect(from: a, to: b))
        case .ellipse:  return .ellipse(CoordinateUtils.rect(from: a, to: b))
        case .line:     return .line(from: a, to: b)
        case .arrow:    return .arrow(from: a, to: b)
        case .pixelate: return .pixelate(rect: CoordinateUtils.rect(from: a, to: b))
        case .blur:     return .blur(rect: CoordinateUtils.rect(from: a, to: b))
        case .spotlight: return .spotlight(rect: CoordinateUtils.rect(from: a, to: b))
        case .roundedRect: return .roundedRect(CoordinateUtils.rect(from: a, to: b))
        case .callout:
            let body = CoordinateUtils.rect(from: a, to: b)
            return .callout(body: body, tail: AnnotationGeometry.defaultCalloutApex(for: body), string: "")
        // measure 不正規化成 rect：起點→終點就是使用者要量的那條線,對角線方向靠它決定。
        // pixelScale＝擷取端的 pointPixelScale（讀數要像素,混合 DPI 各自正確）。
        case .measure:  return .measure(from: a, to: b, pixelScale: pixelScale)
        // polygon 逐點成形（走 PolygonBuilder），非兩點；同 text/counter 回 nil。
        case .text, .counter, .freehand, .highlighter, .select, .polygon: return nil
        }
    }

    /// 文字編輯提交的決策（純：只看「字串空不空」與「是否編輯既有物件」）。
    public enum TextCommitAction: Equatable { case remove, update, add, none }
    public static func textCommitAction(trimmed: String, hasExistingID: Bool) -> TextCommitAction {
        if hasExistingID { return trimmed.isEmpty ? .remove : .update }
        return trimmed.isEmpty ? .none : .add
    }

    /// 新標註是否落在選區內（框外不入庫的 guard）；無選區＝不入庫。
    public static func shapeInSelection(bounds: CGRect, selection: CGRect?) -> Bool {
        selection.map { bounds.intersects($0) } ?? false
    }

    /// overlay keyDown 的高階動作（純路由：keyCode+修飾鍵+字元 → 意圖,不含 view 狀態分支）。
    public enum KeyAction: Equatable {
        case undo, redo, bringToFront, sendToBack, escape, copy, paste, delete, passthrough
    }
    /// keyDown 路由：⌘Z/⌘⇧Z、⌘]/⌘[（皆排除 option/control）、Esc(53)、Return/Enter(36/76,Shift=貼)、
    /// Delete(51/117),其餘 passthrough。
    public static func keyAction(keyCode: UInt16, chars: String?,
                                 command: Bool, shift: Bool, option: Bool, control: Bool) -> KeyAction {
        if command, !option, !control {
            let lower = chars?.lowercased()
            if lower == "z" { return shift ? .redo : .undo }
            if chars == "]" { return .bringToFront }
            if chars == "[" { return .sendToBack }
        }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return shift ? .paste : .copy
        case 51, 117: return .delete
        default: return .passthrough
        }
    }

    /// 工具列點擊的切換規則：點到當前工具＝取消（回 nil）、點到別的＝切過去。
    public static func toggledTool(tapped: AnnotationTool, active: AnnotationTool?) -> AnnotationTool? {
        tapped == active ? nil : tapped
    }

    /// 重疊選取的循環決策：`hits`＝該點命中的 id（最上層在前）。
    /// 目前選中的若在命中清單→回**下一個**（循環到下層,再點又回最上層）；否則回最上層。空→nil。
    public static func nextSelection(hits: [UUID], current: UUID?) -> UUID? {
        guard !hits.isEmpty else { return nil }
        if let cur = current, let idx = hits.firstIndex(of: cur) {
            return hits[(idx + 1) % hits.count]
        }
        return hits[0]
    }

    /// 滾輪調粗細的累加器：把連續 scrollingDeltaY 累加進 `accum`,每滿 ±`step` 就吐一格
    /// （正＝加粗、負＝變細）。回傳「這次要調幾格」與「消化後剩餘的累加值」。
    /// 抽成純函式讓「累加到門檻才動一格、剩餘留到下次」這條可單元測試。
    public static func stepsFromScroll(accum: CGFloat, delta: CGFloat,
                                       step: CGFloat) -> (steps: Int, newAccum: CGFloat) {
        var a = accum + delta
        var steps = 0
        while a >= step { a -= step; steps += 1 }
        while a <= -step { a += step; steps -= 1 }
        return (steps, a)
    }
}
