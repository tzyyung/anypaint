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

    /// 文字字級（spec 修訂：12＋線寬×2，滾輪熱狀態調整＝調字級）。
    public var textFontSize: CGFloat { 12 + style.lineWidth * 2 }

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
        }
    }

    /// 點選命中：面積類用外框外擴 threshold；線段類算點到線段距離（spec）。
    public func hitTest(_ point: CGPoint, threshold: CGFloat = 8) -> Bool {
        switch shape {
        case .rect, .ellipse, .counter, .text:
            return bounds.insetBy(dx: -threshold, dy: -threshold).contains(point)
        case .line(let a, let b), .arrow(let a, let b):
            let d = AnnotationGeometry.distance(from: point, toSegmentFrom: a, to: b)
            return d <= threshold + style.lineWidth / 2
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
        }
    }
}
