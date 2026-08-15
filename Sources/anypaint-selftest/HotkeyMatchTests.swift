import AnypaintKit

/// HotkeyMatch（CGEventTap 攔截路徑的純比對邏輯）。
nonisolated func hotkeyMatchTests() {
    // 位元定義：⌘⇧⌥⌃ 四鍵（與 CGEventFlags/NSEvent.ModifierFlags 同位）
    let cmd: UInt = 1 << 20, shift: UInt = 1 << 17, opt: UInt = 1 << 19, ctrl: UInt = 1 << 18
    let caps: UInt = 1 << 16   // 應被忽略

    // normalizedModifiers：只留四鍵,caps/其餘位元濾掉
    T.checkEq("hotkey: normalize 留 ⌘⇧", HotkeyMatch.normalizedModifiers(fromRawFlags: UInt64(cmd | shift)), cmd | shift)
    T.checkEq("hotkey: normalize 濾掉 capsLock", HotkeyMatch.normalizedModifiers(fromRawFlags: UInt64(cmd | shift | caps)), cmd | shift)
    T.checkEq("hotkey: normalize 濾掉高位雜訊", HotkeyMatch.normalizedModifiers(fromRawFlags: UInt64(cmd) | (1 << 23)), cmd)

    // 綁定表：截圖 ⌘⇧A(keyCode 0)、錄影 ⌘⇧M(keyCode 46)
    let bindings = [
        HotkeyMatch.Binding(name: "capture", keyCode: 0, modifiers: cmd | shift),
        HotkeyMatch.Binding(name: "record", keyCode: 46, modifiers: cmd | shift),
    ]
    // 完全相符才命中
    T.checkEq("hotkey: ⌘⇧A→capture", HotkeyMatch.matchName(keyCode: 0, modifiers: cmd | shift, among: bindings), "capture")
    T.checkEq("hotkey: ⌘⇧M→record", HotkeyMatch.matchName(keyCode: 46, modifiers: cmd | shift, among: bindings), "record")
    // caps lock 一起按也要命中（正規化後忽略 caps）
    T.checkEq("hotkey: ⌘⇧A＋capsLock 仍命中", HotkeyMatch.matchName(keyCode: 0, modifiers: cmd | shift | caps, among: bindings), "capture")
    // 修飾鍵不足→不命中（單按 ⌘A 不該觸發 ⌘⇧A）
    T.checkTrue("hotkey: ⌘A 不命中 ⌘⇧A", HotkeyMatch.matchName(keyCode: 0, modifiers: cmd, among: bindings) == nil)
    // 修飾鍵過多→不命中（⌘⇧⌥A 不是 ⌘⇧A）
    T.checkTrue("hotkey: ⌘⇧⌥A 不命中 ⌘⇧A", HotkeyMatch.matchName(keyCode: 0, modifiers: cmd | shift | opt, among: bindings) == nil)
    // 對的修飾鍵、錯的鍵→不命中
    T.checkTrue("hotkey: ⌘⇧B(keyCode 11) 不命中", HotkeyMatch.matchName(keyCode: 11, modifiers: cmd | shift, among: bindings) == nil)
    // ctrl 不是 cmd
    T.checkTrue("hotkey: ⌃⇧A 不命中 ⌘⇧A", HotkeyMatch.matchName(keyCode: 0, modifiers: ctrl | shift, among: bindings) == nil)
    // 空綁定表→nil
    T.checkTrue("hotkey: 空表→nil", HotkeyMatch.matchName(keyCode: 0, modifiers: cmd | shift, among: []) == nil)
}
