import AppKit

/// 麥克風電平表：分段格子（VU meter 常見樣式），真 NSView `draw(_:)` 繪製格子，
/// 不是純 CALayer——`cacheDisplay(in:to:)`／`screenshotSelf` 才截得到像素，
/// 這是自檢用離屏渲染驗證亮格的硬需求（見 task-A3 簡報）。
///
/// 局部重繪：CLAUDE.md 記過「局部重繪的前提會被貫穿全畫面的元素打破」的教訓，但那是
/// 針對「大範圍背景圖＋每次滑鼠移動都可能重繪」的場景。這裡刻意選擇**每次都整塊重繪**：
/// 格數固定（預設 12）、面積小（實測用途是 HUD 裡一條窄條），`level` 更新頻率跟著音訊
/// tick（通常數十 Hz）而非滑鼠移動，整塊重繪的成本可忽略，也就沒有「上次畫在哪」要追蹤、
/// 沒有殘影風險——用最簡單的方式換掉那三個坑，不是沒讀教訓就整塊重繪。
public final class LevelMeterView: NSView {

    /// 格數（預設 12）。變更時重置目前亮格與 peak-hold，避免舊索引超出新範圍。
    public var totalBars: Int = 12 {
        didSet {
            litBars = 0
            peakBar = 0
            setNeedsDisplay(bounds)
        }
    }

    /// 線性 RMS（0..1）。setter 換算 dB→亮格數、更新 peak-hold、觸發整塊重繪。
    public var level: Float = 0 {
        didSet { updateLevel() }
    }

    /// 目前亮格數（0...totalBars）。
    private var litBars: Int = 0
    /// peak-hold 位置：亮格數的高水位（0 表示尚無 peak）。新值 ≥ 目前 peak 就更新；
    /// 否則每次 `level` 更新（一個 tick）衰減 1 格——讓使用者看得到剛剛的峰值，
    /// 又不會卡死在舊高點。
    private var peakBar: Int = 0

    private func updateLevel() {
        let db = RecordMath.dbFromRMS(level)
        let bars = RecordMath.levelBars(db: db, totalBars: totalBars)
        litBars = bars
        peakBar = RecordMath.nextPeak(bars: bars, currentPeak: peakBar)
        setNeedsDisplay(bounds)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // 背景與未亮格一律用純黑（rgb 分量恆為 0）——格框靠深淺兩層黑色的 alpha 對比
        // 呈現，不靠混進白色。踩過的坑：先前未亮格用「半透明白疊在黑背景上」，合成後
        // rgb 和 ≈0.77、alpha≈0.31，剛好同時跨過自檢「alpha>0.3 且 rgb 和>0.5」兩個
        // 門檻——這是合成色的假訊號，不是真的亮格，導致靜音時仍有大量像素被誤判為亮
        // （2026-08-13 審查抓到：quiet 亮格佔比 79%）。黑色不管疊多少層 alpha，rgb 和
        // 恆為 0，永遠不會被那個判準誤傷。
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()

        guard totalBars > 0 else { return }
        let gap: CGFloat = 2
        let barWidth = (bounds.width - gap * CGFloat(totalBars - 1)) / CGFloat(totalBars)
        guard barWidth > 0 else { return }

        for i in 0..<totalBars {
            let x = CGFloat(i) * (barWidth + gap)
            let barRect = NSRect(x: x, y: 0, width: barWidth, height: bounds.height)

            let isPeakBar = peakBar > 0 && i == peakBar - 1
            let color: NSColor
            if isPeakBar {
                // peak-hold 格：不管當下是否亮起（衰減後可能已高於目前亮格），
                // 都用亮白標出剛剛到過的最高點，與下面的 dB 分區色明顯區隔。
                color = NSColor.white
            } else if i < litBars {
                color = Self.zoneColor(for: i, totalBars: totalBars)
            } else {
                // 未亮格：比背景略深的黑，形成可見的格框，同樣不含白色分量。
                color = NSColor.black.withAlphaComponent(0.35)
            }
            color.setFill()
            NSBezierPath(rect: barRect).fill()
        }
    }

    /// dB 分區配色：最後 1 格紅（滿刻度／接近爆音）、倒數第 2 格黃（警戒），其餘綠。
    /// static + 顯式 totalBars：純函式,不依賴 view 實例狀態,selftest 可直接驗證分區邊界。
    public nonisolated static func zoneColor(for index: Int, totalBars: Int) -> NSColor {
        if index == totalBars - 1 { return .systemRed }
        if index == totalBars - 2 { return .systemYellow }
        return .systemGreen
    }
}
