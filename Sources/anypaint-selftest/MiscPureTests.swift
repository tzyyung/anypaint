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
}
