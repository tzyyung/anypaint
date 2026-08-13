import AppKit

/// 動畫截圖的檔案落地。與 CaptureOutputService 平行的 side path（設計文件 §6）：
/// 現有輸出鏈是影像導向（writePNG），影片/GIF 只重用命名樣板、目錄設定與碰撞遞增，
/// 不硬塞影像管線。
public final class RecordOutputService {
    public init() {}

    /// 暫存母帶路徑。放系統暫存目錄：丟棄/存檔後即刪，殘留由 cleanupStaleTempFiles 清。
    public func tempMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-record-\(UUID().uuidString).mp4")
    }

    /// 「錄影」直接落地的預設檔名樣板（無副檔名,由 finalMovieURL 補 .mp4）。
    public static let recordDefaultName = "anypaint $yyyy-MM-dd HH.mm.ss$"

    /// 「錄影」的最終存檔路徑（純函式,可測）：目錄用 `saveDirectory`（nil/空→`~/Movies/anypaint`）,
    /// 展開 `~`／相對路徑補 `home`;檔名用時間戳樣板＋`.mp4`;同名碰撞遞增（`exists` 注入）。
    public static func finalMovieURL(saveDirectory: String?, vars: [String: String], date: Date,
                                     home: String, timeZone: TimeZone = .current,
                                     exists: (URL) -> Bool) -> URL {
        let dirRaw = (saveDirectory?.isEmpty == false) ? saveDirectory! : "~/Movies/anypaint"
        let dirPath: String
        if dirRaw == "~" { dirPath = home }
        else if dirRaw.hasPrefix("~/") { dirPath = home + String(dirRaw.dropFirst(1)) }
        else { dirPath = FilenameTemplate.ensureAbsolute(dirRaw, home: home) }
        let name = FilenameTemplate.ensuringExtension(
            FilenameTemplate.expand(recordDefaultName, date: date, vars: vars, timeZone: timeZone), ext: "mp4")
        return CaptureSaver.uniquedURL(directory: URL(fileURLWithPath: dirPath), filename: name, exists: exists)
    }

    /// 「錄影」直接落地：把暫存母帶複製到 `finalMovieURL`（`recordSaveDirectory`）＋發存檔通知。
    /// 不開預覽（與 `saveCopy`＝預覽匯出那條分開）。失敗回 nil。
    @discardableResult
    public func saveMovie(from tempURL: URL, vars: [String: String]) -> URL? {
        let url = Self.finalMovieURL(saveDirectory: AppSettings.recordSaveDirectory, vars: vars, date: Date(),
                                     home: NSHomeDirectory(),
                                     exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: tempURL, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent, fileURL: url)
            }
            return url
        } catch {
            NSLog("anypaint: 錄影存檔失敗 \(error)")
            NSSound.beep()
            return nil
        }
    }

    /// app 啟動時清掃殘留暫存（上次 crash/強退遺留）。
    public func cleanupStaleTempFiles() {
        let dir = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasPrefix("anypaint-record-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 快速儲存：樣板展開 → 副檔名改 ext → 檔名 fallback → ~ 展開/相對補家目錄 → 碰撞遞增
    /// → copy → 通知。流程對照 CaptureOutputService.resolveURL＋saveExpanding（該檔 12-50 行），
    /// 差異僅副檔名與「copy 檔案」取代「寫 PNG」。
    @discardableResult
    public func saveCopy(from tempURL: URL, ext: String, vars: [String: String]) -> URL? {
        let now = Date()
        // 樣板多半以 .png 結尾（defaultName 如此）——先剝掉再補正確副檔名，避免 x.png.mp4
        var expanded = FilenameTemplate.expand(AppSettings.quickSavePathTemplate, date: now, vars: vars)
        if FilenameTemplate.hasPNGExtension(expanded) { expanded = String(expanded.dropLast(4)) }
        expanded = FilenameTemplate.ensuringExtension(expanded, ext: ext)
        let fallback = FilenameTemplate.ensuringExtension(
            String(FilenameTemplate.expand(FilenameTemplate.defaultName, date: now, vars: vars).dropLast(4)),
            ext: ext)
        expanded = FilenameTemplate.ensuringMeaningfulFilename(expanded, fallbackName: fallback, ext: ext)
        var path = (expanded as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = NSHomeDirectory() + "/" + path }   // launchd 啟動 cwd=/
        let target = URL(fileURLWithPath: path)
        let url = CaptureSaver.uniquedURL(directory: target.deletingLastPathComponent(),
                                          filename: target.lastPathComponent,
                                          exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: tempURL, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent, fileURL: url)
            }
            return url
        } catch {
            NSLog("anypaint: 動畫存檔失敗 \(error)")
            NSSound.beep()
            return nil
        }
    }
}
