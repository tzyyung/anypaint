import Foundation
import CoreGraphics
import CoreText
import CoreImage
import CoreImage.CIFilterBuiltins

/// 把標註畫進任意 CGContext。畫面預覽（SelectionView.draw）與最終擷取合成
/// 共用這一份 → 所見即所存。座標原點/翻轉由呼叫端的 context 決定，
/// 這裡只按給定座標畫路徑（階段 1 的形狀對翻轉不敏感）。
public enum AnnotationRenderer {

    /// 依陣列順序（＝z-order）逐一渲染。counterNumbers：序號物件的編號查表
    /// （由 AnnotationDocument.counterNumber(for:) 產生；預設空＝序號只畫圓不畫字）。
    public static func render(_ objects: [Annotation], in ctx: CGContext,
                              counterNumbers: [UUID: Int] = [:],
                              sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)? = nil) {
        // 聚光是畫布級：先把「畫布其餘變暗、只留所有 spotlight 矩形明亮」畫在最底,再疊其他標註。
        let spots = objects.compactMap { a -> CGRect? in
            if case .spotlight(let r) = a.shape { return r } else { return nil }
        }
        if !spots.isEmpty { drawSpotlightDim(rects: spots, in: ctx) }
        for a in objects { render(a, in: ctx, counterNumbers: counterNumbers, sourceProvider: sourceProvider) }
    }

    /// 聚光遮暗：畫布（＝目前 clip 外框）扣掉所有 spotlight 矩形,其餘鋪半透明黑（even-odd 挖洞）。
    private static func drawSpotlightDim(rects: [CGRect], in ctx: CGContext) {
        let canvas = ctx.boundingBoxOfClipPath
        guard canvas.width > 0, canvas.height > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.beginPath()
        ctx.addRect(canvas)
        for r in rects { ctx.addRect(r) }
        ctx.fillPath(using: .evenOdd)   // 外框 XOR 各洞 → 洞內不填（明亮）
        ctx.restoreGState()
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

        case .blur(let rect):
            drawBlur(rect: rect, radiusPt: a.blurRadius, in: ctx, sourceProvider: sourceProvider)

        case .spotlight:
            break   // 效果＝畫布級遮暗,已在 render(_:) 開頭統一畫；這裡不畫本體。

        case .polygon(let pts, let closed):
            guard let first = pts.first else { break }
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            if closed { ctx.closePath() }
            ctx.strokePath()

        case .measure(let from, let to, let pixelScale):
            let box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                             width: abs(to.x - from.x), height: abs(to.y - from.y))
            let lines = AnnotationGeometry.measurementLines(from: from, to: to,
                                                            pixelScale: pixelScale)
            ctx.saveGState()
            // 虛線框：與矩形工具在視覺上分得開，也暗示這是「量」不是「圈」。
            ctx.setLineDash(phase: 0, lengths: [max(4, lw * 2), max(3, lw * 1.5)])
            ctx.stroke(box)
            // 對角線＝使用者實際拖的那條線。只在有對角線讀數時畫（單軸或極小框都不畫），
            // 用更細更淡的線，不跟框線搶注意力。
            if lines.count > 1 {
                ctx.setLineWidth(max(1, lw * 0.6))
                ctx.setAlpha(0.7)
                ctx.move(to: from)
                ctx.addLine(to: to)
                ctx.strokePath()
            }
            ctx.restoreGState()
            drawMeasurementLabel(lines, in: box, fill: color,
                                 textColor: a.style.color.contrastingTextCGColor,
                                 fontSize: a.textFontSize, in: ctx)
        }
    }

    /// 測量讀數標籤：色塊底＋對比色字，畫在**框中央**。
    ///
    /// 中央而不是框外上方：renderer 不知道畫布邊界（context 可能是任意大小），畫在框外就可能
    /// 被裁掉；而量間距時細長條的中央本來就是視覺焦點，這也是測量標註的慣例。
    /// 底色沿用 counter 的做法（色塊＋contrastingTextCGColor），淺色字在淺背景上才看得見。
    private static func drawMeasurementLabel(_ texts: [String], in rect: CGRect,
                                             fill: CGColor, textColor: CGColor,
                                             fontSize: CGFloat, in ctx: CGContext) {
        guard !texts.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let lines: [(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] =
            texts.map { text in
                let attr = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
                ])
                let ctLine = CTLineCreateWithAttributedString(attr)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
                return (ctLine, w, ascent, descent)
            }
        let pad = max(3, fontSize * 0.25)
        let lineHeight = lines.map { $0.ascent + $0.descent }.max() ?? fontSize
        let boxWidth = (lines.map(\.width).max() ?? 0) + pad * 2
        let boxHeight = lineHeight * CGFloat(lines.count) + pad * 2
        let box = CGRect(x: rect.midX - boxWidth / 2, y: rect.midY - boxHeight / 2,
                         width: boxWidth, height: boxHeight)
        ctx.saveGState()
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        // 由上往下排：第一行貼 box 頂緣。基線算法比照 drawLine 的 text 案例（+descent），
        // 兩種 context（畫面預覽與最終合成）的翻轉都已由既有 text 標註驗證過。
        for (index, item) in lines.enumerated() {
            let baselineY = box.maxY - pad - lineHeight * CGFloat(index + 1) + item.descent
            ctx.textPosition = CGPoint(x: box.minX + pad, y: baselineY)
            CTLineDraw(item.line, ctx)
        }
        ctx.restoreGState()
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

    /// 非破壞高斯模糊：取原始底圖該區 → CIGaussianBlur → 畫回。取不到＝半透明灰佔位（同 pixelate）。
    /// radiusPt 為點,轉成 crop 的像素半徑（crop 是像素、drawRect 是點）。clampedToExtent 避免邊緣透明。
    private static func drawBlur(rect: CGRect, radiusPt: CGFloat, in ctx: CGContext,
                                sourceProvider: ((CGRect) -> (image: CGImage, drawRect: CGRect)?)?) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        guard let (crop, drawRect) = sourceProvider?(rect), drawRect.width >= 1, drawRect.height >= 1 else {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.6))
            ctx.fill(rect)
            return
        }
        let pxPerPt = CGFloat(crop.width) / drawRect.width
        let radiusPx = max(1, radiusPt * pxPerPt)
        let source = CIImage(cgImage: crop)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source.clampedToExtent()   // 夾住邊緣,模糊才不會吃進透明
        filter.radius = Float(radiusPx)
        guard let out = filter.outputImage else { return }
        let ciCtx = CIContext(options: nil)
        guard let blurred = ciCtx.createCGImage(out, from: source.extent) else { return }   // 裁回原尺寸
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(blurred, in: drawRect)
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
