import CoreGraphics
import Foundation

/// 增量長圖合成（spec §7.5）。可增長 bytes 陣列，append 只複製新增列（O(n) 總量）；
/// 裁尾是 O(1) 邏輯高度調整。寬度規則（D8）：鎖帶後整條長圖 = 內容寬（捲軸欄裁掉），
/// 頂帶留在 base 出現一次、底帶 finalize 補回最底端一次。
public final class ScrollStitcher {
    public private(set) var contentWidth: Int
    public private(set) var height: Int
    public private(set) var appendedFrameCount = 1
    public var isLocked: Bool { lockedInsets != nil }

    private var bytes: [UInt8]              // contentWidth × height × 4（邏輯高，容量可能更大）
    private var lockedInsets: BandInsets?
    private var bottomBandPixels: [UInt8] = []   // finalize 時補回
    private var bottomBandHeight = 0
    private var baseHeight: Int             // 裁尾下限（session 起點，spec D6）
    private let maxHeightPx: Int

    public init(firstFrame: PixelBuffer, maxHeightPx: Int) {
        contentWidth = firstFrame.width
        height = firstFrame.height
        baseHeight = firstFrame.height
        bytes = firstFrame.bytes
        self.maxHeightPx = maxHeightPx
    }

    // 契約（審查 I1/I2/M4）：鎖帶必須在任何 append 之前（底帶才不會埋進 buffer 中段、
    // 裁尾下限=session 起點才成立）；退化 insets 與寬度不符一律拒絕。
    // 回傳 false=拒絕不動 buffer——Session 端（T12）據此採「鎖定成功前不 append」的遞延策略。
    @discardableResult
    public func lockBands(_ insets: BandInsets, bottomBandFrom frame: PixelBuffer) -> Bool {
        guard lockedInsets == nil,
              appendedFrameCount == 1,                    // I1：先拼後鎖 → 拒
              insets.bottom < height,                     // I2：底帶吃掉整個 base → 拒
              frame.width == contentWidth,                // M4：寬度契約 fail-fast
              frame.height > insets.bottom
        else { return false }

        lockedInsets = insets
        let newW = contentWidth - insets.left - insets.right
        // base 水平裁到內容寬（頂帶保留——本來就該出現一次）
        var out = [UInt8](repeating: 0, count: newW * height * 4)
        let srcRow = contentWidth * 4, dstRow = newW * 4
        for r in 0..<height {
            let s = r * srcRow + insets.left * 4
            out.replaceSubrange(r * dstRow..<(r + 1) * dstRow, with: bytes[s..<s + dstRow])
        }
        // base 底帶移除＋暫存（spec §7.2 base 回裁：否則固定頁尾燒在長圖第一屏位置）
        // 守護已保證 insets.bottom < height，trimmed 必等於 insets.bottom；此處保留 min() 作雙保險。
        let trimmed = min(insets.bottom, height - 1)
        bottomBandHeight = trimmed
        if trimmed > 0 {
            // 底帶像素取自鎖定當下的影格（水平同樣裁到內容寬）
            let fh = frame.height
            var band = [UInt8](repeating: 0, count: newW * trimmed * 4)
            for r in 0..<trimmed {
                let s = ((fh - trimmed + r) * frame.width + insets.left) * 4
                band.replaceSubrange(r * dstRow..<(r + 1) * dstRow, with: frame.bytes[s..<s + dstRow])
            }
            bottomBandPixels = band
            out.removeLast(trimmed * dstRow)
            height -= trimmed
        }
        // 守護保證 lockBands 發生在任何 append 之前，此時 height 必等於 session 起點內容高。
        baseHeight = height
        bytes = out
        contentWidth = newW
        return true
    }

    public func append(contentFrame: PixelBuffer, dy: Int) -> Bool {
        precondition(contentFrame.width == contentWidth, "append 前呼叫端必須裁到內容寬")
        guard dy > 0 else { return true }
        guard height + dy <= maxHeightPx else { return false }
        let rowB = contentWidth * 4
        let fh = contentFrame.height
        let take = min(dy, fh)
        let start = (fh - take) * rowB
        bytes.append(contentsOf: contentFrame.bytes[start..<start + take * rowB])
        height += take
        appendedFrameCount += 1
        return true
    }

    public func cropTail(_ amount: Int) -> Int {
        let actual = min(amount, height - baseHeight)   // 不裁破 session 起點（spec D6）
        guard actual > 0 else { return 0 }
        bytes.removeLast(actual * contentWidth * 4)
        height -= actual                                 // 裁掉的高度自然退還上限額度
        return actual
    }

    public func referenceTail(maxHeight: Int) -> PixelBuffer {
        let take = min(maxHeight, height)
        let rowB = contentWidth * 4
        let slice = Array(bytes[(height - take) * rowB..<height * rowB])
        return PixelBuffer(width: contentWidth, height: take, bytes: slice)
    }

    public func finalize() -> CGImage? {
        var out = bytes
        if bottomBandHeight > 0 { out.append(contentsOf: bottomBandPixels) }
        let total = height + bottomBandHeight
        return PixelBuffer(width: contentWidth, height: total, bytes: out).makeCGImage()
    }
}
