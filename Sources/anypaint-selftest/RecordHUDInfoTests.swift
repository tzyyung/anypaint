import AnypaintKit

/// RecordHUDInfo：錄影 HUD 資訊列文字（存檔位置/區域尺寸/檔案大小）純函式。
nonisolated func recordHUDInfoTests() {
    // saveLocation
    T.checkEq("hudInfo: 未設→預設", RecordHUDInfo.saveLocation(nil), "~/Movies/anypaint")
    T.checkEq("hudInfo: 空字串→預設", RecordHUDInfo.saveLocation(""), "~/Movies/anypaint")
    T.checkEq("hudInfo: 有設→原樣", RecordHUDInfo.saveLocation("/tmp/rec"), "/tmp/rec")

    // regionText
    T.checkEq("hudInfo: 區域尺寸", RecordHUDInfo.regionText(widthPx: 800, heightPx: 600), "800×600 px")

    // armedInfo
    T.checkEq("hudInfo: 待命資訊",
              RecordHUDInfo.armedInfo(saveDirectory: nil, widthPx: 800, heightPx: 600),
              "存至 ~/Movies/anypaint · 800×600 px")

    // fileSizeText
    T.checkEq("hudInfo: B", RecordHUDInfo.fileSizeText(bytes: 512), "512 B")
    T.checkEq("hudInfo: KB", RecordHUDInfo.fileSizeText(bytes: 2048), "2 KB")
    T.checkEq("hudInfo: MB", RecordHUDInfo.fileSizeText(bytes: 3 * 1024 * 1024), "3.0 MB")
    // 邊界（審查 #2）：kb∈[1023.5,1024) 不可印成「1024 KB」，要滾進 MB
    T.checkEq("hudInfo: 1024KB 邊界→MB", RecordHUDInfo.fileSizeText(bytes: 1_048_320), "1.0 MB")   // 1023.75 KB
    T.checkEq("hudInfo: 1023KB 仍 KB", RecordHUDInfo.fileSizeText(bytes: 1_047_552), "1023 KB")     // 1023.0 KB

    // recordingInfo（有/無 size）
    T.checkEq("hudInfo: 錄制資訊無大小",
              RecordHUDInfo.recordingInfo(widthPx: 640, heightPx: 480, bytes: nil), "640×480 px")
    T.checkEq("hudInfo: 錄制資訊含大小",
              RecordHUDInfo.recordingInfo(widthPx: 640, heightPx: 480, bytes: 1024 * 1024), "640×480 px · 1.0 MB")

    // 完成態（取代 RecordSavedNotice.message；統一 morph 工具列的錄後文字）
    T.checkTrue("hudInfo: done 標題成功含完成", RecordHUDInfo.doneTitle(success: true).contains("完成"))
    T.checkTrue("hudInfo: done 標題失敗含失敗", RecordHUDInfo.doneTitle(success: false).contains("失敗"))
    T.checkEq("hudInfo: 時長 mm:ss", RecordHUDInfo.durationText(67), "01:07")
    T.checkEq("hudInfo: 時長個位補零", RecordHUDInfo.durationText(7), "00:07")
    T.checkEq("hudInfo: 時長小數 floor（對齊即時時鐘）", RecordHUDInfo.durationText(6.7), "00:06")
    T.checkEq("hudInfo: 時長負值 clamp 0", RecordHUDInfo.durationText(-3), "00:00")
    T.checkEq("hudInfo: done 資訊列", RecordHUDInfo.doneInfo(saveDirectory: nil), "已存至 ~/Movies/anypaint")
    T.checkEq("hudInfo: done 中繼",
              RecordHUDInfo.doneMeta(durationSec: 7, widthPx: 800, heightPx: 600, bytes: 3 * 1024 * 1024 + 209715),
              "⏱ 00:07 · 800×600 px · 3.2 MB")

    // RecordDonePolicy（收起策略純值）
    T.checkEq("donePolicy: 自動收起 15s", RecordDonePolicy.dismissAfterSeconds, 15)
    T.checkTrue("donePolicy: 播放後收面板", RecordDonePolicy.dismissesPanel(after: .play))
    T.checkTrue("donePolicy: 重錄後收面板", RecordDonePolicy.dismissesPanel(after: .reRecord))
    T.checkTrue("donePolicy: 關閉後收面板", RecordDonePolicy.dismissesPanel(after: .close))
    T.checkTrue("donePolicy: 拖曳不收面板", !RecordDonePolicy.dismissesPanel(after: .drag))
}
