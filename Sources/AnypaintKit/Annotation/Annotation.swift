import Foundation
import CoreGraphics

/// 標註顏色：固定色盤 7 色（spec 定案，不做任意色）。
public enum AnnotationColor: String, CaseIterable {
    case red, orange, yellow, green, blue, black, white

    public var cgColor: CGColor {
        let r: CGFloat, g: CGFloat, b: CGFloat
        switch self {
        case .red:    (r, g, b) = (0.93, 0.13, 0.16)
        case .orange: (r, g, b) = (1.00, 0.58, 0.00)
        case .yellow: (r, g, b) = (1.00, 0.84, 0.00)
        case .green:  (r, g, b) = (0.16, 0.73, 0.27)
        case .blue:   (r, g, b) = (0.00, 0.48, 1.00)
        case .black:  (r, g, b) = (0.00, 0.00, 0.00)
        case .white:  (r, g, b) = (1.00, 1.00, 1.00)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 相對亮度（Rec.709 權重）——序號數字要跟圈色對比時用。
    public var isLight: Bool {
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch self {
        case .red:    (r, g, b) = (0.93, 0.13, 0.16)
        case .orange: (r, g, b) = (1.00, 0.58, 0.00)
        case .yellow: (r, g, b) = (1.00, 0.84, 0.00)
        case .green:  (r, g, b) = (0.16, 0.73, 0.27)
        case .blue:   (r, g, b) = (0.00, 0.48, 1.00)
        case .black:  (r, g, b) = (0.00, 0.00, 0.00)
        case .white:  (r, g, b) = (1.00, 1.00, 1.00)
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.7
    }

    /// 中文顯示名（工具列色鈕 accessibility/tooltip 用）。純對應,selftest 可測。
    public var displayName: String {
        switch self {
        case .red: return "紅色"
        case .orange: return "橘色"
        case .yellow: return "黃色"
        case .green: return "綠色"
        case .blue: return "藍色"
        case .black: return "黑色"
        case .white: return "白色"
        }
    }

    /// 與此色對比的文字色：淺色（白/黃）配黑字、其餘配白字。
    public var contrastingTextCGColor: CGColor {
        isLight ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}

/// 一筆標註的樣式。粗細是連續值（spec 2026-07-22 修訂：三檔改連續，1–24pt，預設 4）。
public struct AnnotationStyle: Equatable {
    public var color: AnnotationColor
    public var lineWidth: CGFloat

    public init(color: AnnotationColor, lineWidth: CGFloat) {
        self.color = color
        self.lineWidth = AnnotationStyle.clampLineWidth(lineWidth)
    }

    /// 粗細範圍：1–24pt（spec）。所有寫入路徑（初始化、StyleStore、滾輪調整）都經這裡夾限。
    public static func clampLineWidth(_ v: CGFloat) -> CGFloat {
        min(24, max(1, v))
    }

    /// 文字字級（12＋線寬×2）——editor 與渲染共用同一公式（清理項：原本兩處重複）。
    public var textFontSize: CGFloat { 12 + lineWidth * 2 }
}

/// 一個標註物件。值型別：undo 快照＝直接複製陣列（Memento），
/// copy-on-write 讓未變動的幾何 payload 實際上共享，不爆記憶體。
/// 座標一律用「凍結影像的點座標」（與框選 selection 同座標系）。
public struct Annotation: Identifiable, Equatable {
    /// 幾何 payload。階段 1 先 5 種；階段 3–4 加 case 時編譯器會點名所有 switch。
    public enum Shape: Equatable {
        case rect(CGRect)
        case ellipse(CGRect)
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case counter(center: CGPoint)
        case text(origin: CGPoint, string: String)
        case freehand(points: [CGPoint])
        case highlighter(points: [CGPoint])
        case pixelate(rect: CGRect)
        /// 高斯模糊遮蔽（非破壞,取樣原始底圖；同 pixelate 但模糊感）。
        case blur(rect: CGRect)
        /// 聚光：畫布**其餘變暗**、只留此矩形（含其他 spotlight）明亮。渲染是畫布級（見 renderer）。
        case spotlight(rect: CGRect)
        /// 測量：畫出範圍與對角線，烙上像素讀數（寬×高，斜拉時另給對角線長度）。
        ///
        /// 存**起點與終點**而不是正規化矩形：拖曳方向就是使用者心裡要量的那條線，
        /// 正規化成 rect 會把它丟掉，對角線也就不知道該畫 ↗ 還是 ↘。
        ///
        /// `pixelScale` 隨標註本身走，不由渲染時傳入——scale 本質上是 per-annotation：
        /// 這個框在哪個螢幕畫的就該用那個螢幕的值（混合 DPI 多螢幕），縮放時它不變。
        /// 這也讓 renderer 不必為了測量多一個參數。
        case measure(from: CGPoint, to: CGPoint, pixelScale: CGFloat)
        /// 多邊形/斜框：任意角度的封閉或開放折線，角點可各自拖、邊上可插節點。
        /// closed=true → 封閉區塊（斜框），false → 折線。
        case polygon(points: [CGPoint], closed: Bool)
    }

    public let id: UUID
    public var style: AnnotationStyle
    public var shape: Shape

    public init(shape: Shape, style: AnnotationStyle, id: UUID = UUID()) {
        self.id = id
        self.style = style
        self.shape = shape
    }

    /// 序號圓標半徑：直徑隨粗細（spec）。
    public var counterRadius: CGFloat { 8 + style.lineWidth * 2 }

    /// 文字字級（spec 修訂：12＋線寬×2，滾輪熱狀態調整＝調字級）。公式定義在 AnnotationStyle.textFontSize。
    public var textFontSize: CGFloat { style.textFontSize }

    /// 實際描邊寬：螢光筆＝線寬×2（spec），其餘＝線寬。
    public var effectiveStrokeWidth: CGFloat {
        if case .highlighter = shape { return style.lineWidth * 2 }
        return style.lineWidth
    }

    /// 馬賽克格子大小（pt）：由線寬導出，滾輪熱狀態可調粒度（spec 修訂）。
    public var pixelateBlockSize: CGFloat { max(4, style.lineWidth * 2) }

    /// 高斯模糊半徑（pt）：由線寬導出，滾輪熱狀態可調強度。
    public var blurRadius: CGFloat { max(3, style.lineWidth * 1.5) }

    /// 四角 handle 可否縮放：text/counter 大小由 lineWidth 導出（滾輪調），不給 handle（spec 修訂）。
    /// 完整列舉、不用 default——未來加 case 時編譯器點名。
    public var isCornerResizable: Bool {
        switch shape {
        case .text, .counter:
            return false
        case .rect, .ellipse, .pixelate, .blur, .spotlight, .line, .arrow, .freehand, .highlighter, .measure, .polygon:
            return true
        }
    }

    /// 外接框（線段類為端點正規化矩形，寬或高可為 0）。
    public var bounds: CGRect {
        switch shape {
        case .rect(let r), .ellipse(let r):
            return r
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .counter(let c):
            let r = counterRadius
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .text(let origin, let string):
            return CGRect(origin: origin,
                          size: AnnotationGeometry.measureText(string, fontSize: textFontSize))
        case .freehand(let pts), .highlighter(let pts):
            // 用平滑後路徑的 boundingBoxOfPath（含貝茲控制點外插）＋半寬外擴——
            // 點集 bbox 會低估 Catmull-Rom 轉角 overshoot（總審查記錄）。
            guard let path = AnnotationGeometry.smoothedPath(points: pts) else {
                guard let only = pts.first else { return .zero }
                return CGRect(origin: only, size: .zero)
                    .insetBy(dx: -effectiveStrokeWidth / 2, dy: -effectiveStrokeWidth / 2)
            }
            let half = effectiveStrokeWidth / 2
            return path.boundingBoxOfPath.insetBy(dx: -half, dy: -half)
        case .pixelate(let r), .blur(let r), .spotlight(let r):
            return r
        case .measure(let a, let b, _):
            // 端點正規化矩形（比照 line/arrow）——寬或高可為 0（量單軸間距時）。
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .polygon(let pts, let closed):
            let box = EditablePolygon(points: pts, closed: closed).boundingBox
            let half = style.lineWidth / 2
            return box.insetBy(dx: -half, dy: -half)
        }
    }

    /// 點選命中：面積類用外框外擴 threshold；線段類算點到線段距離（spec）。
    public func hitTest(_ point: CGPoint, threshold: CGFloat = 8) -> Bool {
        switch shape {
        case .rect, .ellipse, .counter, .text, .pixelate, .blur, .spotlight, .measure:
            return bounds.insetBy(dx: -threshold, dy: -threshold).contains(point)
        case .line(let a, let b), .arrow(let a, let b):
            let d = AnnotationGeometry.distance(from: point, toSegmentFrom: a, to: b)
            return d <= threshold + style.lineWidth / 2
        case .freehand(let pts), .highlighter(let pts):
            guard let path = AnnotationGeometry.smoothedPath(points: pts) else { return false }
            let fat = path.copy(strokingWithWidth: effectiveStrokeWidth + threshold * 2,
                                lineCap: .round, lineJoin: .round, miterLimit: 10)
            return fat.contains(point)
        case .polygon(let pts, let closed):
            let poly = EditablePolygon(points: pts, closed: closed)
            if closed, poly.pointInside(point) { return true }
            guard let e = poly.nearestEdge(to: point) else { return false }
            return e.distance <= threshold + style.lineWidth / 2
        }
    }

    /// 平移。
    public mutating func move(by delta: CGVector) {
        switch shape {
        case .rect(var r):
            r.origin.x += delta.dx; r.origin.y += delta.dy
            shape = .rect(r)
        case .ellipse(var r):
            r.origin.x += delta.dx; r.origin.y += delta.dy
            shape = .ellipse(r)
        case .line(let a, let b):
            shape = .line(from: CGPoint(x: a.x + delta.dx, y: a.y + delta.dy),
                          to: CGPoint(x: b.x + delta.dx, y: b.y + delta.dy))
        case .arrow(let a, let b):
            shape = .arrow(from: CGPoint(x: a.x + delta.dx, y: a.y + delta.dy),
                           to: CGPoint(x: b.x + delta.dx, y: b.y + delta.dy))
        case .counter(let c):
            shape = .counter(center: CGPoint(x: c.x + delta.dx, y: c.y + delta.dy))
        case .text(let origin, let string):
            shape = .text(origin: CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy),
                          string: string)
        case .freehand(let pts):
            shape = .freehand(points: pts.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
        case .highlighter(let pts):
            shape = .highlighter(points: pts.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
        case .pixelate(var r):
            r.origin.x += delta.dx; r.origin.y += delta.dy
            shape = .pixelate(rect: r)
        case .blur(var r):
            r.origin.x += delta.dx; r.origin.y += delta.dy
            shape = .blur(rect: r)
        case .spotlight(var r):
            r.origin.x += delta.dx; r.origin.y += delta.dy
            shape = .spotlight(rect: r)
        case .measure(let a, let b, let sc):
            shape = .measure(from: CGPoint(x: a.x + delta.dx, y: a.y + delta.dy),
                             to: CGPoint(x: b.x + delta.dx, y: b.y + delta.dy),
                             pixelScale: sc)   // 平移不改 scale
        case .polygon(let pts, let closed):
            shape = .polygon(points: pts.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) },
                             closed: closed)
        }
    }

    /// 以四角 handle 縮放：把幾何從 start 映射到 new（比例縮放＋平移）。
    /// start 寬高 ≤0 或不可縮放物件＝no-op。
    public mutating func scaled(from start: CGRect, to new: CGRect) {
        guard isCornerResizable, start.width > 0, start.height > 0 else { return }
        func mapX(_ x: CGFloat) -> CGFloat { new.minX + (x - start.minX) * new.width / start.width }
        func mapY(_ y: CGFloat) -> CGFloat { new.minY + (y - start.minY) * new.height / start.height }
        func mapP(_ p: CGPoint) -> CGPoint { CGPoint(x: mapX(p.x), y: mapY(p.y)) }
        func mapR(_ r: CGRect) -> CGRect {
            CGRect(x: mapX(r.minX), y: mapY(r.minY),
                   width: r.width * new.width / start.width,
                   height: r.height * new.height / start.height)
        }
        switch shape {
        case .rect(let r):      shape = .rect(mapR(r))
        case .ellipse(let r):   shape = .ellipse(mapR(r))
        case .pixelate(let r):  shape = .pixelate(rect: mapR(r))
        case .blur(let r):      shape = .blur(rect: mapR(r))
        case .spotlight(let r): shape = .spotlight(rect: mapR(r))
        case .measure(let a, let b, let sc): shape = .measure(from: mapP(a), to: mapP(b), pixelScale: sc)
        case .line(let a, let b):  shape = .line(from: mapP(a), to: mapP(b))
        case .arrow(let a, let b): shape = .arrow(from: mapP(a), to: mapP(b))
        case .freehand(let pts):    shape = .freehand(points: pts.map(mapP))
        case .highlighter(let pts): shape = .highlighter(points: pts.map(mapP))
        case .polygon(let pts, let closed): shape = .polygon(points: pts.map(mapP), closed: closed)
        case .text, .counter: break   // isCornerResizable guard 已擋，這裡保持 switch 完整
        }
    }
}
