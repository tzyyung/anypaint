import AnypaintKit

/// 零散純函式：AppActiveMode 優先序、FilenameTemplate.normalizedPathTemplate、
/// OverlayKeyRecorderField.isUnrepresentablePrivateUse。
nonisolated func miscPureTests() {
    // AppActiveMode.resolve：freeze > scroll > record > none
    T.checkEq("activeMode: freeze 最優先",
              AppActiveMode.resolve(freeze: true, scroll: true, record: true), .freeze)
    T.checkEq("activeMode: scroll 次之", AppActiveMode.resolve(freeze: false, scroll: true, record: true), .scroll)
    T.checkEq("activeMode: record", AppActiveMode.resolve(freeze: false, scroll: false, record: true), .record)
    T.checkEq("activeMode: 皆無→none", AppActiveMode.resolve(freeze: false, scroll: false, record: false), .none)

    // FilenameTemplate.normalizedPathTemplate（原 OutputSettings 內嵌）
    T.checkEq("pathNorm: 相對路徑補 ~/", FilenameTemplate.normalizedPathTemplate("  a/b "), "~/a/b")
    T.checkEq("pathNorm: 絕對路徑原樣", FilenameTemplate.normalizedPathTemplate("/x/y"), "/x/y")
    T.checkEq("pathNorm: ~ 開頭原樣", FilenameTemplate.normalizedPathTemplate("~/x"), "~/x")
    T.checkEq("pathNorm: 空→空", FilenameTemplate.normalizedPathTemplate("   "), "")

    // OverlayKeyRecorderField.isUnrepresentablePrivateUse
    // 0xF700=NSUpArrowFunctionKey(有名)→false；一般字元→false；未命名 PUA(如 0xF8FF)→true
    T.checkTrue("PUA: 一般字元 'a'→false", !OverlayKeyRecorderField.isUnrepresentablePrivateUse("a"))
    let upArrow = String(UnicodeScalar(0xF700)!)
    T.checkTrue("PUA: 0xF700(上箭頭,有名)→false", !OverlayKeyRecorderField.isUnrepresentablePrivateUse(upArrow))
    let unnamed = String(UnicodeScalar(0xF8FF)!)   // Apple logo PUA,無特殊鍵名
    T.checkTrue("PUA: 未命名 PUA→true", OverlayKeyRecorderField.isUnrepresentablePrivateUse(unnamed))
    T.checkTrue("PUA: 多字元→false", !OverlayKeyRecorderField.isUnrepresentablePrivateUse("ab"))

    // FilenameTemplate.ensureAbsolute（原 CaptureOutputService/OutputSettings 內嵌）
    T.checkEq("ensureAbs: 絕對路徑原樣", FilenameTemplate.ensureAbsolute("/a/b", home: "/Users/x"), "/a/b")
    T.checkEq("ensureAbs: 相對補家目錄", FilenameTemplate.ensureAbsolute("a/b", home: "/Users/x"), "/Users/x/a/b")

    // FilenameTemplate.previewWithPNGHint（原 OutputSettings.previewText 後綴）
    T.checkEq("pngHint: 無 .png 補提示",
              FilenameTemplate.previewWithPNGHint(expandedText: "~/a", template: "$title$"), "~/a（將自動補 .png）")
    T.checkEq("pngHint: 有 .png 不補",
              FilenameTemplate.previewWithPNGHint(expandedText: "~/a.png", template: "x.png"), "~/a.png")

    // UITestServer.shouldStart
    T.checkTrue("shouldStart: --uitest→true", UITestServer.shouldStart(args: ["x", "--uitest"], allowSetting: false))
    T.checkTrue("shouldStart: 設定允許→true", UITestServer.shouldStart(args: ["x"], allowSetting: true))
    T.checkTrue("shouldStart: 皆無→false", !UITestServer.shouldStart(args: ["x"], allowSetting: false))

    // AudioInputDeviceList.popupSelection
    let ids = ["mic-a", "mic-b", "mic-c"]
    let p1 = AudioInputDeviceList.popupSelection(saved: "mic-b", deviceIDs: ids)
    T.checkTrue("micPopup: 存在裝置→非幽靈", !p1.isGhost)
    T.checkEq("micPopup: 選到 index+1", p1.index, 2)   // mic-b 是 index1 → popup index2
    let p2 = AudioInputDeviceList.popupSelection(saved: "ghost-x", deviceIDs: ids)
    T.checkTrue("micPopup: 不存在→幽靈", p2.isGhost)
    T.checkEq("micPopup: 幽靈→回系統預設(0)", p2.index, 0)
    let p3 = AudioInputDeviceList.popupSelection(saved: nil, deviceIDs: ids)
    T.checkTrue("micPopup: nil→非幽靈", !p3.isGhost)
    T.checkEq("micPopup: nil→系統預設(0)", p3.index, 0)

    // RecordSession.cancelAction：狀態→動作
    T.checkEq("cancelAction: 錄影中→stop", RecordSession.cancelAction(for: .recording), .stop)
    T.checkEq("cancelAction: armed→cancel", RecordSession.cancelAction(for: .armed), .cancel)
    T.checkEq("cancelAction: selecting→cancel", RecordSession.cancelAction(for: .selecting), .cancel)
    T.checkEq("cancelAction: finishing→cancel", RecordSession.cancelAction(for: .finishing), .cancel)
    T.checkEq("cancelAction: idle→none", RecordSession.cancelAction(for: .idle), .none)

    // FilenameTemplate.chooseAppName
    T.checkEq("appName: Finder 名優先", FilenameTemplate.chooseAppName(finderName: "預覽程式", fileName: "Preview", bundleNames: ["X"]), "預覽程式")
    T.checkEq("appName: Finder 名等於檔名→用 bundle", FilenameTemplate.chooseAppName(finderName: "Preview", fileName: "Preview", bundleNames: ["", "顯示名"]), "顯示名")
    T.checkEq("appName: 都沒有→退回檔名", FilenameTemplate.chooseAppName(finderName: "", fileName: "Preview", bundleNames: []), "Preview")
}
