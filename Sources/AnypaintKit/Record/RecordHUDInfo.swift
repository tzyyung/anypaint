import Foundation

/// 錄影 HUD 的資訊列文字（純函式,可測）：檔案資訊（存到哪）＋錄制資訊（區域尺寸/大小/時間）。
public enum RecordHUDInfo {
    /// 存檔位置顯示：未設＝預設 `~/Movies/anypaint`。
    public static func saveLocation(_ dir: String?) -> String {
        (dir?.isEmpty == false) ? dir! : "~/Movies/anypaint"
    }

    /// 區域尺寸（像素）。
    public static func regionText(widthPx: Int, heightPx: Int) -> String {
        "\(widthPx)×\(heightPx) px"
    }

    /// 待命資訊列：「存至 <dir> · <W>×<H> px」。
    public static func armedInfo(saveDirectory: String?, widthPx: Int, heightPx: Int) -> String {
        "存至 \(saveLocation(saveDirectory)) · \(regionText(widthPx: widthPx, heightPx: heightPx))"
    }

    /// 檔案大小人類可讀（B/KB/MB）。用 `kb.rounded()` 判界：否則 kb∈[1023.5,1024) 會被 `%.0f` 印成
    /// 「1024 KB」而非「1.0 MB」（審查 #2 邊界修）。
    public static func fileSizeText(bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb.rounded() < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// 錄制中資訊列：「<W>×<H> px · <size>」（size 可省）。
    public static func recordingInfo(widthPx: Int, heightPx: Int, bytes: Int64?) -> String {
        let base = regionText(widthPx: widthPx, heightPx: heightPx)
        guard let bytes else { return base }
        return base + " · " + fileSizeText(bytes: bytes)
    }

    // MARK: 完成態（取代 RecordSavedNotice；統一 morph 工具列的錄後文字）

    /// 完成標題（純函式,可測；取代 `RecordSavedNotice.message`）：成功給勾＋字樣,失敗給警告。
    public static func doneTitle(success: Bool) -> String {
        success ? "✓ 錄影完成" : "⚠︎ 錄影存檔失敗"
    }

    /// 時長 mm:ss（負值 clamp 0）。用 floor（無條件捨去）與即時時鐘 `RecordMath.hudClockText` 一致
    /// （審查 #4：否則 6.7s 時即時顯 00:06、完成卡顯 00:07 對不上）。
    public static func durationText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 完成資訊列：「已存至 <dir>」。
    public static func doneInfo(saveDirectory: String?) -> String {
        "已存至 \(saveLocation(saveDirectory))"
    }

    /// 完成中繼資訊：「⏱ 00:07 · 800×600 px · 3.2 MB」。
    public static func doneMeta(durationSec: Double, widthPx: Int, heightPx: Int, bytes: Int64) -> String {
        "⏱ \(durationText(durationSec)) · \(regionText(widthPx: widthPx, heightPx: heightPx)) · \(fileSizeText(bytes: bytes))"
    }
}
