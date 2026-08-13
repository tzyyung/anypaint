import AnypaintKit
import CoreGraphics

/// SelectionGeometry 純幾何（原內嵌在 internal SelectionView，抽出後可直測）。
nonisolated func selectionGeometryTests() {
    let r = CGRect(x: 10, y: 20, width: 100, height: 60)   // minX10 maxX110 minY20 maxY80 mid60/50

    // handlePoints：8 點固定順序（左上/上中/右上/右中/右下/下中/左下/左中）
    let hp = SelectionGeometry.handlePoints(r)
    T.checkEq("geo handlePoints: 8 點", hp.count, 8)
    T.checkEq("geo handlePoints: [0]=左上", hp[0], CGPoint(x: 10, y: 80))
    T.checkEq("geo handlePoints: [2]=右上", hp[2], CGPoint(x: 110, y: 80))
    T.checkEq("geo handlePoints: [4]=右下", hp[4], CGPoint(x: 110, y: 20))
    T.checkEq("geo handlePoints: [6]=左下", hp[6], CGPoint(x: 10, y: 20))

    // handleRect：以點為中心 size×size
    T.checkEq("geo handleRect", SelectionGeometry.handleRect(at: CGPoint(x: 50, y: 50), size: 8),
              CGRect(x: 46, y: 46, width: 8, height: 8))

    // hitHandleIndex：命中左上（含容差）、中央不中
    T.checkEq("geo hitHandle: 命中左上=index0",
              SelectionGeometry.hitHandleIndex(CGPoint(x: 10, y: 80), in: r, size: 8), 0)
    T.checkTrue("geo hitHandle: 框中央不中",
                SelectionGeometry.hitHandleIndex(CGPoint(x: 60, y: 50), in: r, size: 8) == nil)
    // 容差：左上點外 4pt（size/2=4 + tolerance4 = 8 內）仍中
    T.checkEq("geo hitHandle: 容差內仍命中",
              SelectionGeometry.hitHandleIndex(CGPoint(x: 10 - 7, y: 80), in: r, size: 8), 0)

    // cornerPoints / hitCorner
    let cp = SelectionGeometry.cornerPoints(r)
    T.checkEq("geo cornerPoints: 4 角", cp.count, 4)
    T.checkTrue("geo cornerPoints: [0]=左上", cp[0].0 == .topLeft && cp[0].1 == CGPoint(x: 10, y: 80))
    T.checkTrue("geo hitCorner: 命中右下",
                SelectionGeometry.hitCorner(CGPoint(x: 110, y: 20), in: r, size: 8) == .bottomRight)
    T.checkTrue("geo hitCorner: 中央不中",
                SelectionGeometry.hitCorner(CGPoint(x: 60, y: 50), in: r, size: 8) == nil)

    // resizedBounds：拖右下角放大
    T.checkEq("geo resize: 拖右下角",
              SelectionGeometry.resizedBounds(r, corner: .bottomRight, to: CGPoint(x: 160, y: 0)),
              CGRect(x: 10, y: 0, width: 150, height: 80))
    // 拖過頭翻轉 → 正規化成正寬高（左上角拖到右下方外）
    T.checkEq("geo resize: 拖過頭翻轉正規化",
              SelectionGeometry.resizedBounds(r, corner: .topLeft, to: CGPoint(x: 200, y: 0)),
              CGRect(x: 110, y: 0, width: 90, height: 20))

    // loupeRect：正常在右下 16pt 外；靠右邊界翻到左側；靠下邊界翻到上方；最終 clamp 進畫面
    let bounds = CGSize(width: 400, height: 300)
    let normal = SelectionGeometry.loupeRect(at: CGPoint(x: 100, y: 200), in: bounds, side: 110)
    T.checkEq("geo loupe: 正常在游標右側+16", normal.minX, 116)
    let rightEdge = SelectionGeometry.loupeRect(at: CGPoint(x: 395, y: 200), in: bounds, side: 110)
    T.checkTrue("geo loupe: 近右邊界翻到左側（不超出）", rightEdge.maxX <= bounds.width)
    let bottomEdge = SelectionGeometry.loupeRect(at: CGPoint(x: 100, y: 5), in: bounds, side: 110)
    T.checkTrue("geo loupe: 近下邊界不超出頂/底", bottomEdge.minY >= 0 && bottomEdge.maxY <= bounds.height)

    // samplePixelCoord：Y 翻轉 + scale + clamp
    // 點 (50, 250) 於 viewHeight 300、scale 2、影像 800×600：x=100；y=(300-250)*2=100
    let sp = SelectionGeometry.samplePixelCoord(at: CGPoint(x: 50, y: 250), scale: 2,
                                                imageWidth: 800, imageHeight: 600, viewHeight: 300)
    T.checkEq("geo sample: x=point.x*scale", sp.x, 100)
    T.checkEq("geo sample: y=(H-point.y)*scale（翻轉）", sp.y, 100)
    // clamp：負座標 → 0；超界 → 影像邊-1
    let spClampLo = SelectionGeometry.samplePixelCoord(at: CGPoint(x: -10, y: 999), scale: 2,
                                                       imageWidth: 800, imageHeight: 600, viewHeight: 300)
    T.checkEq("geo sample: x<0 clamp 0", spClampLo.x, 0)
    T.checkEq("geo sample: y 超上界 clamp 0", spClampLo.y, 0)
    let spClampHi = SelectionGeometry.samplePixelCoord(at: CGPoint(x: 9999, y: -999), scale: 2,
                                                       imageWidth: 800, imageHeight: 600, viewHeight: 300)
    T.checkEq("geo sample: x 超界 clamp W-1", spClampHi.x, 799)
    T.checkEq("geo sample: y 超界 clamp H-1", spClampHi.y, 599)

    // crosshair 帶
    T.checkEq("geo crosshairV", SelectionGeometry.crosshairBandVertical(atX: 50, height: 300),
              CGRect(x: 48, y: 0, width: 4, height: 300))
    T.checkEq("geo crosshairH", SelectionGeometry.crosshairBandHorizontal(atY: 50, width: 400),
              CGRect(x: 0, y: 48, width: 400, height: 4))

    // resized（8 向）：r=(10,20,100,60)
    T.checkEq("geo resized: 右邊只改寬",
              SelectionGeometry.resized(r, edge: .right, to: CGPoint(x: 160, y: 999)),
              CGRect(x: 10, y: 20, width: 150, height: 60))
    T.checkEq("geo resized: 下邊移 minY→高度增",
              SelectionGeometry.resized(r, edge: .bottom, to: CGPoint(x: 999, y: 0)),
              CGRect(x: 10, y: 0, width: 100, height: 80))
    T.checkEq("geo resized: 左上角移 minX+maxY",
              SelectionGeometry.resized(r, edge: .topLeft, to: CGPoint(x: 0, y: 100)),
              CGRect(x: 0, y: 20, width: 110, height: 80))
    // ResizeEdge 順序須與 handlePoints 一致（typealias SelectionView.Handle 依賴此對齊）
    T.checkEq("geo resized: ResizeEdge 8 向", SelectionGeometry.ResizeEdge.allCases.count, 8)

    // clampPoint / clampRectOrigin
    let sz = CGSize(width: 200, height: 100)
    T.checkEq("geo clampPoint: 負→0", SelectionGeometry.clampPoint(CGPoint(x: -5, y: -9), in: sz), CGPoint.zero)
    T.checkEq("geo clampPoint: 超界→邊", SelectionGeometry.clampPoint(CGPoint(x: 999, y: 999), in: sz), CGPoint(x: 200, y: 100))
    T.checkEq("geo clampRect: 原點推回界內",
              SelectionGeometry.clampRectOrigin(CGRect(x: 190, y: 95, width: 40, height: 30), in: sz),
              CGRect(x: 160, y: 70, width: 40, height: 30))

    // validateAndLocalize（presentLocked 驗證）：globalRect 在螢幕內→轉本地;不在→nil
    let scrFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
    let inside = CGRect(x: 150, y: 250, width: 300, height: 200)
    T.checkEq("validateLocalize: 在螢幕內→減螢幕原點",
              SelectionGeometry.validateAndLocalize(globalRect: inside, screenFrame: scrFrame),
              CGRect(x: 50, y: 50, width: 300, height: 200))
    let outside = CGRect(x: 50, y: 250, width: 300, height: 200)   // minX 50 < 螢幕 minX 100
    T.checkTrue("validateLocalize: 超出螢幕→nil",
                SelectionGeometry.validateAndLocalize(globalRect: outside, screenFrame: scrFrame) == nil)

    // isValidSelectionSize
    T.checkTrue("geo validSize: nil→false", !SelectionGeometry.isValidSelectionSize(nil, minSize: 5))
    T.checkTrue("geo validSize: 剛好等於 minSize→false（需 >）",
                !SelectionGeometry.isValidSelectionSize(CGRect(x: 0, y: 0, width: 5, height: 5), minSize: 5))
    T.checkTrue("geo validSize: 大於→true",
                SelectionGeometry.isValidSelectionSize(CGRect(x: 0, y: 0, width: 6, height: 6), minSize: 5))

    // meetsMinEdge（錄影最小選區,≥ 含相等）
    T.checkTrue("meetsMinEdge: 剛好等於→true", SelectionGeometry.meetsMinEdge(CGSize(width: 64, height: 64), min: 64))
    T.checkTrue("meetsMinEdge: 一邊不足→false", !SelectionGeometry.meetsMinEdge(CGSize(width: 64, height: 63), min: 64))
    T.checkTrue("meetsMinEdge: 都夠→true", SelectionGeometry.meetsMinEdge(CGSize(width: 100, height: 80), min: 64))
}
