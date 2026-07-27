import CoreGraphics
import Foundation

/// RGBA8、row-major、左上原點的原始像素緩衝。滾動截圖核心的統一影像型別：
/// 不用 NSImage/CGImage 做運算——拼接是 memcpy 等級的操作，包裝型別只會擋路。
public struct PixelBuffer {
    public let width: Int
    public private(set) var height: Int
    public var bytes: [UInt8]          // count == width*height*4

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width; self.height = height; self.bytes = bytes
    }

    /// 統一重繪成 RGBA8——CGImage 的原生格式五花八門（BGRA、灰階、預乘與否），
    /// 全部經一次 CGContext 正規化，之後的逐位元組運算才有一致意義。
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, bytes: data)
    }

    public func makeCGImage() -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> PixelBuffer {
        precondition(x >= 0 && y >= 0 && x + w <= width && y + h <= height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let dstRow = w * 4
        for r in 0..<h {
            let s = ((y + r) * width + x) * 4
            out.replaceSubrange(r * dstRow..<(r + 1) * dstRow, with: bytes[s..<s + dstRow])
        }
        return PixelBuffer(width: w, height: h, bytes: out)
    }
}

/// 灰階浮點面（luma = 0.299R+0.587G+0.114B）。matcher 全程在 luma 上運算：
/// 單通道省 4 倍記憶體頻寬，ZNCC 對灰階已足夠鑑別。
public struct LumaPlane {
    public let width: Int
    public let height: Int
    public var v: [Float]

    public init(width: Int, height: Int, v: [Float]) {
        precondition(v.count == width * height)
        self.width = width; self.height = height; self.v = v
    }

    public init(_ p: PixelBuffer) {
        var out = [Float](repeating: 0, count: p.width * p.height)
        for i in 0..<(p.width * p.height) {
            let o = i * 4
            out[i] = 0.299 * Float(p.bytes[o]) + 0.587 * Float(p.bytes[o+1]) + 0.114 * Float(p.bytes[o+2])
        }
        self.init(width: p.width, height: p.height, v: out)
    }

    /// 2×2 box 降採樣（金字塔用）。奇數尺寸捨去最後一列/欄。
    public func downsampled() -> LumaPlane {
        let w = width / 2, h = height / 2
        var out = [Float](repeating: 0, count: w * h)
        for r in 0..<h {
            for c in 0..<w {
                let a = v[(r*2) * width + c*2], b = v[(r*2) * width + c*2 + 1]
                let d = v[(r*2+1) * width + c*2], e = v[(r*2+1) * width + c*2 + 1]
                out[r * w + c] = (a + b + d + e) * 0.25
            }
        }
        return LumaPlane(width: w, height: h, v: out)
    }

    public func cropped(top: Int, bottom: Int, left: Int, right: Int) -> LumaPlane {
        let w = width - left - right, h = height - top - bottom
        precondition(w > 0 && h > 0)
        var out = [Float](repeating: 0, count: w * h)
        for r in 0..<h {
            let s = (top + r) * width + left
            out.replaceSubrange(r * w..<(r + 1) * w, with: v[s..<s + w])
        }
        return LumaPlane(width: w, height: h, v: out)
    }

    /// 垂直翻轉。負向（回捲）匹配 = 翻轉兩張圖跑正向搜尋再把 dy 取負——
    /// 一條程式路徑吃雙向（spec §7.1 滾輪方向閘門的實作機制）。
    public func flippedVertically() -> LumaPlane {
        var out = [Float](repeating: 0, count: v.count)
        for r in 0..<height {
            out.replaceSubrange(r * width..<(r + 1) * width,
                                with: v[(height - 1 - r) * width..<(height - r) * width])
        }
        return LumaPlane(width: width, height: height, v: out)
    }
}

/// 四向靜態帶內縮量。
public struct BandInsets: Equatable {
    public var top: Int; public var bottom: Int; public var left: Int; public var right: Int
    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let zero = BandInsets()
}

/// 選區（AppKit 全域點座標、左下原點）→ SCStream 幾何（spec §4 座標鏈）。
/// 三步缺一不可：像素格對齊（防半點偏移的重採樣模糊）→ 螢幕相對 → Y 翻轉（上左原點）。
/// width/height 必須顯式給 stream，否則輸出被縮進預設 1920×1080（SDK 行為，審查證實）。
public enum ScrollCoords {
    public static func streamGeometry(selectionGlobal: CGRect,
                                      screenFrameGlobal: CGRect,
                                      scale: CGFloat) -> (sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        // 1) 對齊像素格：origin 向下取整、size 向上取整到 1/scale 的倍數
        let unit = 1.0 / scale
        let alignedX = (selectionGlobal.minX / unit).rounded(.down) * unit
        let alignedY = (selectionGlobal.minY / unit).rounded(.down) * unit
        let alignedMaxX = (selectionGlobal.maxX / unit).rounded(.up) * unit
        let alignedMaxY = (selectionGlobal.maxY / unit).rounded(.up) * unit
        // 2) 螢幕相對（仍左下原點）
        let relX = alignedX - screenFrameGlobal.minX
        let relYBottom = alignedY - screenFrameGlobal.minY
        let w = alignedMaxX - alignedX
        let h = alignedMaxY - alignedY
        // 3) Y 翻轉成上左原點（sourceRect 單位是點、display logical 座標）
        let relYTop = screenFrameGlobal.height - relYBottom - h
        return (CGRect(x: relX, y: relYTop, width: w, height: h),
                Int((w * scale).rounded()), Int((h * scale).rounded()))
    }

    /// 從螢幕 frame 清單裡挑出含指定點的那一個，回傳索引。
    ///
    /// 為什麼不用 `NSScreen.main`：它的語意是「含**鍵盤焦點視窗**的螢幕」，而 anypaint 是
    /// accessory app（LSUIElement）平時沒有 key window——在副螢幕按快鍵時它會指向錯誤的螢幕，
    /// 甚至回 nil 讓整個流程直接 no-op（commit a77aeb3 修的「無主螢幕」症狀就是這個）。
    ///
    /// 滾動截圖用**滑鼠所在螢幕**判定是安全的：這個功能本來就要求滑鼠留在選區內才收得到滾輪，
    /// 所以滑鼠必然在目標螢幕上。
    ///
    /// 邊界（螢幕相鄰處的點只會屬於其中一個）：`CGRect.contains` 對右／上邊界回 false，
    /// 所以相鄰螢幕不會重複命中。點落在所有螢幕之外（可能發生在螢幕熱插拔的瞬間）回 nil，
    /// 由呼叫端決定退路。
    /// - Parameter mouseGlobal: 全域座標的滑鼠位置（左下原點，與 `NSScreen.frame` 同座標系）。
    public static func screenIndex(containing mouseGlobal: CGPoint,
                                   screenFrames: [CGRect]) -> Int? {
        screenFrames.firstIndex { $0.contains(mouseGlobal) }
    }
}
