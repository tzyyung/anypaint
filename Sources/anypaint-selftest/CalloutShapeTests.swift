import AnypaintKit
import CoreGraphics
import Foundation

/// #5 圓角矩形 roundedRect ＋ 對話框 callout：純幾何、shape 行為、渲染有像素。
nonisolated func calloutShapeTests() {
    let style = AnnotationStyle(color: .red, lineWidth: 4)

    // 1) cornerRadius：短邊 1/4、上限 28。
    T.checkEq("cornerRadius: 小框=短邊1/4",
              AnnotationGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 100, height: 40)), 10)
    T.checkEq("cornerRadius: 大框夾到上限 28",
              AnnotationGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 400, height: 400)), 28)
    T.checkTrue("cornerRadius: 永不超過短邊一半",
                AnnotationGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 8, height: 8)) <= 4)

    // 2) calloutBaseWidth：短邊 0.3、夾 [12,48]。
    T.checkEq("baseWidth: 中框=短邊0.3",
              AnnotationGeometry.calloutBaseWidth(for: CGRect(x: 0, y: 0, width: 200, height: 100)), 30)
    T.checkEq("baseWidth: 小框夾到下限 12",
              AnnotationGeometry.calloutBaseWidth(for: CGRect(x: 0, y: 0, width: 20, height: 20)), 12)
    T.checkEq("baseWidth: 大框夾到上限 48",
              AnnotationGeometry.calloutBaseWidth(for: CGRect(x: 0, y: 0, width: 800, height: 800)), 48)

    // 3) calloutTailBase：apex 在 body 內 → nil。
    let body = CGRect(x: 100, y: 100, width: 200, height: 100)   // x:100..300, y:100..200
    T.checkTrue("tailBase: apex 在 body 內 → nil",
                AnnotationGeometry.calloutTailBase(body: body, apex: CGPoint(x: 200, y: 150), baseWidth: 30) == nil)

    // 4) apex 正下方（y<minY，view 座標底邊）→ 貼底邊、基點沿 x、y 皆=minY。
    if let (b1, b2) = AnnotationGeometry.calloutTailBase(body: body, apex: CGPoint(x: 200, y: 40), baseWidth: 30) {
        T.checkEq("tailBase: 正下方貼底邊 b1", b1, CGPoint(x: 185, y: 100))
        T.checkEq("tailBase: 正下方貼底邊 b2", b2, CGPoint(x: 215, y: 100))
    } else { T.checkTrue("tailBase: 正下方應有尾巴", false) }

    // 5) apex 正左方 → 貼左邊、基點沿 y、x 皆=minX。
    if let (b1, b2) = AnnotationGeometry.calloutTailBase(body: body, apex: CGPoint(x: 20, y: 150), baseWidth: 30) {
        T.checkEq("tailBase: 正左方貼左邊 b1", b1, CGPoint(x: 100, y: 135))
        T.checkEq("tailBase: 正左方貼左邊 b2", b2, CGPoint(x: 100, y: 165))
    } else { T.checkTrue("tailBase: 正左方應有尾巴", false) }

    // 6) apex 右上斜角，水平溢出 > 垂直溢出 → 貼右邊（垂直邊）。
    //    apex=(500,210): dxOut=500-300=200, dyOut=210-200=10 → dxOut 勝 → 右邊 x=maxX=300。
    if let (b1, b2) = AnnotationGeometry.calloutTailBase(body: body, apex: CGPoint(x: 500, y: 210), baseWidth: 30) {
        T.checkEq("tailBase: 右上斜角貼右邊 x", b1.x, 300)
        T.checkEq("tailBase: 右上斜角貼右邊 x2", b2.x, 300)
    } else { T.checkTrue("tailBase: 斜角應有尾巴", false) }

    // 7) 基座夾限：apex 靠近角落，基座不越出邊界。
    //    apex 正下、x=290（靠右）→ 中心夾到 maxX-half=285 → 基點 270..300。
    if let (b1, b2) = AnnotationGeometry.calloutTailBase(body: body, apex: CGPoint(x: 290, y: 40), baseWidth: 30) {
        T.checkEq("tailBase: 夾限右緣 b1", b1, CGPoint(x: 270, y: 100))
        T.checkEq("tailBase: 夾限右緣 b2", b2, CGPoint(x: 300, y: 100))
    } else { T.checkTrue("tailBase: 夾限應有尾巴", false) }

    // 8) defaultCalloutApex：底邊左側 1/4、往下拉。
    let apex = AnnotationGeometry.defaultCalloutApex(for: body)
    T.checkEq("defaultApex: x=左側1/4", apex.x, 150)
    T.checkTrue("defaultApex: y 在底邊下方", apex.y < body.minY)

    // 9) twoPointShape：roundedRect / callout。
    if case .roundedRect(let r)? = AnnotationInput.twoPointShape(tool: .roundedRect,
        from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 100), pixelScale: 2) {
        T.checkEq("twoPoint: roundedRect 正規化", r, CGRect(x: 100, y: 100, width: 200, height: 100))
    } else { T.checkTrue("twoPoint: roundedRect", false) }
    if case .callout(let cb, let ct)? = AnnotationInput.twoPointShape(tool: .callout,
        from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200), pixelScale: 2) {
        T.checkEq("twoPoint: callout body", cb, CGRect(x: 100, y: 100, width: 200, height: 100))
        T.checkEq("twoPoint: callout 預設尾巴", ct, AnnotationGeometry.defaultCalloutApex(for: cb))
    } else { T.checkTrue("twoPoint: callout", false) }

    // 10) roundedRect shape 行為：bounds/isCornerResizable/move/scaled/hitTest。
    let rr = Annotation(shape: .roundedRect(CGRect(x: 10, y: 10, width: 40, height: 30)), style: style)
    T.checkEq("roundedRect: bounds=rect", rr.bounds, CGRect(x: 10, y: 10, width: 40, height: 30))
    T.checkTrue("roundedRect: 角點可縮放", rr.isCornerResizable)
    T.checkTrue("roundedRect: 命中框內", rr.hitTest(CGPoint(x: 30, y: 25)))
    T.checkTrue("roundedRect: 框外遠處不命中", !rr.hitTest(CGPoint(x: 500, y: 500)))
    var rrMoved = rr; rrMoved.move(by: CGVector(dx: 5, dy: 7))
    if case .roundedRect(let r) = rrMoved.shape { T.checkEq("roundedRect: move", r.origin, CGPoint(x: 15, y: 17)) }
    else { T.checkTrue("roundedRect: move 型別", false) }
    var rrScaled = rr
    rrScaled.scaled(from: CGRect(x: 10, y: 10, width: 40, height: 30),
                    to: CGRect(x: 10, y: 10, width: 80, height: 60))
    if case .roundedRect(let r) = rrScaled.shape {
        T.checkEq("roundedRect: scaled", r, CGRect(x: 10, y: 10, width: 80, height: 60))
    } else { T.checkTrue("roundedRect: scaled 型別", false) }

    // 11) callout shape 行為：bounds=body∪tail、move 兩者、scaled 兩者、hitTest（body＋尾端）。
    let coBody = CGRect(x: 100, y: 100, width: 100, height: 60)
    let coTail = CGPoint(x: 120, y: 40)   // body 下方
    let co = Annotation(shape: .callout(body: coBody, tail: coTail), style: style)
    T.checkEq("callout: bounds 含尾巴", co.bounds, coBody.union(CGRect(origin: coTail, size: .zero)))
    T.checkTrue("callout: 命中 body", co.hitTest(CGPoint(x: 150, y: 130)))
    T.checkTrue("callout: 命中尾端附近", co.hitTest(CGPoint(x: 120, y: 41)))
    T.checkTrue("callout: 遠處不命中", !co.hitTest(CGPoint(x: 500, y: 500)))
    var coMoved = co; coMoved.move(by: CGVector(dx: 10, dy: -5))
    if case .callout(let b, let t) = coMoved.shape {
        T.checkEq("callout: move body", b.origin, CGPoint(x: 110, y: 95))
        T.checkEq("callout: move tail", t, CGPoint(x: 130, y: 35))
    } else { T.checkTrue("callout: move 型別", false) }
    var coScaled = co
    coScaled.scaled(from: coBody, to: CGRect(x: 100, y: 100, width: 200, height: 120))   // 2x
    if case .callout(let b, let t) = coScaled.shape {
        T.checkEq("callout: scaled body", b, CGRect(x: 100, y: 100, width: 200, height: 120))
        // tail 隨同映射：x 120→(120-100)*2+100=140；y 40→(40-100)*2+100=-20
        T.checkEq("callout: scaled tail", t, CGPoint(x: 140, y: -20))
    } else { T.checkTrue("callout: scaled 型別", false) }

    // 12) 渲染：roundedRect / callout 各自畫出非透明像素（含尾巴段）。
    func litPixels(_ objects: [Annotation], _ w: Int, _ h: Int) -> Int {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            AnnotationRenderer.render(objects, in: ctx)
        }
        var lit = 0
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 0 { lit += 1 }
        return lit
    }
    let rrRender = Annotation(shape: .roundedRect(CGRect(x: 10, y: 10, width: 60, height: 40)), style: style)
    T.checkTrue("roundedRect 渲染: 有非透明像素", litPixels([rrRender], 90, 70) > 0)
    // callout：body 在上、尾巴往下到 y≈10 → 需要夠高的畫布涵蓋尾巴段。
    let coRender = Annotation(shape: .callout(body: CGRect(x: 20, y: 60, width: 60, height: 40),
                                              tail: CGPoint(x: 40, y: 15)), style: style)
    let coLit = litPixels([coRender], 110, 120)
    let bodyOnlyLit = litPixels([Annotation(shape: .roundedRect(CGRect(x: 20, y: 60, width: 60, height: 40)),
                                            style: style)], 110, 120)
    T.checkTrue("callout 渲染: 有非透明像素", coLit > 0)
    T.checkTrue("callout 渲染: 比純圓角框多（尾巴段有畫）", coLit > bodyOnlyLit)
}
