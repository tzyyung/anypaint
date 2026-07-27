import CoreGraphics
import Foundation
import AnypaintKit

/// 合成虛擬長頁面：從已知 y 偏移裁視窗當連續影格，位移答案已知。
/// 全部決定性（seed 固定 → 輸出固定），CI 可重現。
enum SyntheticPage {
    /// 線性同餘偽隨機（決定性；不可用系統隨機源）。
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    }

    /// 產生 width×height 的「文字狀」頁面：每行由隨機段落色塊組成，行高 14、行距 6。
    static func make(width: Int, height: Int, seed: UInt64) -> PixelBuffer {
        var rng = LCG(seed: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)   // 白底
        var y = 0
        while y < height {
            let lineH = 14
            var x = rng.int(30)                       // 隨機縮排
            while x < width - 20 {
                let w = 20 + rng.int(80)              // 隨機「字詞」寬
                let g = UInt8(30 + rng.int(120))      // 隨機深灰
                for r in y..<min(y + lineH, height) {
                    for c in x..<min(x + w, width) {
                        let o = (r * width + c) * 4
                        bytes[o] = g; bytes[o+1] = g; bytes[o+2] = g   // alpha 留 255
                    }
                }
                x += w + 8 + rng.int(20)              // 字距
            }
            y += lineH + 6
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 從頁面 y 偏移裁一個視窗（模擬選區影格）。
    static func window(_ page: PixelBuffer, y: Int, height: Int) -> PixelBuffer {
        precondition(y >= 0 && y + height <= page.height)
        let rowBytes = page.width * 4
        let slice = Array(page.bytes[(y * rowBytes)..<((y + height) * rowBytes)])
        return PixelBuffer(width: page.width, height: height, bytes: slice)
    }

    /// 把固定帶（獨立紋理）壓進影格的頂/底/左/右——模擬固定導覽列、頁尾、捲軸欄。
    static func stamp(_ frame: inout PixelBuffer, top: Int = 0, bottom: Int = 0,
                      left: Int = 0, right: Int = 0, seed: UInt64) {
        var rng = LCG(seed: seed)
        let w = frame.width, h = frame.height
        func fill(_ rows: Range<Int>, _ cols: Range<Int>) {
            let g = UInt8(160 + rng.int(60))
            for r in rows { for c in cols {
                let o = (r * w + c) * 4
                frame.bytes[o] = g; frame.bytes[o+1] = UInt8(rng.int(40)); frame.bytes[o+2] = g
            } }
        }
        if top > 0 { fill(0..<top, 0..<w) }
        if bottom > 0 { fill((h - bottom)..<h, 0..<w) }
        if left > 0 { fill(0..<h, 0..<left) }
        if right > 0 { fill(0..<h, (w - right)..<w) }
    }

    /// 週期橫條紋理（重複紋理測資：matcher 必須判 ambiguous）。
    static func periodicStripes(width: Int, height: Int, period: Int) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for r in 0..<height where (r / (period / 2)) % 2 == 0 {
            for c in 0..<width {
                let o = (r * width + c) * 4
                bytes[o] = 60; bytes[o+1] = 60; bytes[o+2] = 60
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 等行距的「文字行」頁面：每 `period` 像素一行字塊，深底亮字（模擬終端機／留白網頁）。
    /// `period` 越大＝影格內字行越少＝越稀疏。
    ///
    /// **測資必須是物理上的純平移**：整頁的內容只由絕對 y 座標決定，開窗即得平移關係。
    /// 先前自檢用的 sparse 模式是「視窗上半永遠不畫字」，文字捲到分界線就消失——
    /// 那在物理上不是平移，任何對位演算法都必然失敗，據此調整演算法只會愈調愈錯。
    ///
    /// - Parameter identicalRows: true＝所有行 pattern 相同（病態對照組，數學上不可區分，
    ///   matcher 必須拒絕而不是挑一個週期倍數）。
    static func linedPage(width: Int, height: Int, period: Int, lineThickness: Int,
                          identicalRows: Bool) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i*4] = 28; bytes[i*4+1] = 28; bytes[i*4+2] = 28
        }
        var lineIndex = 0
        var y = 0
        while y < height {
            var lcg = LCG(seed: UInt64(bitPattern: Int64(identicalRows ? 7 : lineIndex)))
            var x = 8 + lcg.int(40)
            while x < width - 30 {
                let w = min(30 + lcg.int(110), width - 10 - x)
                let g = UInt8(150 + lcg.int(105))
                for r in y..<min(y + lineThickness, height) {
                    for c in x..<(x + w) {
                        let o = (r * width + c) * 4
                        bytes[o] = g; bytes[o+1] = g; bytes[o+2] = g
                    }
                }
                x += w + 10 + lcg.int(24)
            }
            lineIndex += 1
            y += period
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 照片類平滑紋理：低頻控制點網格＋雙線性內插，**無任何週期結構**。
    /// 用來確認結論不是只在「等行距文字」這一類內容上成立。
    static func smoothTexture(width: Int, height: Int, seed: UInt64) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var lcg = LCG(seed: seed)
        let gx = 24, gy = 40
        var grid = [Double](repeating: 0, count: (gx + 1) * (gy + 1))
        for i in 0..<grid.count { grid[i] = Double(lcg.int(1000)) / 1000.0 }
        for r in 0..<height {
            let fy = Double(r) / Double(height) * Double(gy)
            let y0 = min(gy, Int(fy)), y1 = min(gy, y0 + 1), ty = fy - Double(y0)
            for c in 0..<width {
                let fx = Double(c) / Double(width) * Double(gx)
                let x0 = min(gx, Int(fx)), x1 = min(gx, x0 + 1), tx = fx - Double(x0)
                let a = grid[y0 * (gx + 1) + x0], b = grid[y0 * (gx + 1) + x1]
                let d = grid[y1 * (gx + 1) + x0], e = grid[y1 * (gx + 1) + x1]
                let v = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
                let g = UInt8(max(0, min(255, v * 230 + 12)))
                let o = (r * width + c) * 4
                bytes[o] = g; bytes[o+1] = g; bytes[o+2] = g
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 純色（低信心測資）。
    static func solid(width: Int, height: Int, gray: UInt8) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i*4] = gray; bytes[i*4+1] = gray; bytes[i*4+2] = gray
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 在影格內蓋一塊決定性「動態雜訊」方塊（模擬 GIF/影片區污染）。
    static func stampDynamicBlock(_ frame: inout PixelBuffer, x: Int, y: Int,
                                  w: Int, h: Int, seed: UInt64) {
        var rng = LCG(seed: seed)
        for r in y..<min(y + h, frame.height) {
            for c in x..<min(x + w, frame.width) {
                let o = (r * frame.width + c) * 4
                frame.bytes[o] = UInt8(rng.int(256))
                frame.bytes[o+1] = UInt8(rng.int(256))
                frame.bytes[o+2] = UInt8(rng.int(256))
            }
        }
    }

    /// 對整格加均勻雜訊（±amp，模擬次像素重繪差異）。
    static func addNoise(_ frame: inout PixelBuffer, amplitude: Int, seed: UInt64) {
        var rng = LCG(seed: seed)
        for i in stride(from: 0, to: frame.bytes.count, by: 4) {
            for ch in 0..<3 {
                let v = Int(frame.bytes[i+ch]) + rng.int(amplitude * 2 + 1) - amplitude
                frame.bytes[i+ch] = UInt8(max(0, min(255, v)))
            }
        }
    }
}
