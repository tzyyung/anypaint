import Foundation

/// 動畫截圖的純計算（無狀態、selftest 可測）。
/// 演算法出處見設計文件 §6/§10：sample-and-hold 取自 Gifski.app GIFGenerator.swift、
/// 累計捨入取自 gifski src/lib.rs、0.5s 尾格門檻取自 Cap PR #1219。
public enum RecordMath {

    /// GIF 每格 delay（centiseconds）。**累計捨入**：delay = round(累計秒×100) − 已寫入 cs，
    /// 誤差永不漂移（逐格天真捨入 1/12s→8cs 會讓長片加速 ~4%）。
    ///
    /// 前置條件：`duration ≤ 0` 時每格 delay 為 minCs。
    /// - Parameters:
    ///   - frameStartTimes: 每格開始顯示的秒數（遞增，首格 0）。
    ///   - duration: 總長（秒）＝最後一格顯示到此為止。
    ///   - minCs: 每格下限（GIF 規格實務下限 2cs＝50fps 上限）。
    public static func gifDelaysCentiseconds(frameStartTimes: [Double],
                                             duration: Double,
                                             minCs: Int = 2) -> [Int] {
        var out: [Int] = []
        var written = 0
        for i in frameStartTimes.indices {
            let end = i + 1 < frameStartTimes.count ? frameStartTimes[i + 1] : duration
            let delay = max(minCs, Int((end * 100).rounded()) - written)
            out.append(delay)
            written += delay
        }
        return out
    }

    /// APNG 每格 delay（秒）。與 `gifDelaysCentiseconds` **不同規則**：APNG 沒有 GIF 的
    /// 2cs（50fps）下限，`kCGImagePropertyAPNGDelayTime` 直接吃秒數 Double，因此逐格用
    /// 「下一格起點 − 本格起點」即可、不需要累計捨入去消化取整誤差（那是 GIF 特有的問題）。
    ///
    /// 前置條件：`duration ≤ 0` 或早於最後一格起點時，末格 delay 可能為負——呼叫端保證
    /// `frameStartTimes` 遞增且 `duration` 涵蓋最後一格（與 `gifDelaysCentiseconds` 同前提）。
    /// - Parameters:
    ///   - frameStartTimes: 每格開始顯示的秒數（遞增，首格 0）。
    ///   - duration: 總長（秒）＝最後一格顯示到此為止。
    public static func apngDelaysSeconds(frameStartTimes: [Double], duration: Double) -> [Double] {
        frameStartTimes.indices.map { i in
            let end = i + 1 < frameStartTimes.count ? frameStartTimes[i + 1] : duration
            return end - frameStartTimes[i]
        }
    }

    /// 均勻目標時間網格（秒）。至少 2 格（GIF 最少兩格才有動畫意義）。
    ///
    /// 前置條件：`fps > 0`。
    public static func gridTimes(duration: Double, fps: Double) -> [Double] {
        let count = max(2, Int(duration * fps))
        return (0..<count).map { Double($0) / fps }
    }

    /// sample-and-hold：對每個目標時刻，取「PTS ≤ 目標」的最新來源格 index；
    /// 目標早於第一格 PTS 時用第一格。一個來源格可重複使用（靜止期）、也可被跳過（快動）。
    /// VFR 母帶的大 PTS 空洞（SCK 靜止不供格）因此天然消化。
    ///
    /// 前置條件：`fps > 0`；`sourceTimes` 空時回空結果。
    /// - Parameter sourceTimes: 來源每格 PTS（秒、遞增）。
    public static func sampleHoldIndices(sourceTimes: [Double],
                                         duration: Double,
                                         fps: Double) -> [Int] {
        guard !sourceTimes.isEmpty else { return [] }
        var out: [Int] = []
        var src = 0
        for t in gridTimes(duration: duration, fps: fps) {
            while src + 1 < sourceTimes.count, sourceTimes[src + 1] <= t { src += 1 }
            out.append(sourceTimes[src] <= t ? src : 0)
        }
        return out
    }

    /// 停止時是否需要補尾格：畫面靜止時 SCK 不供格，檔案會停在最後一格的 PTS——
    /// 結尾靜止超過門檻就把最後一格重蓋時間戳補進 writer（設計文件 §3 停止順序第 2 步）。
    public static func needsTailFrame(lastPTSSeconds: Double,
                                      nowSeconds: Double,
                                      threshold: Double = 0.5) -> Bool {
        nowSeconds - lastPTSSeconds > threshold
    }

    /// HUD 時鐘文字：不限時＝正數 mm:ss；限時＝剩餘倒數（下限 00:00，不閃負值）。
    public static func hudClockText(elapsedSeconds: Double, limitSeconds: Double?) -> String {
        let shown: Double
        if let limit = limitSeconds {
            shown = max(0, limit - elapsedSeconds)
        } else {
            shown = max(0, elapsedSeconds)
        }
        let s = Int(shown.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Goertzel 單頻能量（正規化）：音訊自檢判定「錄到的就是自己播的 440Hz」。
    /// 純計算——輸入是裸樣本陣列，不碰 AVFoundation（分層原則）。
    public static func goertzelPower(samples: [Float], sampleRate: Double,
                                     targetHz: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let w = 2 * Double.pi * targetHz / sampleRate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return power / Double(samples.count * samples.count)
    }

    /// 線性 RMS（0..1）。把整段樣本當一串算整體均方根——待命試音錶的粗略確認足夠，
    /// 不分聲道。空輸入回 0。純函式：不 import 任何框架（同本檔其餘方法）。
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard samples.count > 0 else { return 0 }
        var sum = 0.0
        for v in samples { sum += Double(v) * Double(v) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// 線性 RMS（0..1）→ dBFS，clamp 到 [-60, 0]（電平表下限 -60 dB）。
    public static func dbFromRMS(_ rms: Float) -> Float {
        guard rms > 0 else { return -60 }
        return max(-60, min(0, 20 * log10f(rms)))
    }

    /// dBFS（-60..0）→ 亮格數（0..totalBars），線性映射。
    public static func levelBars(db: Float, totalBars: Int) -> Int {
        let frac = (db + 60) / 60   // -60→0, 0→1
        return max(0, min(totalBars, Int((frac * Float(totalBars)).rounded())))
    }

    /// 無訊號判定：RMS 低於門檻。門檻＝實測噪底（≈0.0001）的數十倍。
    /// 校準來源：2026-08-12 除錯實測（內建麥克風/DaiLing G3 靜置 peak≈0.0001、人聲 0.01–0.5）。
    public static let silenceThreshold: Float = 0.003
    public static func isSilent(rms: Float) -> Bool { rms < silenceThreshold }

    /// 影片位元率（bps）：Azayaka 公式 `w*h*(30/8)*factor` + QuickRecorder 20 萬下限；
    /// factor＝H.264 0.9／HEVC 0.45（設計文件 §1.8）。純整數運算,抽出供 selftest 驗證。
    public static func videoBitrate(pixelWidth: Int, pixelHeight: Int, useHEVC: Bool) -> Int {
        let factor = useHEVC ? 0.45 : 0.9
        return max(200_000, Int(Double(pixelWidth * pixelHeight) * (30.0 / 8.0) * factor))
    }

    /// 限時錄影秒數輸入解析（RecordHUD 秒數欄）：空白／非整數／≤0 → nil；否則 clamp 1...600。
    public static func parseRecordDuration(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), v > 0 else { return nil }
        return Double(min(600, max(1, v)))
    }

    /// 電平表 peak-hold：本格亮格數 ≥ 當前 peak → 更新到本格；否則 peak 衰減一格（不低於 0）。
    public static func nextPeak(bars: Int, currentPeak: Int) -> Int {
        bars >= currentPeak ? bars : max(0, currentPeak - 1)
    }

    /// 匯出剪裁時長：請求長度與「母帶時長 − 範圍起點」取小（AVAssetReader 只讀交集,不 clamp 會
    /// 吐出比實際內容更長、尾端補靜止格的動畫）。
    public static func clampedExportDuration(requested: Double, assetDuration: Double, rangeStart: Double) -> Double {
        min(requested, assetDuration - rangeStart)
    }

    /// 像素長度 → 輸出點長度（除以 pointScale,四捨五入,下限 1）。逐維套用。
    public static func outputPointLength(pixels: Int, pointScale: CGFloat) -> Int {
        max(1, Int((CGFloat(pixels) / pointScale).rounded()))
    }
}
