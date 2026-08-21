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

    /// 測量讀數：依拖曳出的形狀選最有意義的表示，可能一行或兩行（純函式，selftest 可測）。
    ///
    /// - 細長橫條 → `["160 px"]`（量水平間距，另一維是雜訊）
    /// - 細長直條 → `["96 px"]`
    /// - 兩維都夠大 → `["248 × 96 px", "↘ 265 px"]`（尺寸＋對角線長度與方向）
    /// - 兩維都很小（剛開始拖）→ `["3 × 5 px"]`，對角線此時沒有意義
    ///
    /// 一種互動（拖一下）同時回答三個問題：寬、高、斜距。**對角線一律附上而不做意圖猜測**——
    /// 量元件尺寸的人多看一行不受影響，量斜距的人則不必切換模式或按修飾鍵；
    /// 幾何上分不出這兩種意圖，猜錯的代價比多顯示一行大。
    ///
    /// - Parameters:
    ///   - from: 拖曳起點（**點**座標，與 selection 同座標系）。
    ///   - to: 拖曳終點。方向決定對角線畫向與箭頭符號。
    ///   - pixelScale: 擷取端的 `SCContentFilter.pointPixelScale`。讀數一律以**像素**呈現
    ///     ——使用者量的是 px。
    ///   - thinThresholdPx: 判定「細長」的門檻，單位**像素**。用像素而非點：使用者拖的時候
    ///     看的是螢幕上的實際粗細，用點判定會讓 Retina 與非 Retina 螢幕的手感不同。
    public static func measurementLines(from: CGPoint, to: CGPoint, pixelScale: CGFloat,
                                        thinThresholdPx: CGFloat = 8) -> [String] {
        let dx = to.x - from.x, dy = to.y - from.y
        let wPx = (abs(dx) * pixelScale).rounded()
        let hPx = (abs(dy) * pixelScale).rounded()
        if hPx < thinThresholdPx, wPx >= thinThresholdPx { return ["\(Int(wPx)) px"] }
        if wPx < thinThresholdPx, hPx >= thinThresholdPx { return ["\(Int(hPx)) px"] }

        let size = "\(Int(wPx)) × \(Int(hPx)) px"
        guard wPx >= thinThresholdPx, hPx >= thinThresholdPx else { return [size] }
        let diagonalPx = (hypot(dx, dy) * pixelScale).rounded()
        return [size, "\(diagonalArrow(dx: dx, dy: dy)) \(Int(diagonalPx)) px"]
    }

    /// 對角線方向符號。座標系是 view 座標（左下原點、**y 向上**）——所以 dy > 0 是往上。
    private static func diagonalArrow(dx: CGFloat, dy: CGFloat) -> String {
        if dx >= 0 { return dy >= 0 ? "↗" : "↘" }
        return dy >= 0 ? "↖" : "↙"
    }

    /// 圓角矩形的圓角半徑（點）：隨框短邊成比例（1/4），上限 28pt。
    /// 0.25×短邊 ≤ 0.5×短邊，永遠不會超過短邊一半（不會意外變成膠囊）。
    public static func cornerRadius(for rect: CGRect) -> CGFloat {
        let minSide = min(abs(rect.width), abs(rect.height))
        return min(minSide * 0.25, 28)
    }

    /// Callout 尾巴基座寬（點）：隨 body 短邊成比例（0.3），夾在 [12, 48]。
    public static func calloutBaseWidth(for body: CGRect) -> CGFloat {
        min(max(min(abs(body.width), abs(body.height)) * 0.3, 12), 48)
    }

    /// Callout 尾巴基座：回傳尾巴貼在 body 邊上的兩個基點（沿該邊排列，中間會拉出 apex）。
    /// apex 落在 body 內 → 無尾巴（回 nil）。座標系＝view 座標（y 向上，minY 為底邊）。
    ///
    /// 貼哪條邊：比較 apex 對 body 的**水平溢出量**與**垂直溢出量**，大的那個決定主邊
    /// （純垂直外側→貼上/下邊、純水平外側→貼左/右邊、斜角→溢出多的邊）。
    /// 基座中心＝apex 在該邊上的投影，夾限使基座不越出邊界；邊太短放不下就置中。
    public static func calloutTailBase(body: CGRect, apex: CGPoint, baseWidth: CGFloat)
        -> (CGPoint, CGPoint)? {
        if body.contains(apex) { return nil }
        let half = baseWidth / 2
        let outLeft = apex.x < body.minX, outRight = apex.x > body.maxX
        let outBelow = apex.y < body.minY, outAbove = apex.y > body.maxY
        let dxOut = outLeft ? (body.minX - apex.x) : (outRight ? (apex.x - body.maxX) : 0)
        let dyOut = outBelow ? (body.minY - apex.y) : (outAbove ? (apex.y - body.maxY) : 0)
        if dxOut >= dyOut {
            // 貼左/右垂直邊 → 基點沿 y 排列
            let edgeX = outLeft ? body.minX : body.maxX
            let lo = body.minY + half, hi = body.maxY - half
            let cy = lo <= hi ? min(max(apex.y, lo), hi) : body.midY
            return (CGPoint(x: edgeX, y: cy - half), CGPoint(x: edgeX, y: cy + half))
        } else {
            // 貼上/下水平邊 → 基點沿 x 排列
            let edgeY = outBelow ? body.minY : body.maxY
            let lo = body.minX + half, hi = body.maxX - half
            let cx = lo <= hi ? min(max(apex.x, lo), hi) : body.midX
            return (CGPoint(x: cx - half, y: edgeY), CGPoint(x: cx + half, y: edgeY))
        }
    }

    /// Callout 預設尾巴頂點：新畫出 body 時尾巴指向左下（從底邊左側 1/4 處往下拉）。
    public static func defaultCalloutApex(for body: CGRect) -> CGPoint {
        CGPoint(x: body.minX + body.width * 0.25,
                y: body.minY - max(28, body.height * 0.6))
    }

    /// Callout 內嵌文字的可用矩形：body 內縮一段（避開圓角與描邊）。內縮量隨圓角走、至少 8pt。
    /// body 太小放不下＝回 .zero（呼叫端據此不畫字/不開編輯器）。
    public static func calloutTextRect(body: CGRect) -> CGRect {
        let pad = max(8, cornerRadius(for: body) * 0.6)
        guard body.width > pad * 2 + 2, body.height > pad * 2 + 2 else { return .zero }
        return body.insetBy(dx: pad, dy: pad)
    }
}
