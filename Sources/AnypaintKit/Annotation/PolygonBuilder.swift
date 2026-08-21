import Foundation
import CoreGraphics

/// 多邊形逐點成形的決策純函式（無 view 狀態，進 selftest）。
/// view 只負責蒐集點擊座標並套用回傳的 Action。
public enum PolygonBuilder {
    public enum Action: Equatable {
        case addPoint(CGPoint)
        case close
        case ignore
    }

    /// 一次點擊的決策：≥3 點且落在起點門檻內 → close；與上一點重合 → ignore；其餘 → addPoint。
    public static func clickAction(points: [CGPoint], newPoint: CGPoint,
                                   closeThreshold: CGFloat) -> Action {
        if points.count >= 3, let first = points.first,
           hypot(newPoint.x - first.x, newPoint.y - first.y) <= closeThreshold {
            return .close
        }
        if let last = points.last,
           hypot(newPoint.x - last.x, newPoint.y - last.y) < 1e-6 {
            return .ignore
        }
        return .addPoint(newPoint)
    }

    /// 雙擊/Enter 收尾的前提：至少 3 點才成面。
    public static func canFinish(points: [CGPoint]) -> Bool {
        points.count >= 3
    }
}
