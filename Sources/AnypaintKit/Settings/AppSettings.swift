import Foundation

/// 使用者可調偏好（存 UserDefaults）。目前只有框選看門狗。
public enum AppSettings {
    private static let watchdogKey = "overlayWatchdogSeconds"

    /// 設定頁下拉框的選項：0＝關閉，其餘為秒數（1/2/3/5/10 分鐘）。
    public static let watchdogOptions: [Double] = [0, 60, 120, 180, 300, 600]

    /// 正規化：0 以下＝0（關閉，使用者明確選擇）；非 0 最少 60、最多 600。
    public static func normalizedWatchdogSeconds(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        return min(600, max(60, v))
    }

    /// 框選看門狗秒數（免按鍵的最終逃生保險）。
    /// 0 = 關閉；從未設定過 = 預設 60。逾時是指「無任何互動」達此秒數才強制解除。
    public static var overlayWatchdogSeconds: Double {
        get {
            // 用 object(forKey:) 區分「沒設定過」(nil→預設60) 與「設成 0=關閉」。
            guard let v = UserDefaults.standard.object(forKey: watchdogKey) as? Double else { return 60 }
            return normalizedWatchdogSeconds(v)
        }
        set {
            UserDefaults.standard.set(normalizedWatchdogSeconds(newValue), forKey: watchdogKey)
        }
    }

    private static let colorRGBKey = "colorPickerShowsRGB"

    /// 取色顯示格式：true＝RGB（預設，如「213, 144, 13」）、false＝HEX（如「#D5900D」）。
    /// 放大鏡下按 Shift 切換並記住（跨 session）。
    public static var colorPickerShowsRGB: Bool {
        get { UserDefaults.standard.object(forKey: colorRGBKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: colorRGBKey) }
    }
}
