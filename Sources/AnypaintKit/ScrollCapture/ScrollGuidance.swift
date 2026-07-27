import Foundation

public enum GuidanceMessage: Equatable {
    case progress(px: Int), slowDown, gapNotStitched, mouseOutside, selectionTooSmall
    case backscrollTrimming, backscrollAtOrigin, hardToMatch, bottomProbing, deadReckoning
    /// 到底判定的**主動確認**：只在本次 session 曾發生匹配失敗或近似接合（長圖品質有疑慮）時
    /// 才出現。正常到底維持無感自動收尾——不打擾使用者是設計裁決。
    case confirmBottomByBackscroll
}

/// HUD 提示決策（spec §10 規則表）。純值型別：事件進、訊息出，Session 只轉發。
/// 計數器語意（spec §10 明文）：失敗計數被任一成功接受格重置；回捲格不計失敗。
public struct ScrollGuidance {
    let selectionHeight: Int
    public private(set) var consecutiveFailures = 0

    public init(selectionHeight: Int) { self.selectionHeight = selectionHeight }

    public mutating func frameAccepted(dy: Int, totalPx: Int) -> GuidanceMessage {
        consecutiveFailures = 0
        // 70% 閾值：由 selftest 對「重疊多少以下 matcher 開始不可靠」的量測背書（spec §10）
        if dy > selectionHeight * 7 / 10 { return .slowDown }
        return .progress(px: totalPx)
    }

    public mutating func frameDropped() -> GuidanceMessage? {
        consecutiveFailures += 1
        return consecutiveFailures >= 3 ? .hardToMatch : nil
    }

    public mutating func frameDroppedBackscroll() -> GuidanceMessage { .backscrollTrimming }

    /// 「捲太快」複合訊號（spec §10）：匹配失敗中 且 自上次成功後滾輪累計 > 選區高。
    public mutating func wheelAccumulated(sinceLastAccept px: Int) -> GuidanceMessage? {
        (consecutiveFailures > 0 && px > selectionHeight) ? .gapNotStitched : nil
    }

    public mutating func mouseLeftSelection() -> GuidanceMessage { .mouseOutside }
    public mutating func backscrollAtOrigin() -> GuidanceMessage { .backscrollAtOrigin }
    public mutating func bottomProbing() -> GuidanceMessage { .bottomProbing }
    public mutating func confirmBottom() -> GuidanceMessage { .confirmBottomByBackscroll }
    public mutating func deadReckoningUsed() -> GuidanceMessage { .deadReckoning }
}
