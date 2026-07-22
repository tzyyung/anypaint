import CoreGraphics
import Foundation

/// 單一像素取色（純 CoreGraphics、可 headless 測試）。
///
/// 為什麼繞一手 1×1 context：CGImage 的像素格式因來源而異（ScreenCaptureKit 常是
/// BGRA，byte order／premultiply 也可能不同），直接讀 dataProvider 得自己分辨所有
/// 格式。把目標像素「畫」進固定格式（RGBA8、sRGB）的 1×1 buffer 再讀 bytes，
/// 由 CoreGraphics 負責格式與色彩空間轉換，來源是什麼都對。
public enum ColorSampler {

    /// 讀取影像中單一像素的 RGB（左上原點像素座標）。座標越界回 nil。
    /// 全不透明來源（截圖）下 premultiplied 不失真；輸出為 sRGB 值。
    public static func sampleRGB(image: CGImage, x: Int, y: Int)
        -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            // 把整張圖畫進 1×1 context：平移讓像素 (x, y)（左上原點）正好落在唯一的
            // context 像素上。context 繪圖座標是左下原點：像素列 y 佔繪圖空間
            // [R.maxY-(y+1), R.maxY-y)，要等於 [0,1) → R.minY = y - (height-1)。
            ctx.draw(image, in: CGRect(x: -CGFloat(x),
                                       y: CGFloat(y) - CGFloat(image.height - 1),
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return nil }
        return (r: pixel[0], g: pixel[1], b: pixel[2])
    }

    /// "#3A6FF2"（大寫）。
    public static func hexString(r: UInt8, g: UInt8, b: UInt8) -> String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// "rgb(58, 111, 242)"。
    public static func rgbString(r: UInt8, g: UInt8, b: UInt8) -> String {
        "rgb(\(r), \(g), \(b))"
    }
}
