import Foundation
import CoreGraphics
import CoreText

/// 把標註畫進任意 CGContext。畫面預覽（SelectionView.draw）與最終擷取合成
/// 共用這一份 → 所見即所存。座標原點/翻轉由呼叫端的 context 決定，
/// 這裡只按給定座標畫路徑（階段 1 的形狀對翻轉不敏感）。
public enum AnnotationRenderer {

    /// 依陣列順序（＝z-order）逐一渲染。counterNumbers：序號物件的編號查表
    /// （由 AnnotationDocument.counterNumber(for:) 產生；預設空＝序號只畫圓不畫字）。
    public static func render(_ objects: [Annotation], in ctx: CGContext,
                              counterNumbers: [UUID: Int] = [:]) {
        for a in objects { render(a, in: ctx, counterNumbers: counterNumbers) }
    }

    static func render(_ a: Annotation, in ctx: CGContext, counterNumbers: [UUID: Int]) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let color = a.style.color.cgColor
        let lw = a.style.lineWidth
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch a.shape {
        case .rect(let r):
            ctx.stroke(r)

        case .ellipse(let r):
            ctx.strokeEllipse(in: r)

        case .line(let from, let to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .arrow(let from, let to):
            // 線段畫到箭頭底部，頭部用實心三角（頭長 = max(10, 線寬×3)，spec）。
            let head = max(10, lw * 3)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let base = CGPoint(x: to.x - head * cos(angle), y: to.y - head * sin(angle))
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            let half = head * 0.5
            let p1 = CGPoint(x: base.x - half * sin(angle), y: base.y + half * cos(angle))
            let p2 = CGPoint(x: base.x + half * sin(angle), y: base.y - half * cos(angle))
            ctx.move(to: to)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .counter(let center):
            let r = a.counterRadius
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                       width: r * 2, height: r * 2))
            if let n = counterNumbers[a.id] {
                let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                drawLine("\(n)", fontSize: r, color: white, in: ctx, centered: true,
                         baselineAt: { ascent, descent in
                             // 垂直置中：基線 = 圓心 − (ascent−descent)/2；水平置中＝centered（helper 扣半寬）
                             CGPoint(x: center.x, y: center.y - (ascent - descent) / 2) })
            }

        case .text(let origin, let string):
            drawLine(string, fontSize: a.textFontSize, color: color, in: ctx,
                     baselineAt: { ascent, descent in
                         CGPoint(x: origin.x, y: origin.y + descent) })
        }
    }

    /// 單行文字畫進 context（CoreText）。baselineAt 依 ascent/descent 回傳「錨點」：
    /// text 案例回傳左緣基線；counter 案例回傳圓心（此時 helper 水平置中＝扣掉半寬）。
    private static func drawLine(_ string: String, fontSize: CGFloat, color: CGColor,
                                 in ctx: CGContext, centered: Bool = false,
                                 baselineAt: (CGFloat, CGFloat) -> CGPoint) {
        guard !string.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        var anchor = baselineAt(ascent, descent)
        if centered { anchor.x -= width / 2 }
        ctx.saveGState()
        ctx.textPosition = anchor
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 把標註合成到「已裁切的選取框影像」上，回傳新圖（尺寸不變）。
    /// - selection：凍結影像點座標的選取框（左下原點）。
    /// - scale：點→像素倍率（Retina 2x 等）。
    /// CGBitmapContext 與非翻轉 view 同為左下原點，所以只需 scale＋平移、不需翻轉；
    /// 裁切階段的 Y 翻轉已由 CoordinateUtils.pixelCropRect 處理。
    /// 注意：pixelCropRect 有 .integral 取整，與 selection 的平移可能有 <1px 誤差，可接受。
    public static func composite(objects: [Annotation],
                                 overCropped cropped: CGImage,
                                 selection: CGRect,
                                 scale: CGFloat,
                                 counterNumbers: [UUID: Int] = [:]) -> CGImage? {
        let w = cropped.width, h = cropped.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)
        render(objects, in: ctx, counterNumbers: counterNumbers)
        return ctx.makeImage()
    }
}
