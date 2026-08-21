import Foundation
import CoreGraphics

/// 可編輯多邊形的純幾何核心（Foundation/CoreGraphics only，進 selftest）。
/// 供多邊形標註（階段 1）、非矩形裁切（階段 2）、透視校正（階段 3）共用：
/// 角點各自拖、邊上插節點、拖/刪節點。座標＝凍結影像點座標（左下原點）。
public struct EditablePolygon: Equatable {
    public var points: [CGPoint]
    public var closed: Bool

    public init(points: [CGPoint], closed: Bool = true) {
        self.points = points
        self.closed = closed
    }

    /// 外接框（無點 → .zero）。
    public var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 邊的端點索引對：closed 有 n 條（含回到起點的收尾邊）、open 有 n-1 條。
    private var edgeIndices: [(Int, Int)] {
        guard points.count >= 2 else { return [] }
        let n = points.count
        let upper = closed ? n : n - 1
        return (0..<upper).map { ($0, ($0 + 1) % n) }
    }

    /// ray-casting 命中（<3 點恆 false）。
    public func pointInside(_ p: CGPoint) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (p.y - a.y) / (b.y - a.y)
                if p.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// 距 p 最近的邊（<2 點 → nil）。回傳邊索引（＝起點索引）、點到線段距離、線段中點。
    public func nearestEdge(to p: CGPoint) -> (index: Int, distance: CGFloat, midpoint: CGPoint)? {
        let edges = edgeIndices
        guard !edges.isEmpty else { return nil }
        var best: (index: Int, distance: CGFloat, midpoint: CGPoint)?
        for (idx, (i, k)) in edges.enumerated() {
            let a = points[i], b = points[k]
            let d = AnnotationGeometry.distance(from: p, toSegmentFrom: a, to: b)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if best == nil || d < best!.distance { best = (idx, d, mid) }
        }
        return best
    }

    /// 在 edgeIndex 之後插入新節點（越界 → 原值）。
    public func insertingNode(at edgeIndex: Int, point: CGPoint) -> EditablePolygon {
        guard edgeIndex >= 0, edgeIndex < points.count else { return self }
        var copy = self
        copy.points.insert(point, at: edgeIndex + 1)
        return copy
    }

    /// 移動指定節點（越界 → 原值）。
    public func movingNode(_ index: Int, to p: CGPoint) -> EditablePolygon {
        guard index >= 0, index < points.count else { return self }
        var copy = self
        copy.points[index] = p
        return copy
    }

    /// 刪除指定節點；結果 <3 點或越界 → 原值（多邊形至少 3 點）。
    public func removingNode(_ index: Int) -> EditablePolygon {
        guard index >= 0, index < points.count, points.count > 3 else { return self }
        var copy = self
        copy.points.remove(at: index)
        return copy
    }

    /// 每個角點為中心的方形 handle（繪製與命中共用）。
    public func handleRects(size: CGFloat) -> [CGRect] {
        points.map { CGRect(x: $0.x - size / 2, y: $0.y - size / 2, width: size, height: size) }
    }
}
