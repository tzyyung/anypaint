import Foundation

/// 使用者可調偏好（存 UserDefaults）。目前只有框選逾時。
public enum AppSettings {
    private static let watchdogKey = "overlayWatchdogSeconds"

    /// 框選看門狗秒數（免按鍵的最終逃生保險）。預設 60；下限 15 上限 300。
    /// 逾時是指「無任何互動」達此秒數才強制解除——正常調整框會一直重置它。
    public static var overlayWatchdogSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: watchdogKey)
            return v > 0 ? v : 60
        }
        set {
            UserDefaults.standard.set(min(300, max(15, newValue)), forKey: watchdogKey)
        }
    }
}
