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

    private static let saveDirKey = "saveDirectoryPath"

    /// 截圖存檔資料夾（quickSavePathTemplate 的遷移來源）。從未設定＝桌面。
    /// 預設用 ~ 形式——不把家目錄寫死進樣板（可攜；展開交給存檔/預覽層）。
    public static var saveDirectoryPath: String {
        get {
            if let v = UserDefaults.standard.string(forKey: saveDirKey), !v.isEmpty { return v }
            return "~/Desktop"
        }
        set { UserDefaults.standard.set(newValue, forKey: saveDirKey) }
    }

    // MARK: - 輸出（檔名樣板／自動儲存／通知）

    private static let manualNameKey = "manualNameTemplate"
    private static let quickSaveKey = "quickSavePathTemplate"
    private static let autoSaveEnabledKey = "autoSaveEnabled"
    private static let autoSavePathKey = "autoSavePathTemplate"
    private static let saveNotifyKey = "saveNotificationEnabled"

    /// 另存為對話框的預設檔名樣板（純檔名，不含目錄）。
    public static var manualNameTemplate: String {
        get {
            if let v = UserDefaults.standard.string(forKey: manualNameKey), !v.isEmpty { return v }
            return FilenameTemplate.defaultName
        }
        set { UserDefaults.standard.set(newValue, forKey: manualNameKey) }
    }

    /// 遷移：新鍵未設（nil/空）→ 以舊存檔資料夾組完整路徑樣板（純函式，selftest 可測）。
    public static func resolvedQuickSaveTemplate(stored: String?,
                                                 legacyDirectory: String) -> String {
        if let s = stored, !s.isEmpty { return s }
        return legacyDirectory + "/" + FilenameTemplate.defaultName
    }

    /// 存鈕/⌘S 的完整路徑樣板。
    /// 未設定＝舊 saveDirectoryPath（其預設＝桌面）＋預設檔名——lazy 遷移，不寫回、冪等。
    public static var quickSavePathTemplate: String {
        get {
            resolvedQuickSaveTemplate(
                stored: UserDefaults.standard.string(forKey: quickSaveKey),
                legacyDirectory: saveDirectoryPath)
        }
        set { UserDefaults.standard.set(newValue, forKey: quickSaveKey) }
    }

    /// 自動儲存：每次完成截圖（複製/貼/存/另存、含看門狗搶救）額外存一份。預設關。
    public static var autoSaveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoSaveEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSaveEnabledKey) }
    }

    /// 自動儲存路徑樣板。預設 ~/Pictures/anypaint/。
    public static var autoSavePathTemplate: String {
        get {
            if let v = UserDefaults.standard.string(forKey: autoSavePathKey), !v.isEmpty { return v }
            return "~/Pictures/anypaint/" + FilenameTemplate.defaultName   // ~ 形式：不寫死家目錄
        }
        set { UserDefaults.standard.set(newValue, forKey: autoSavePathKey) }
    }

    /// 快速儲存/自動儲存後發系統通知。預設開。
    public static var saveNotificationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: saveNotifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: saveNotifyKey) }
    }

    private static let openWithKey = "openWithBundleIdentifier"

    /// 「存檔並開啟」要交給哪個 App 的 bundle ID。空／未設＝系統預設的 PNG 程式
    /// （多數機器＝預覽程式）。
    ///
    /// 存 bundle ID 而不是路徑：App 在 /Applications ↔ ~/Applications 之間搬動、
    /// 或改了顯示名稱，靠 bundle ID 仍找得到；存路徑就會失效。
    public static var openWithBundleIdentifier: String {
        get { UserDefaults.standard.string(forKey: openWithKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: openWithKey) }
    }

    /// 決定「存檔並開啟」實際要交給哪個 App（純函式，selftest 可測）。
    ///
    /// - Parameter resolve: bundle ID → App URL 的解析器（正式路徑傳
    ///   `NSWorkspace.urlForApplication(withBundleIdentifier:)`）。
    /// - Returns: 指定的 App URL；**未指定或解析不到都回 nil**，由呼叫端退回系統預設。
    ///   解析不到＝使用者選過的 App 被刪了或改了 bundle ID——這時退回系統預設把檔案開起來，
    ///   比整個動作失敗有用（設定頁會另外把這個狀態顯示出來，不靜默）。
    public static func resolveOpenWithApp(stored: String,
                                          resolve: (String) -> URL?) -> URL? {
        let id = stored.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return resolve(id)
    }

    /// 輸出設定回出廠預設。連遷移來源 saveDirectoryPath 一併清——
    /// 否則清了新鍵後 quickSave 又從舊資料夾遷移，還原的不是「預設」。
    public static func resetOutputDefaults() {
        for key in [manualNameKey, quickSaveKey, autoSaveEnabledKey,
                    autoSavePathKey, saveNotifyKey, saveDirKey, openWithKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let settingsTabKey = "settingsSelectedTab"

    /// 設定視窗記住上次分頁（0-3；越界由呼叫端 clamp）。
    public static var settingsSelectedTab: Int {
        get { UserDefaults.standard.integer(forKey: settingsTabKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingsTabKey) }
    }

    // MARK: - 滾動截圖

    private static let scrollWatchdogKey = "scrollWatchdogSeconds"
    private static let scrollMaxHeightKey = "scrollMaxHeightPx"

    /// 設定頁滾動看門狗下拉選項：0＝關閉，其餘為秒數。
    public static let scrollWatchdogOptions: [Double] = [0, 60, 300, 600, 1800]

    /// 設定頁長圖高度上限下拉選項（px）。
    public static let scrollMaxHeightOptions: [Int] = [10000, 30000, 50000]

    /// capturing 期間看門狗（獨立於框選看門狗；讀內容 2 分鐘是正常行為——spec §9.3）。
    /// 0 = 關閉（以長度上限＋連續失敗自動收工為保底）；預設 300。
    public static var scrollWatchdogSeconds: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: scrollWatchdogKey) as? Double else { return 300 }
            return v <= 0 ? 0 : min(1800, max(60, v))
        }
        set { UserDefaults.standard.set(newValue, forKey: scrollWatchdogKey) }
    }

    /// 長圖高度上限 px（spec §7.5）。預設 30000。
    public static var scrollMaxHeightPx: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: scrollMaxHeightKey)
            return v > 0 ? min(100_000, max(5000, v)) : 30000
        }
        set { UserDefaults.standard.set(newValue, forKey: scrollMaxHeightKey) }
    }
}
