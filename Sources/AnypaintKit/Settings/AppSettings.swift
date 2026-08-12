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

    // MARK: - 動畫截圖

    private static let recordCursorKey = "recordShowsCursor"
    private static let recordClickRingKey = "recordClickRing"
    private static let recordGifFpsKey = "recordGifFps"
    private static let recordUseHEVCKey = "recordUseHEVC"

    /// 錄製時顯示滑鼠游標（交給 SCStreamConfiguration.showsCursor）。預設開。
    public static var recordShowsCursor: Bool {
        get { UserDefaults.standard.object(forKey: recordCursorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordCursorKey) }
    }

    /// 錄製時顯示點擊高亮圈（螢幕透明視窗，SCK 自然拍入）。預設開。
    /// 設定頁上與游標連動：游標關閉時此項停用（Kap 的 UX 慣例，設計文件 §7）。
    public static var recordClickRing: Bool {
        get { UserDefaults.standard.object(forKey: recordClickRingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordClickRingKey) }
    }

    /// GIF 編碼幀率選項。
    public static let recordGifFpsOptions: [Int] = [8, 10, 12, 15, 20]

    /// GIF 幀率正規化：找最接近的選項；平手時取較小值（determinism）。
    ///
    /// 純函式，供 selftest 直接測試。
    public static func normalizedRecordGifFps(_ v: Int) -> Int {
        let options = recordGifFpsOptions
        if options.contains(v) {
            return v
        }
        var best = options[0]
        var bestDiff = abs(v - best)
        for opt in options {
            let diff = abs(v - opt)
            if diff < bestDiff || (diff == bestDiff && opt < best) {
                best = opt
                bestDiff = diff
            }
        }
        return best
    }

    /// GIF 編碼幀率（fp）。預設 12。
    public static var recordGifFps: Int {
        get {
            // 未設定過 → 預設 12；已設定 → 正規化（防止舊版本設定值跨版本失效）
            guard let v = UserDefaults.standard.object(forKey: recordGifFpsKey) as? Int else { return 12 }
            return normalizedRecordGifFps(v)
        }
        set {
            UserDefaults.standard.set(normalizedRecordGifFps(newValue), forKey: recordGifFpsKey)
        }
    }

    /// MP4 使用 HEVC 編碼（檔案較小，舊裝置相容性較差）。預設 false（H.264）。
    public static var recordUseHEVC: Bool {
        get { UserDefaults.standard.object(forKey: recordUseHEVCKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: recordUseHEVCKey) }
    }

    private static let recordSystemAudioKey = "recordSystemAudio"
    private static let recordMicrophoneKey = "recordMicrophone"

    /// 錄製時包含系統聲音（SCStreamConfiguration.capturesAudio）。預設開。
    public static var recordSystemAudio: Bool {
        get { UserDefaults.standard.object(forKey: recordSystemAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordSystemAudioKey) }
    }

    /// 錄製時包含麥克風（需要 TCC 授權；未授權時啟動處會降級關閉，不中斷錄影——spec §3）。
    /// 預設關。
    public static var recordMicrophone: Bool {
        get { UserDefaults.standard.object(forKey: recordMicrophoneKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: recordMicrophoneKey) }
    }

    // MARK: - UI 自動化

    private static let allowLocalAutomationKey = "allowLocalAutomation"
    /// 自動化通道的常駐閘門（--uitest 之外的第二條）。預設關——混淆代理人對策 (a)。
    public static var allowLocalAutomation: Bool {
        get { UserDefaults.standard.object(forKey: allowLocalAutomationKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: allowLocalAutomationKey) }
    }
}
