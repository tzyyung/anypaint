import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// 影像轉換（非矩形裁切、透視校正）。純幾何部分進 selftest；CG/CI 產圖部分薄殼、實機驗。
/// 座標約定：`viewPoint` 是 overlay 點座標（左下原點）；`imagePixel` 是 snapshot 像素座標（左上原點,
/// 與 `CGImage` 像素格一致）。CoreImage 的 `CIImage` 是左下原點——warp 時內部再翻。
public enum ImageTransform {

    // MARK: 純幾何（可測）

    /// overlay 點座標（左下原點）→ snapshot 像素座標（左上原點）。
    public static func imagePixel(viewPoint p: CGPoint, viewHeight: CGFloat, scale: CGFloat) -> CGPoint {
        CGPoint(x: p.x * scale, y: (viewHeight - p.y) * scale)
    }

    /// 由四角推估拉直後的矩形尺寸（像素）：寬＝上下兩邊長平均、高＝左右兩邊長平均。
    /// corners 順序＝[topLeft, topRight, bottomRight, bottomLeft]（任何一致座標系皆可，只用邊長）。
    public static func rectifiedSize(corners: [CGPoint]) -> CGSize {
        guard corners.count == 4 else { return .zero }
        let tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3]
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let w = ((dist(tl, tr) + dist(bl, br)) / 2).rounded()
        let h = ((dist(tl, bl) + dist(tr, br)) / 2).rounded()
        return CGSize(width: max(1, w), height: max(1, h))
    }

    /// 把任意順序的 4 點依位置排成 [topLeft, topRight, bottomRight, bottomLeft]
    /// （像素座標,左上原點,y 向下）。用 x±y 判角：tl 最小 x+y、br 最大 x+y、tr 最大 x−y、bl 最小 x−y。
    /// 非 4 點回原陣列。
    public static func orderedCorners(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count == 4 else { return pts }
        let tl = pts.min { $0.x + $0.y < $1.x + $1.y }!
        let br = pts.max { $0.x + $0.y < $1.x + $1.y }!
        let tr = pts.max { $0.x - $0.y < $1.x - $1.y }!
        let bl = pts.min { $0.x - $0.y < $1.x - $1.y }!
        return [tl, tr, br, bl]
    }

    /// 多邊形（像素座標,左上原點）的整數外接框——裁切輸出尺寸。
    public static func pixelBoundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    // MARK: CG/CI 產圖（薄殼,實機驗）

    /// 非矩形裁切：以多邊形為遮罩,框外透明,裁到外接框。
    /// - source: 完整 snapshot 像素影像（左上原點）。
    /// - imagePolygon: 多邊形頂點,snapshot 像素座標（左上原點）。
    public static func maskedCrop(source: CGImage, imagePolygon: [CGPoint]) -> CGImage? {
        guard imagePolygon.count >= 3 else { return nil }
        let w = source.width, h = source.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // context 左下原點 → 多邊形 y 翻轉；來源不翻（draw 會擺正）。
        ctx.beginPath()
        let flipped = imagePolygon.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) }
        ctx.move(to: flipped[0])
        for p in flipped.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.clip()
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let masked = ctx.makeImage() else { return nil }
        let bbox = pixelBoundingBox(imagePolygon)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard bbox.width >= 1, bbox.height >= 1 else { return nil }
        return masked.cropping(to: bbox)   // cropping 用左上原點,與 imagePolygon 同系
    }

    /// 透視校正：四角 quad → 拉直成正矩形。
    /// - imageCorners: [topLeft, topRight, bottomRight, bottomLeft]，snapshot 像素座標（左上原點）。
    public static func perspectiveCorrect(source: CGImage, imageCorners: [CGPoint]) -> CGImage? {
        guard imageCorners.count == 4 else { return nil }
        let h = CGFloat(source.height)
        let ci = CIImage(cgImage: source)
        // CIImage 左下原點 → 像素座標（左上）翻 y。
        func ciPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ci
        filter.topLeft = ciPoint(imageCorners[0])
        filter.topRight = ciPoint(imageCorners[1])
        filter.bottomRight = ciPoint(imageCorners[2])
        filter.bottomLeft = ciPoint(imageCorners[3])
        filter.crop = true
        guard let out = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(out, from: out.extent)
    }
}
