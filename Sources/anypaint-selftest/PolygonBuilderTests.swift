import AnypaintKit
import CoreGraphics

/// PolygonBuilder：多邊形逐點成形決策（收尾/重合/加點）。
nonisolated func polygonBuilderTests() {
    let p0 = CGPoint(x: 0, y: 0)
    // 空 → 第一點
    T.checkEq("builder: 首點=addPoint",
              PolygonBuilder.clickAction(points: [], newPoint: p0, closeThreshold: 8), .addPoint(p0))
    // 與上一點重合 → ignore
    T.checkEq("builder: 重合點=ignore",
              PolygonBuilder.clickAction(points: [p0], newPoint: p0, closeThreshold: 8), .ignore)
    // 已 3 點、點回起點附近 → close
    let tri = [p0, CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]
    T.checkEq("builder: 回起點=close",
              PolygonBuilder.clickAction(points: tri, newPoint: CGPoint(x: 2, y: 1), closeThreshold: 8), .close)
    // 只有 2 點時點回起點：還不能收尾 → addPoint
    T.checkEq("builder: <3點回起點=addPoint",
              PolygonBuilder.clickAction(points: [p0, CGPoint(x: 10, y: 0)],
                                         newPoint: CGPoint(x: 1, y: 1), closeThreshold: 8),
              .addPoint(CGPoint(x: 1, y: 1)))
    // canFinish
    T.checkTrue("builder: 3點可收尾", PolygonBuilder.canFinish(points: tri))
    T.checkTrue("builder: 2點不可收尾", !PolygonBuilder.canFinish(points: [p0, CGPoint(x: 10, y: 0)]))
}
