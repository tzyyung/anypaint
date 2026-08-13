import Foundation

public enum GuidanceMessage: Equatable {
    case progress(px: Int), slowDown, gapNotStitched, mouseOutside, selectionTooSmall
    case backscrollTrimming, backscrollAtOrigin, hardToMatch, bottomProbing, deadReckoning
    /// 到底判定的**主動確認**：只在本次 session 曾發生匹配失敗或近似接合（長圖品質有疑慮）時
    /// 才出現。正常到底維持無感自動收尾——不打擾使用者是設計裁決。
    case confirmBottomByBackscroll
}

/// HUD 訊息語氣（純值,不綁 AppKit——顏色映射留在 view 層）。
public enum GuidanceTone: Equatable { case neutral, warning, error }

public extension GuidanceMessage {
    /// 繁中文案（spec §10 逐字）。純對應,selftest 可測（原內嵌在 ScrollHUD 的 file-scope func）。
    var displayText: String {
        switch self {
        case .progress(let px): return "已拼接 \(px) px"
        case .slowDown: return "捲慢一點，重疊區太少"
        case .gapNotStitched: return "捲太快，這段沒接上——回捲到斷點附近再往下慢慢捲"
        case .mouseOutside: return "滑鼠留在框內才收得到滾輪"
        case .backscrollTrimming: return "回捲中——長圖尾端同步撤回"
        case .backscrollAtOrigin: return "已回到起點，再往上不會拼入"
        case .hardToMatch: return "這段內容不好辨識，慢慢捲"
        case .selectionTooSmall: return "選區高度不足，拉高一點才能開始"
        case .bottomProbing: return "已到底部，收尾中…"
        case .deadReckoning: return "空白區段以軌跡推算，接縫可能略有誤差"
        case .confirmBottomByBackscroll: return "有幾段不易辨識——往回捲一點再往下捲，確認沒有漏"
        }
    }

    /// 語氣：警告黃／錯誤紅／中性白（spec §10）。原內嵌在 ScrollHUD.tone。
    var tone: GuidanceTone {
        switch self {
        case .slowDown, .hardToMatch, .selectionTooSmall, .confirmBottomByBackscroll: return .warning
        case .gapNotStitched: return .error
        // mouseOutside 是「提醒」級（spec §10）＝中性,非警告黃
        case .progress, .mouseOutside, .backscrollTrimming, .backscrollAtOrigin, .bottomProbing, .deadReckoning:
            return .neutral
        }
    }
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
