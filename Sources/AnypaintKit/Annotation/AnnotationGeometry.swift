import Foundation
import CoreGraphics
import CoreText

/// 標註用的純幾何函式。零 UI 依賴，selftest 直接測。
public enum AnnotationGeometry {
    /// 點 p 到線段 ab 的最短距離（線段長度為零時＝到該點的距離）。
    public static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        let t: CGFloat
        if len2 == 0 {
            t = 0
        } else {
            t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        }
        let cx = a.x + t * abx
        let cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    /// 單行文字量測（CoreText；與 renderer 同字面同字級 → 量測即顯示大小）。
    public static func measureText(_ string: String, fontSize: CGFloat) -> CGSize {
        guard !string.isEmpty else { return .zero }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent)
    }
}
