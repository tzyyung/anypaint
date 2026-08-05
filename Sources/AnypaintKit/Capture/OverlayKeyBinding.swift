import AppKit

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

    private enum CodingKeys: String, CodingKey { case character, modifiers }

    /// 不能用合成的 `Decodable`：那條路直接把存的字串指定給 `character`，繞過上面 init
    /// 的小寫正規化。舊資料（或使用者手改的 UserDefaults）裡若混進大寫字元，`resolve`
    /// 比對時一律轉小寫，會永遠比不中——動作因此悄悄失效，且無任何警示。改走正規化 init。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(character: try c.decode(String.self, forKey: .character),
                  modifiers: try c.decode(OverlayModifiers.self, forKey: .modifiers))
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

    private static func key(for action: OverlayAction) -> String { "overlayKey.\(action.rawValue)" }

    /// 讀綁定。沒設定、或存的資料解不出來 → 回預設值（不寫入，讓預設值保持可演進）。
    public static func binding(for action: OverlayAction,
                               store: UserDefaults = .standard) -> OverlayKeyBinding {
        let fallback = defaults[action]!
        guard let s = store.string(forKey: key(for: action)),
              let data = s.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OverlayKeyBinding.self, from: data)
        else { return fallback }
        return decoded
    }

    public static func setBinding(_ binding: OverlayKeyBinding,
                                  for action: OverlayAction,
                                  store: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(binding),
              let s = String(data: data, encoding: .utf8) else { return }
        store.set(s, forKey: key(for: action))
    }

    /// 清除＝移除項目，於是自然回到預設值。不存哨兵值，所以沒有「無綁定」狀態。
    public static func clear(_ action: OverlayAction, store: UserDefaults = .standard) {
        store.removeObject(forKey: key(for: action))
    }

    public static func all(store: UserDefaults = .standard) -> [OverlayAction: OverlayKeyBinding] {
        var result: [OverlayAction: OverlayKeyBinding] = [:]
        for a in OverlayAction.allCases { result[a] = binding(for: a, store: store) }
        return result
    }
}

extension OverlayModifiers {
    /// 只取四個關心的位元——NSEvent 的 flags 還含 capsLock/function/numericPad 等，
    /// 直接整包比對會因為那些雜訊位而永遠不相等。
    public init(event flags: NSEvent.ModifierFlags) {
        var m: OverlayModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        self = m
    }
}
