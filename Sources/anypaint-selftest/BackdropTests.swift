import AnypaintKit
import CoreGraphics
import Foundation

/// #1 美化背景 Backdrop：純資料/版面（單元）＋完整渲染管線（整合）。
nonisolated func backdropTests() {

    // ── 單元：BackdropBackground ──────────────────────────────
    T.checkEq("bg: 全部預設數", BackdropBackground.allCases.count, 7)
    for bg in BackdropBackground.allCases {
        if bg.isGradient {
            T.checkTrue("bg: \(bg.rawValue) 漸層有兩色標", (bg.gradientColors?.count ?? 0) == 2)
            T.checkTrue("bg: \(bg.rawValue) 漸層無純色", bg.solidColor == nil)
        } else {
            T.checkTrue("bg: \(bg.rawValue) 純色有顏色", bg.solidColor != nil)
            T.checkTrue("bg: \(bg.rawValue) 純色無漸層", bg.gradientColors == nil)
        }
        T.checkTrue("bg: \(bg.rawValue) 有中文名", !bg.displayName.isEmpty)
    }

    // ── 單元：BackdropStyle 夾限與預設 ──────────────────────────
    let def = BackdropStyle()
    T.checkTrue("style: 預設有背景/正 padding", def.paddingPt > 0)
    T.checkEq("style: padding 夾到上限", BackdropStyle(paddingPt: 999).paddingPt, 160)
    T.checkEq("style: padding 夾到下限", BackdropStyle(paddingPt: -5).paddingPt, 0)
    T.checkEq("style: 圓角夾到上限", BackdropStyle(cornerRadiusPt: 999).cornerRadiusPt, 48)
    T.checkEq("style: 圓角夾到下限", BackdropStyle(cornerRadiusPt: -5).cornerRadiusPt, 0)

    // ── 單元：BackdropLayout ────────────────────────────────
    let src = CGSize(width: 200, height: 100)
    let outS = BackdropLayout.outputSize(sourcePixelSize: src, paddingPt: 40, scale: 2)
    T.checkEq("layout: 輸出尺寸=來源+2×padding×scale", outS, CGSize(width: 200 + 160, height: 100 + 160))
    let cr = BackdropLayout.contentRect(sourcePixelSize: src, paddingPt: 40, scale: 2)
    T.checkEq("layout: 內容矩形置中", cr, CGRect(x: 80, y: 80, width: 200, height: 100))
    T.checkEq("layout: 圓角像素=點×scale", BackdropLayout.cornerRadiusPx(cornerRadiusPt: 10, sourcePixelSize: src, scale: 2), 20)
    T.checkEq("layout: 圓角不超過短邊一半",
              BackdropLayout.cornerRadiusPx(cornerRadiusPt: 999, sourcePixelSize: src, scale: 1), 50)

    // ── 像素讀取 helper ────────────────────────────────────
    // 回傳 (x,y) 左上原點的 RGBA（0–255）。
    func pixels(of img: CGImage) -> (w: Int, h: Int, buf: [UInt8]) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, buf)
    }
    func rgba(_ p: (w: Int, h: Int, buf: [UInt8]), _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * p.w + x) * 4
        return (p.buf[i], p.buf[i+1], p.buf[i+2], p.buf[i+3])
    }
    // 純紅來源（含明顯內容，用來驗置中畫回）。
    func redSource(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    // ── 整合：純色背景、無圓角無陰影 → 尺寸/角落背景/中心來源 ─────────
    let source = redSource(120, 80)
    let solidStyle = BackdropStyle(background: .graphite, paddingPt: 20, cornerRadiusPt: 0, shadow: false)
    guard let solidOut = BackdropRenderer.render(source: source, style: solidStyle, scale: 1) else {
        T.checkTrue("render: 純色輸出", false); return
    }
    T.checkEq("render: 輸出寬=120+40", solidOut.width, 160)
    T.checkEq("render: 輸出高=80+40", solidOut.height, 120)
    let sp = pixels(of: solidOut)
    // 角落＝石墨純色（約 0.16,0.17,0.20 → 41,43,51）。
    let corner = rgba(sp, 2, 2)
    T.checkTrue("render: 角落是背景色（深灰、非紅）",
                corner.0 < 80 && corner.1 < 80 && corner.2 < 90 && corner.3 == 255)
    // 中心＝紅色來源。
    let center = rgba(sp, 80, 60)
    T.checkTrue("render: 中心是來源紅", center.0 > 200 && center.1 < 60 && center.2 < 60)

    // ── 整合：漸層背景 → 角落非透明、且不是來源紅 ───────────────
    let gradStyle = BackdropStyle(background: .ocean, paddingPt: 20, cornerRadiusPt: 0, shadow: false)
    guard let gradOut = BackdropRenderer.render(source: source, style: gradStyle, scale: 1) else {
        T.checkTrue("render: 漸層輸出", false); return
    }
    let gp = pixels(of: gradOut)
    let gTopLeft = rgba(gp, 3, 3)
    let gBotRight = rgba(gp, gradOut.width - 4, gradOut.height - 4)
    T.checkTrue("render: 漸層角落不透明", gTopLeft.3 == 255 && gBotRight.3 == 255)
    T.checkTrue("render: 漸層角落非來源紅（藍綠系）", gTopLeft.2 > gTopLeft.0)
    T.checkTrue("render: 漸層左上右下不同色（真的有漸層）",
                gTopLeft != gBotRight)

    // ── 整合：圓角把內容角落切掉 → 內容矩形角落是背景、中心仍是來源 ──
    let roundStyle = BackdropStyle(background: .graphite, paddingPt: 20, cornerRadiusPt: 30, shadow: false)
    guard let roundOut = BackdropRenderer.render(source: source, style: roundStyle, scale: 1) else {
        T.checkTrue("render: 圓角輸出", false); return
    }
    let rp = pixels(of: roundOut)
    // 內容矩形左上角像素（padding=20,內容從 (20,20) 起；左上角在輸出左上內縮 20）——被圓角切掉＝露背景。
    let contentCorner = rgba(rp, 21, 21)
    T.checkTrue("render: 圓角切掉內容角落（露背景深灰）",
                contentCorner.0 < 80 && contentCorner.1 < 80)
    T.checkTrue("render: 圓角中心仍是來源紅", rgba(rp, 80, 60).0 > 200)

    // ── 整合：陰影開/關 → 內容外緣下方一帶變暗 ───────────────────
    let noShadow = BackdropRenderer.render(source: source,
        style: BackdropStyle(background: .white, paddingPt: 30, cornerRadiusPt: 0, shadow: false), scale: 1)!
    let withShadow = BackdropRenderer.render(source: source,
        style: BackdropStyle(background: .white, paddingPt: 30, cornerRadiusPt: 0, shadow: true), scale: 1)!
    let np = pixels(of: noShadow), wp = pixels(of: withShadow)
    // 內容下緣正下方一帶（內容 y 從 top 邊算：輸出高 140，內容佔中間 80，下緣在 y≈110 附近；
    // 取內容水平中央、內容矩形正下方 3px）。左上原點 y。
    let sx = noShadow.width / 2
    let sy = 30 + 80 + 3   // padding(top) + content height + 3
    let bright = rgba(np, sx, sy).0    // 無陰影＝白底亮
    let dim = rgba(wp, sx, sy).0       // 有陰影＝被投影壓暗
    T.checkTrue("render: 陰影讓內容下緣一帶變暗", Int(dim) < Int(bright) - 10)

    // ── 整合：真實管線——先合成標註再美化（標註色出現在放大圖中）──────
    let baseCrop = redSource(100, 100)
    let ann = Annotation(shape: .rect(CGRect(x: 20, y: 20, width: 60, height: 60)),
                         style: AnnotationStyle(color: .blue, lineWidth: 8))
    guard let composited = AnnotationRenderer.composite(objects: [ann], overCropped: baseCrop,
        selection: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1) else {
        T.checkTrue("pipeline: 合成", false); return
    }
    guard let beautified = BackdropRenderer.render(source: composited,
        style: BackdropStyle(background: .indigo, paddingPt: 24, cornerRadiusPt: 8, shadow: true), scale: 1) else {
        T.checkTrue("pipeline: 美化", false); return
    }
    T.checkEq("pipeline: 美化後放大（寬=100+48）", beautified.width, 148)
    // 掃整張找藍色標註像素（合成的矩形描邊）——確認標註被帶進美化圖。
    let bp = pixels(of: beautified)
    var blueFound = false
    var i = 0
    while i < bp.buf.count {
        let r = bp.buf[i], g = bp.buf[i+1], b = bp.buf[i+2]
        if b > 150 && r < 120 && g < 120 { blueFound = true; break }
        i += 4
    }
    T.checkTrue("pipeline: 美化圖含藍色標註（標註已烤進）", blueFound)
}
