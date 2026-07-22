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
                              counterNumbers: [UUID: Int] = [:],
                              sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)? = nil) {
        for a in objects { render(a, in: ctx, counterNumbers: counterNumbers, sourceProvider: sourceProvider) }
    }

    static func render(_ a: Annotation, in ctx: CGContext, counterNumbers: [UUID: Int],
                       sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)?) {
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
                let numberColor = a.style.color.contrastingTextCGColor
                drawLine("\(n)", fontSize: r, color: numberColor, in: ctx, centered: true,
                         baselineAt: { ascent, descent in
                             // 垂直置中：基線 = 圓心 − (ascent−descent)/2；水平置中＝centered（helper 扣半寬）
                             CGPoint(x: center.x, y: center.y - (ascent - descent) / 2) })
            }

        case .text(let origin, let string):
            drawLine(string, fontSize: a.textFontSize, color: color, in: ctx,
                     baselineAt: { ascent, descent in
                         CGPoint(x: origin.x, y: origin.y + descent) })

        case .freehand(let pts), .highlighter(let pts):
            guard let path = AnnotationGeometry.smoothedPath(points: pts) else { break }
            if case .highlighter = a.shape {
                // 螢光筆：加寬×2、40% 不透明、multiply——壓在文字上不糊（spec）
                ctx.setBlendMode(.multiply)
                ctx.setAlpha(0.4)
            }
            ctx.setLineWidth(a.effectiveStrokeWidth)
            ctx.addPath(path)
            ctx.strokePath()

        case .pixelate(let rect):
            drawPixelate(rect: rect, blockSize: a.pixelateBlockSize, in: ctx, sourceProvider: sourceProvider)
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

    /// 非破壞馬賽克：從 provider 取「原始凍結影像」該區像素 → 縮小 1/block →
    /// nearest-neighbor 放大畫回（純 CG，免 CIFilter）。取不到底圖＝半透明灰佔位。
    private static func drawPixelate(rect: CGRect, blockSize: CGFloat, in ctx: CGContext,
                                     sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)?) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        // 與可取樣範圍取交集：矩形超出底圖時只畫交集，避免 crop 縮小卻鋪滿整個 rect 造成拉伸
        //（多螢幕拖過邊界的情境；總審查 Minor）。provider 回 nil 仍走灰佔位。
        guard let (crop, drawRect) = sourceProvider?(rect), drawRect.width >= 1, drawRect.height >= 1 else {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.6))
            ctx.fill(rect)
            return
        }
        let tinyW = max(1, Int(drawRect.width / blockSize))
        let tinyH = max(1, Int(drawRect.height / blockSize))
        guard let tinyCtx = CGContext(
            data: nil, width: tinyW, height: tinyH, bitsPerComponent: 8, bytesPerRow: 0,
            space: crop.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        tinyCtx.interpolationQuality = .low    // 縮小取平均
        tinyCtx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(tinyW), height: CGFloat(tinyH)))
        guard let tiny = tinyCtx.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none       // 放大用 nearest-neighbor → 方格
        ctx.draw(tiny, in: drawRect)
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
                                 counterNumbers: [UUID: Int] = [:],
                                 sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)? = nil) -> CGImage? {
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
        render(objects, in: ctx, counterNumbers: counterNumbers, sourceProvider: sourceProvider)
        return ctx.makeImage()
    }
}
