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
        // 自檢判「有電平」＝**彩色格**（飽和度 max-min > 0.25），不是「偏亮像素」。這讓外觀與判準脫鉤：
        //  · 亮格用飽和的綠/黃/紅（會被算）；未亮格/外框/peak 用**低飽和的灰白**（不會被算）。
        //  · 因此未亮格可以放心用「可見的實心灰」——空表也一眼看得出是一排格子；舊判準（rgb 和>0.5）
        //    會把任何偏亮像素當亮格，逼未亮格只能純黑（真機 Retina 下看不見），才是原本「黑塊」的病根。
        //  （2026-08-13 舊坑「半透明白疊黑＝假亮格」在飽和度判準下自然消失：白是低飽和，不會被算。）
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.5).setFill()    // 底軌（純黑，加深讓灰格更跳）
        track.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke() // 外框（白，低飽和＝自檢不算亮格）
        track.lineWidth = 1
        track.stroke()

        guard totalBars > 0 else { return }
        let inner = frame.insetBy(dx: 2, dy: 2)
        let gap: CGFloat = 1.5
        let barWidth = (inner.width - gap * CGFloat(totalBars - 1)) / CGFloat(totalBars)
        guard barWidth > 0 else { return }

        for i in 0..<totalBars {
            let x = inner.minX + CGFloat(i) * (barWidth + gap)
            let barRect = NSRect(x: x, y: inner.minY, width: barWidth, height: inner.height)
            let cell = NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1)

            let isPeakBar = peakBar > 0 && i == peakBar - 1
            if isPeakBar {
                NSColor.white.setFill(); cell.fill()                       // peak-hold：亮白標最高點
            } else if i < litBars {
                Self.zoneColor(for: i, totalBars: totalBars).setFill(); cell.fill()   // 亮格：分區色
            } else {
                // 未亮格：**實心可見灰**——空表也一眼看得出是一排格子（真機 Retina 下細描邊太淡看不見，
                // 實心才夠清楚）。灰白是**低飽和**色，自檢改用飽和度判亮格後不會被誤算，故可放心用亮灰。
                NSColor.white.withAlphaComponent(0.4).setFill(); cell.fill()
            }
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
