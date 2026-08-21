import Foundation
import CoreGraphics

/// 把來源影像（已合成標註的截圖）畫到裝飾背景上，回傳放大後的新圖。
/// 純 CoreGraphics，可在 selftest 以離屏 context 驗像素。
public enum BackdropRenderer {

    /// 產生美化後的影像。
    /// - source：要美化的內容（像素圖；通常＝截圖選區＋標註合成後）。
    /// - style：背景/padding/圓角/陰影。
    /// - scale：點→像素倍率（padding、圓角以點指定，這裡換成像素）。
    public static func render(source: CGImage, style: BackdropStyle, scale: CGFloat) -> CGImage? {
        let srcSize = CGSize(width: source.width, height: source.height)
        let out = BackdropLayout.outputSize(sourcePixelSize: srcSize, paddingPt: style.paddingPt, scale: scale)
        let w = Int(out.width.rounded()), h = Int(out.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        // 1) 背景（純色或漸層；漸層由左上→右下）
        drawBackground(style.background, in: canvas, ctx: ctx)

        // 2) 內容矩形＋圓角路徑
        let content = BackdropLayout.contentRect(sourcePixelSize: srcSize, paddingPt: style.paddingPt, scale: scale)
        let radius = BackdropLayout.cornerRadiusPx(cornerRadiusPt: style.cornerRadiusPt,
                                                   sourcePixelSize: srcSize, scale: scale)
        let clip = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 3) 陰影：先用圓角路徑填一層（帶 shadow）當投影底，再把內容畫上去。
        if style.shadow {
            ctx.saveGState()
            let blur = max(8, 24 * scale)
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(clip)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))   // 被內容蓋住,只為投影
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 4) 內容：圓角裁切後畫來源。
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(source, in: content)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func drawBackground(_ bg: BackdropBackground, in rect: CGRect, ctx: CGContext) {
        if let solid = bg.solidColor {
            ctx.setFillColor(solid)
            ctx.fill(rect)
            return
        }
        guard let colors = bg.gradientColors, colors.count >= 2,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: [0, 1]) else {
            // 退路：漸層建不起來就填第一色（不留透明背景）。
            ctx.setFillColor(bg.gradientColors?.first ?? CGColor(gray: 0.5, alpha: 1))
            ctx.fill(rect)
            return
        }
        // 左上 → 右下（CGContext 左下原點：起點 (minX, maxY)、終點 (maxX, minY)）。
        ctx.saveGState()
        ctx.addRect(rect); ctx.clip()
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
        ctx.restoreGState()
    }
}
