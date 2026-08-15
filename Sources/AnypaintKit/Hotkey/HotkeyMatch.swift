import Foundation

/// 全域快鍵比對的純邏輯（CGEventTap 攔截路徑用）。**不 import AppKit/CoreGraphics**——
/// 只吃裸整數（keyCode、修飾鍵位元），讓 selftest 可在無框架環境驗。
///
/// 修飾鍵位元：`CGEventFlags` 與 `NSEvent.ModifierFlags` 的 ⌘⇧⌥⌃ 四個位元**同位**（都源自同一組
/// CG 常數），所以 tap callback 拿到的 `CGEventFlags.rawValue` 與 KeyboardShortcuts `Shortcut.modifiers`
/// （`NSEvent.ModifierFlags`）遮成同一個 mask 後可直接比。caps lock／fn／numpad 等其餘位元一律忽略。
public enum HotkeyMatch {
    /// device-independent 修飾鍵遮罩：shift(1<<17)｜control(1<<18)｜option(1<<19)｜command(1<<20)。
    public static let modifierMask: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    /// 一組快鍵綁定：名稱（KeyboardShortcuts.Name.rawValue）＋虛擬 keyCode＋修飾鍵位元。
    public struct Binding: Equatable {
        public let name: String
        public let keyCode: Int
        public let modifiers: UInt
        public init(name: String, keyCode: Int, modifiers: UInt) {
            self.name = name; self.keyCode = keyCode; self.modifiers = modifiers
        }
    }

    /// `CGEventFlags.rawValue`（UInt64）→ 只留 ⌘⇧⌥⌃ 的正規化修飾鍵位元。
    public static func normalizedModifiers(fromRawFlags raw: UInt64) -> UInt {
        UInt(raw & UInt64(modifierMask))
    }

    /// 比對一個按鍵事件命中哪顆快鍵：keyCode 相等且修飾鍵（遮成四鍵後）**完全相符**才算。
    /// 完全相符（不是子集）——⌘⇧A 不該被單按 ⌘A 或多按 ⌘⇧⌥A 命中。回命中名稱,無則 nil。
    /// 多顆綁定撞同鍵時回**第一個**命中（呼叫端 binding 順序決定；正常設定不會重複）。
    public static func matchName(keyCode: Int, modifiers: UInt, among bindings: [Binding]) -> String? {
        let m = modifiers & modifierMask
        for b in bindings where b.keyCode == keyCode && (b.modifiers & modifierMask) == m {
            return b.name
        }
        return nil
    }
}
