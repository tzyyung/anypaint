import Foundation

/// 框選中可自訂的功能。raw value 同時作為 UserDefaults key 後綴，不可隨意改名。
public enum OverlayAction: String, CaseIterable, Sendable {
    case reshoot = "reshoot"
    case pickColor = "pickColor"
    case save = "save"
    case saveAs = "saveAs"
    case saveAndOpen = "saveAndOpen"
    case recognizeText = "recognizeText"
}

/// 修飾鍵集合。刻意不用 `NSEvent.ModifierFlags`——解析要能在無 AppKit 的純邏輯測試裡跑，
/// 且 NSEvent 的 flags 含 capsLock/function/numericPad 等雜訊位，直接比對會不穩。
public struct OverlayModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = OverlayModifiers(rawValue: 1 << 0)
    public static let shift   = OverlayModifiers(rawValue: 1 << 1)
    public static let control = OverlayModifiers(rawValue: 1 << 2)
    public static let option  = OverlayModifiers(rawValue: 1 << 3)
}

/// 一組綁定：字元＋修飾鍵。字元一律小寫（`init` 內正規化）。
public struct OverlayKeyBinding: Equatable, Codable, Sendable {
    public let character: String
    public let modifiers: OverlayModifiers

    public init(character: String, modifiers: OverlayModifiers) {
        self.character = character.lowercased()
        self.modifiers = modifiers
    }
}

public enum OverlayKeyBindings {
    /// 預設值＝改動前寫死在 SelectionOverlayController 的那一組，手感不變。
    public static let defaults: [OverlayAction: OverlayKeyBinding] = [
        .reshoot:       OverlayKeyBinding(character: "r", modifiers: []),
        .pickColor:     OverlayKeyBinding(character: "c", modifiers: []),
        .save:          OverlayKeyBinding(character: "s", modifiers: [.command]),
        .saveAs:        OverlayKeyBinding(character: "s", modifiers: [.command, .shift]),
        .saveAndOpen:   OverlayKeyBinding(character: "o", modifiers: [.command]),
        .recognizeText: OverlayKeyBinding(character: "t", modifiers: [.command]),
    ]

    /// 固定求值順序，先中者勝。互撞時後面那個永遠輪不到——這是設定頁要提示的事。
    public static let evaluationOrder: [OverlayAction] = [
        .reshoot, .pickColor, .save, .saveAs, .saveAndOpen, .recognizeText,
    ]

    /// 純解析：按下的字元＋修飾鍵 → 動作。修飾鍵必須完全相等。
    /// 情境守門（文字編輯中、組字中、有無有效選區）不在這裡，留給呼叫端。
    public static func resolve(character: String,
                              modifiers: OverlayModifiers,
                              bindings: [OverlayAction: OverlayKeyBinding]) -> OverlayAction? {
        let key = character.lowercased()
        for action in evaluationOrder {
            guard let b = bindings[action] else { continue }
            if b.character == key && b.modifiers == modifiers { return action }
        }
        return nil
    }

    /// 找出被遮蔽的動作：某動作的綁定與求值順序更前面的動作相同時，它永遠不會被觸發。
    /// 回傳 [被遮蔽的動作: 搶到它的動作]。
    public static func shadowed(in bindings: [OverlayAction: OverlayKeyBinding]) -> [OverlayAction: OverlayAction] {
        var result: [OverlayAction: OverlayAction] = [:]
        for (index, action) in evaluationOrder.enumerated() {
            guard let b = bindings[action] else { continue }
            for earlier in evaluationOrder[..<index] {
                guard let e = bindings[earlier] else { continue }
                if e.character == b.character && e.modifiers == b.modifiers {
                    result[action] = earlier
                    break
                }
            }
        }
        return result
    }
}
