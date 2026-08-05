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

func overlayKeyBindingConflictTests() {
    T.checkTrue("預設值無互撞", OverlayKeyBindings.shadowed(in: OverlayKeyBindings.defaults).isEmpty)

    var clash = OverlayKeyBindings.defaults
    clash[.recognizeText] = OverlayKeyBinding(character: "s", modifiers: [.command])
    let s1 = OverlayKeyBindings.shadowed(in: clash)
    T.checkEq("辨識文字被存檔遮蔽", s1[.recognizeText], .save)
    T.checkEq("只報一筆", s1.count, 1)

    // 修飾鍵不同不算互撞
    var shifted = OverlayKeyBindings.defaults
    shifted[.recognizeText] = OverlayKeyBinding(character: "s", modifiers: [.command, .option])
    T.checkTrue("⌥⌘s 與 ⌘s 不算互撞", OverlayKeyBindings.shadowed(in: shifted).isEmpty)

    // 三個相撞：後兩個都被最前面那個遮蔽
    var triple = OverlayKeyBindings.defaults
    triple[.saveAndOpen] = OverlayKeyBinding(character: "r", modifiers: [])
    triple[.recognizeText] = OverlayKeyBinding(character: "r", modifiers: [])
    let s2 = OverlayKeyBindings.shadowed(in: triple)
    T.checkEq("存檔並開啟被重拍遮蔽", s2[.saveAndOpen], .reshoot)
    T.checkEq("辨識文字被重拍遮蔽", s2[.recognizeText], .reshoot)
    T.checkEq("共兩筆", s2.count, 2)
}

func overlayKeyBindingStoreTests() {
    // 獨立 suite，跑完清掉——不可寫進 com.aidaris.anypaint
    let suiteName = "anypaint.selftest.overlayKeys"
    let store = UserDefaults(suiteName: suiteName)!
    for a in OverlayAction.allCases { store.removeObject(forKey: "overlayKey.\(a.rawValue)") }

    T.checkEq("未設定時回預設",
              OverlayKeyBindings.binding(for: .recognizeText, store: store),
              OverlayKeyBindings.defaults[.recognizeText]!)

    let custom = OverlayKeyBinding(character: "y", modifiers: [.command, .option])
    OverlayKeyBindings.setBinding(custom, for: .recognizeText, store: store)
    T.checkEq("寫入後讀回同值",
              OverlayKeyBindings.binding(for: .recognizeText, store: store), custom)
    T.checkEq("其他動作不受影響",
              OverlayKeyBindings.binding(for: .save, store: store),
              OverlayKeyBindings.defaults[.save]!)

    OverlayKeyBindings.clear(.recognizeText, store: store)
    T.checkEq("清除後回預設",
              OverlayKeyBindings.binding(for: .recognizeText, store: store),
              OverlayKeyBindings.defaults[.recognizeText]!)

    // 存壞資料 → 回預設，不崩
    store.set("not json", forKey: "overlayKey.save")
    T.checkEq("資料損毀時回預設",
              OverlayKeyBindings.binding(for: .save, store: store),
              OverlayKeyBindings.defaults[.save]!)

    OverlayKeyBindings.setBinding(custom, for: .pickColor, store: store)
    T.checkEq("all() 含自訂值", OverlayKeyBindings.all(store: store)[.pickColor], custom)
    T.checkEq("all() 涵蓋所有動作",
              Set(OverlayKeyBindings.all(store: store).keys), Set(OverlayAction.allCases))

    for a in OverlayAction.allCases { store.removeObject(forKey: "overlayKey.\(a.rawValue)") }
    UserDefaults.standard.removeSuite(named: suiteName)
}
