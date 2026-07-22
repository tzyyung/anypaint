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

    /// Catmull-Rom 式平滑：相鄰點差÷6 當貝茲控制點（參考 Capso BezierSmoothing）。
    /// <2 點回 nil；2 點退化為直線。不做快取（值型別下失效管理不划算，實測卡頓再加）。
    public static func smoothedPath(points: [CGPoint]) -> CGPath? {
        guard points.count >= 2 else { return nil }
        let path = CGMutablePath()
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<points.count {
            let p0 = points[max(0, i - 2)]
            let p1 = points[i - 1]
            let p2 = points[i]
            let p3 = points[min(points.count - 1, i + 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
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
