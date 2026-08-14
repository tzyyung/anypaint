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

    // recordingInfo（有/無 size）
    T.checkEq("hudInfo: 錄制資訊無大小",
              RecordHUDInfo.recordingInfo(widthPx: 640, heightPx: 480, bytes: nil), "640×480 px")
    T.checkEq("hudInfo: 錄制資訊含大小",
              RecordHUDInfo.recordingInfo(widthPx: 640, heightPx: 480, bytes: 1024 * 1024), "640×480 px · 1.0 MB")
}
