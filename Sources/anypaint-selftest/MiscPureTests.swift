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
}
