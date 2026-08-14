import AnypaintKit
import Foundation

/// RecordOutputService.finalMovieURL：「錄影」直接落地的目標路徑純邏輯。
nonisolated func recordOutputTests() {
    let date = Date(timeIntervalSince1970: 0)   // 固定時間,測結構不測確切時戳
    let home = "/Users/tester"
    func url(_ dir: String?, exists: @escaping (URL) -> Bool = { _ in false }) -> URL {
        RecordOutputService.finalMovieURL(saveDirectory: dir, vars: [:], date: date, home: home,
                                          timeZone: TimeZone(identifier: "UTC")!, exists: exists)
    }

    // 未設目錄→ ~/Movies/anypaint（展開 home）
    let d = url(nil)
    T.checkEq("finalURL: 未設→~/Movies/anypaint 目錄",
              d.deletingLastPathComponent().path, "/Users/tester/Movies/anypaint")
    T.checkEq("finalURL: 副檔名 .mp4", d.pathExtension, "mp4")
    T.checkTrue("finalURL: 檔名含時間戳(1970→1970-01-01)", d.lastPathComponent.contains("1970-01-01"))

    // 指定 ~ 開頭目錄→展開 home
    T.checkEq("finalURL: ~/foo 展開",
              url("~/foo").deletingLastPathComponent().path, "/Users/tester/foo")
    // 絕對路徑原樣
    T.checkEq("finalURL: 絕對路徑原樣",
              url("/tmp/recs").deletingLastPathComponent().path, "/tmp/recs")
    // 相對路徑補 home
    T.checkEq("finalURL: 相對路徑補 home",
              url("recs").deletingLastPathComponent().path, "/Users/tester/recs")
    // 空字串→視同未設,回預設
    T.checkEq("finalURL: 空字串→預設",
              url("").deletingLastPathComponent().path, "/Users/tester/Movies/anypaint")

    // 碰撞遞增：第一個候選已存在→檔名補 -2
    var first: URL?
    let u2 = url(nil, exists: { candidate in
        if first == nil { first = candidate; return true }   // 第一個當作已存在
        return false
    })
    T.checkTrue("finalURL: 碰撞→檔名補 -2", u2.lastPathComponent.contains("-2.mp4"))

    // silentFormatWarning（Task B3）：有音軌＋無聲格式→提醒;MP4 或無音軌→nil
    T.checkTrue("silentFmt: gif+有音軌→提醒", RecordOutputService.silentFormatWarning(ext: "gif", hasAudio: true) != nil)
    T.checkTrue("silentFmt: png(APNG)+有音軌→提醒", RecordOutputService.silentFormatWarning(ext: "png", hasAudio: true) != nil)
    T.checkTrue("silentFmt: webp+有音軌→提醒", RecordOutputService.silentFormatWarning(ext: "webp", hasAudio: true) != nil)
    T.checkTrue("silentFmt: mp4+有音軌→nil（含聲音）", RecordOutputService.silentFormatWarning(ext: "mp4", hasAudio: true) == nil)
    T.checkTrue("silentFmt: gif+無音軌→nil", RecordOutputService.silentFormatWarning(ext: "gif", hasAudio: false) == nil)
    T.checkTrue("silentFmt: 大小寫容忍 GIF", RecordOutputService.silentFormatWarning(ext: "GIF", hasAudio: true) != nil)

    // （錄後完成文案已移轉到 RecordHUDInfo.doneTitle，見 recordHUDInfoTests；
    //   RecordSavedNotice 由統一 morph 工具列取代並刪除。）

    // saveDirectoryPath（完成面板「開啟存檔資料夾」的目錄解析，與 finalMovieURL 同套規則）
    T.checkEq("saveDir: 未設→~/Movies/anypaint",
              RecordOutputService.saveDirectoryPath(saveDirectory: nil, home: "/Users/tester"),
              "/Users/tester/Movies/anypaint")
    T.checkEq("saveDir: 空→預設",
              RecordOutputService.saveDirectoryPath(saveDirectory: "", home: "/Users/tester"),
              "/Users/tester/Movies/anypaint")
    T.checkEq("saveDir: ~/foo 展開",
              RecordOutputService.saveDirectoryPath(saveDirectory: "~/foo", home: "/Users/tester"),
              "/Users/tester/foo")
    T.checkEq("saveDir: 絕對原樣",
              RecordOutputService.saveDirectoryPath(saveDirectory: "/tmp/rec", home: "/Users/tester"), "/tmp/rec")

    // AudioInputVolume.clamped（輸入音量 clamp）
    T.checkEq("inputVol: 負→0", AudioInputVolume.clamped(-0.5), 0)
    T.checkEq("inputVol: >1→1", AudioInputVolume.clamped(1.7), 1)
    T.checkEq("inputVol: 範圍內原樣", AudioInputVolume.clamped(0.6), 0.6)
}
