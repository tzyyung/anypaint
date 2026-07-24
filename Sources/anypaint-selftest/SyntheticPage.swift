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
