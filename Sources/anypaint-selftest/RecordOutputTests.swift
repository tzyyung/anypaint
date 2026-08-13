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
}
