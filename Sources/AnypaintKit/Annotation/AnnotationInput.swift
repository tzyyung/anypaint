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
        // measure 不正規化成 rect：起點→終點就是使用者要量的那條線,對角線方向靠它決定。
        // pixelScale＝擷取端的 pointPixelScale（讀數要像素,混合 DPI 各自正確）。
        case .measure:  return .measure(from: a, to: b, pixelScale: pixelScale)
        case .text, .counter, .freehand, .highlighter, .select: return nil
        }
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
