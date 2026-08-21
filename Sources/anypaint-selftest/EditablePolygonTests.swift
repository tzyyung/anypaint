import AnypaintKit
import CoreGraphics

/// EditablePolygon：可編輯多邊形幾何核心（角點/插點/刪點/命中），與 polygon 標註形狀。
nonisolated func editablePolygonTests() {
    // 單位正方形（左下原點）：(0,0)(10,0)(10,10)(0,10)
    let sq = EditablePolygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                      CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])

    T.checkEq("poly: boundingBox", sq.boundingBox, CGRect(x: 0, y: 0, width: 10, height: 10))
    T.checkTrue("poly: 內點命中", sq.pointInside(CGPoint(x: 5, y: 5)))
    T.checkTrue("poly: 外點不命中", !sq.pointInside(CGPoint(x: 15, y: 5)))
    T.checkTrue("poly: <3 點不命中",
                EditablePolygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
                    .pointInside(CGPoint(x: 0.5, y: 0.5)) == false)

    // nearestEdge：靠近下緣中點 (5,0)
    if let e = sq.nearestEdge(to: CGPoint(x: 5, y: -1)) {
        T.checkEq("poly: nearestEdge index", e.index, 0)
        T.checkEq("poly: nearestEdge 距離", e.distance, 1)
        T.checkEq("poly: nearestEdge 中點", e.midpoint, CGPoint(x: 5, y: 0))
    } else { T.checkTrue("poly: nearestEdge 非nil", false) }
    // closed 有回到起點的那條邊（index 3：(0,10)->(0,0)）
    if let e = sq.nearestEdge(to: CGPoint(x: -1, y: 5)) {
        T.checkEq("poly: closed 收尾邊 index", e.index, 3)
    } else { T.checkTrue("poly: closed 收尾邊", false) }

    // insertingNode：在邊 0 之後插點 → 位置 1
    let inserted = sq.insertingNode(at: 0, point: CGPoint(x: 5, y: 0))
    T.checkEq("poly: 插點後點數", inserted.points.count, 5)
    T.checkEq("poly: 插點位置", inserted.points[1], CGPoint(x: 5, y: 0))
    T.checkEq("poly: 越界插點=原值", sq.insertingNode(at: 99, point: .zero), sq)

    // movingNode
    T.checkEq("poly: 移點", sq.movingNode(0, to: CGPoint(x: -5, y: -5)).points[0], CGPoint(x: -5, y: -5))
    T.checkEq("poly: 越界移點=原值", sq.movingNode(99, to: .zero), sq)

    // removingNode：4→3 可以，3→2 擋下
    T.checkEq("poly: 刪點 4→3", sq.removingNode(0).points.count, 3)
    let tri = EditablePolygon(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)])
    T.checkEq("poly: 刪點 3→2 擋下=原值", tri.removingNode(0), tri)

    // handleRects：每點一個方框，中心=點
    let hs = sq.handleRects(size: 8)
    T.checkEq("poly: handle 數=點數", hs.count, 4)
    T.checkEq("poly: handle 置中於點", CGPoint(x: hs[0].midX, y: hs[0].midY), CGPoint(x: 0, y: 0))
    T.checkEq("poly: handle 尺寸", hs[0].size, CGSize(width: 8, height: 8))

    // --- Annotation.Shape.polygon ---
    let style = AnnotationStyle(color: .red, lineWidth: 4)
    let polyAnn = Annotation(shape: .polygon(points: sq.points, closed: true), style: style)
    // bounds = 外接框外擴半線寬
    T.checkEq("polyShape: bounds 外擴半線寬", polyAnn.bounds,
              CGRect(x: 0, y: 0, width: 10, height: 10).insetBy(dx: -2, dy: -2))
    // hitTest：內點命中、遠處外點不命中
    T.checkTrue("polyShape: 內點命中", polyAnn.hitTest(CGPoint(x: 5, y: 5)))
    T.checkTrue("polyShape: 遠外點不命中", !polyAnn.hitTest(CGPoint(x: 100, y: 100)))
    // move：全點平移
    var moved = polyAnn
    moved.move(by: CGVector(dx: 5, dy: 7))
    if case .polygon(let pts, _) = moved.shape {
        T.checkEq("polyShape: move 平移首點", pts[0], CGPoint(x: 5, y: 7))
    } else { T.checkTrue("polyShape: move 型別", false) }
    // scaled：從單位框放大兩倍 → 各點×2
    var scaled = polyAnn
    scaled.scaled(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                  to: CGRect(x: 0, y: 0, width: 20, height: 20))
    if case .polygon(let pts, _) = scaled.shape {
        T.checkEq("polyShape: scaled 角點×2", pts[2], CGPoint(x: 20, y: 20))
    } else { T.checkTrue("polyShape: scaled 型別", false) }
    T.checkTrue("polyShape: 角點可縮放", polyAnn.isCornerResizable)
}
