import AppKit
import AnypaintKit

func overlayKeyBindingResolveTests() {
    let d = OverlayKeyBindings.defaults

    // 預設值即現行行為
    T.checkEq("resolve 裸 r → 重拍",
              OverlayKeyBindings.resolve(character: "r", modifiers: [], bindings: d), .reshoot)
    T.checkEq("resolve 裸 c → 取色",
              OverlayKeyBindings.resolve(character: "c", modifiers: [], bindings: d), .pickColor)
    T.checkEq("resolve ⌘s → 存檔",
              OverlayKeyBindings.resolve(character: "s", modifiers: [.command], bindings: d), .save)
    T.checkEq("resolve ⇧⌘s → 另存為",
              OverlayKeyBindings.resolve(character: "s", modifiers: [.command, .shift], bindings: d), .saveAs)
    T.checkEq("resolve ⌘o → 存檔並開啟",
              OverlayKeyBindings.resolve(character: "o", modifiers: [.command], bindings: d), .saveAndOpen)
    T.checkEq("resolve ⌘t → 辨識文字",
              OverlayKeyBindings.resolve(character: "t", modifiers: [.command], bindings: d), .recognizeText)

    // 修飾鍵完全相等：⇧r 不再命中裸 r（spec 記載的刻意行為變更）
    T.checkEq("resolve ⇧r → 無（修飾鍵須完全相等）",
              OverlayKeyBindings.resolve(character: "r", modifiers: [.shift], bindings: d), nil)
    T.checkEq("resolve ⌃⌘s → 無（多了 control）",
              OverlayKeyBindings.resolve(character: "s", modifiers: [.command, .control], bindings: d), nil)
    T.checkEq("resolve 裸 s → 無（預設 save 需要 ⌘）",
              OverlayKeyBindings.resolve(character: "s", modifiers: [], bindings: d), nil)
    T.checkEq("resolve 未綁定的 z → 無",
              OverlayKeyBindings.resolve(character: "z", modifiers: [], bindings: d), nil)

    // 大小寫正規化：呼叫端可能傳入大寫
    T.checkEq("resolve 大寫 R 視為 r",
              OverlayKeyBindings.resolve(character: "R", modifiers: [], bindings: d), .reshoot)

    // 自訂值生效
    var custom = d
    custom[.recognizeText] = OverlayKeyBinding(character: "y", modifiers: [.command, .option])
    T.checkEq("自訂 ⌥⌘y → 辨識文字",
              OverlayKeyBindings.resolve(character: "y", modifiers: [.command, .option], bindings: custom), .recognizeText)
    T.checkEq("改掉之後舊的 ⌘t 失效",
              OverlayKeyBindings.resolve(character: "t", modifiers: [.command], bindings: custom), nil)

    // 求值順序：兩個動作同綁定時，順序在前者勝
    var clash = d
    clash[.recognizeText] = OverlayKeyBinding(character: "s", modifiers: [.command])
    T.checkEq("互撞時求值順序在前的 save 勝",
              OverlayKeyBindings.resolve(character: "s", modifiers: [.command], bindings: clash), .save)

    T.checkEq("evaluationOrder 涵蓋所有動作",
              Set(OverlayKeyBindings.evaluationOrder), Set(OverlayAction.allCases))
    T.checkEq("defaults 涵蓋所有動作",
              Set(OverlayKeyBindings.defaults.keys), Set(OverlayAction.allCases))
}
