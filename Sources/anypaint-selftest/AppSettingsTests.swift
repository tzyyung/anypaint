import AnypaintKit
import Foundation

/// AppSettings 各 computed property 的預設值 + 正規化 + round-trip。
/// 用字串鍵直接清 UserDefaults 來造「未設定」狀態（沿用 RecordOptionsTests 慣例）。
/// 每項測完清鍵,避免污染其他測試/重跑。
nonisolated func appSettingsTests() {
    let d = UserDefaults.standard
    func clear(_ k: String) { d.removeObject(forKey: k) }

    // overlayWatchdogSeconds：未設→60；0→0；30→拉到60；900→夾到600（getter+setter 都正規化）
    clear("overlayWatchdogSeconds")
    T.checkEq("overlayWatchdog: 未設→60", AppSettings.overlayWatchdogSeconds, 60)
    AppSettings.overlayWatchdogSeconds = 0
    T.checkEq("overlayWatchdog: 0=關閉", AppSettings.overlayWatchdogSeconds, 0)
    AppSettings.overlayWatchdogSeconds = 30
    T.checkEq("overlayWatchdog: 30→60 下限", AppSettings.overlayWatchdogSeconds, 60)
    AppSettings.overlayWatchdogSeconds = 900
    T.checkEq("overlayWatchdog: 900→600 上限", AppSettings.overlayWatchdogSeconds, 600)
    clear("overlayWatchdogSeconds")

    // colorPickerShowsRGB：未設→true；false round-trip
    clear("colorPickerShowsRGB")
    T.checkEq("colorPickerRGB: 未設→true", AppSettings.colorPickerShowsRGB, true)
    AppSettings.colorPickerShowsRGB = false
    T.checkEq("colorPickerRGB: false round-trip", AppSettings.colorPickerShowsRGB, false)
    clear("colorPickerShowsRGB")

    // saveDirectoryPath：未設/空→~/Desktop
    clear("saveDirectoryPath")
    T.checkEq("saveDir: 未設→~/Desktop", AppSettings.saveDirectoryPath, "~/Desktop")
    d.set("", forKey: "saveDirectoryPath")
    T.checkEq("saveDir: 空字串也→~/Desktop", AppSettings.saveDirectoryPath, "~/Desktop")
    AppSettings.saveDirectoryPath = "~/Pictures"
    T.checkEq("saveDir: round-trip", AppSettings.saveDirectoryPath, "~/Pictures")
    clear("saveDirectoryPath")

    // manualNameTemplate：空→FilenameTemplate.defaultName
    clear("manualNameTemplate")
    T.checkEq("manualName: 未設→defaultName", AppSettings.manualNameTemplate, FilenameTemplate.defaultName)
    clear("manualNameTemplate")

    // autoSaveEnabled：未設→false
    clear("autoSaveEnabled")
    T.checkEq("autoSave: 未設→false", AppSettings.autoSaveEnabled, false)
    AppSettings.autoSaveEnabled = true
    T.checkEq("autoSave: true round-trip", AppSettings.autoSaveEnabled, true)
    clear("autoSaveEnabled")

    // autoSavePathTemplate：未設→~/Pictures/anypaint/ + default
    clear("autoSavePathTemplate")
    T.checkEq("autoSavePath: 未設→~/Pictures/anypaint/…",
              AppSettings.autoSavePathTemplate, "~/Pictures/anypaint/" + FilenameTemplate.defaultName)
    clear("autoSavePathTemplate")

    // saveNotificationEnabled：未設→true
    clear("saveNotificationEnabled")
    T.checkEq("saveNotify: 未設→true", AppSettings.saveNotificationEnabled, true)
    AppSettings.saveNotificationEnabled = false
    T.checkEq("saveNotify: false round-trip", AppSettings.saveNotificationEnabled, false)
    clear("saveNotificationEnabled")

    // openWithBundleIdentifier：未設→""
    clear("openWithBundleIdentifier")
    T.checkEq("openWith: 未設→空", AppSettings.openWithBundleIdentifier, "")
    clear("openWithBundleIdentifier")

    // settingsSelectedTab：未設→0
    clear("settingsSelectedTab")
    T.checkEq("settingsTab: 未設→0", AppSettings.settingsSelectedTab, 0)
    AppSettings.settingsSelectedTab = 2
    T.checkEq("settingsTab: round-trip", AppSettings.settingsSelectedTab, 2)
    clear("settingsSelectedTab")

    // scrollWatchdogSeconds：未設→300；0→0；30→60；9999→1800（getter 正規化）
    clear("scrollWatchdogSeconds")
    T.checkEq("scrollWatchdog: 未設→300", AppSettings.scrollWatchdogSeconds, 300)
    AppSettings.scrollWatchdogSeconds = 0
    T.checkEq("scrollWatchdog: 0=關閉", AppSettings.scrollWatchdogSeconds, 0)
    AppSettings.scrollWatchdogSeconds = 30
    T.checkEq("scrollWatchdog: 30→60 下限", AppSettings.scrollWatchdogSeconds, 60)
    AppSettings.scrollWatchdogSeconds = 9999
    T.checkEq("scrollWatchdog: 9999→1800 上限", AppSettings.scrollWatchdogSeconds, 1800)
    clear("scrollWatchdogSeconds")

    // scrollMaxHeightPx：未設→30000；1→5000；999999→100000
    clear("scrollMaxHeightPx")
    T.checkEq("scrollMaxH: 未設→30000", AppSettings.scrollMaxHeightPx, 30000)
    AppSettings.scrollMaxHeightPx = 1
    T.checkEq("scrollMaxH: 1→5000 下限", AppSettings.scrollMaxHeightPx, 5000)
    AppSettings.scrollMaxHeightPx = 999999
    T.checkEq("scrollMaxH: 999999→100000 上限", AppSettings.scrollMaxHeightPx, 100_000)
    clear("scrollMaxHeightPx")

    // recordClickRing：未設→true
    clear("recordClickRing")
    T.checkEq("clickRing: 未設→true", AppSettings.recordClickRing, true)
    clear("recordClickRing")

    // recordGifFps：未設→12；setter 正規化（13→12 最接近、平手取小）
    clear("recordGifFps")
    T.checkEq("gifFps: 未設→12", AppSettings.recordGifFps, 12)
    AppSettings.recordGifFps = 13
    T.checkEq("gifFps: 13→正規化到最近選項", AppSettings.recordGifFps, 12)
    clear("recordGifFps")

    // allowLocalAutomation：未設→false
    clear("allowLocalAutomation")
    T.checkEq("allowAutomation: 未設→false", AppSettings.allowLocalAutomation, false)
    clear("allowLocalAutomation")

    // resetOutputDefaults：設一堆值→呼叫→全部回預設
    d.set("custom-name", forKey: "manualNameTemplate")
    d.set(true, forKey: "autoSaveEnabled")
    d.set(false, forKey: "saveNotificationEnabled")
    d.set("com.foo.bar", forKey: "openWithBundleIdentifier")
    AppSettings.resetOutputDefaults()
    T.checkEq("reset: manualName 回預設", AppSettings.manualNameTemplate, FilenameTemplate.defaultName)
    T.checkEq("reset: autoSave 回 false", AppSettings.autoSaveEnabled, false)
    T.checkEq("reset: saveNotify 回 true", AppSettings.saveNotificationEnabled, true)
    T.checkEq("reset: openWith 回空", AppSettings.openWithBundleIdentifier, "")
}
