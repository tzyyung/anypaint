import KeyboardShortcuts

/// 全域快鍵的具名定義。使用者可在設定頁改鍵，KeyboardShortcuts 會自動存 UserDefaults。
/// 底層一樣是 Carbon RegisterEventHotKey，不需輔助使用權限。
public extension KeyboardShortcuts.Name {
    /// 截圖（預設 ⌘⇧A）
    static let capture = Self("capture", default: .init(.a, modifiers: [.command, .shift]))
    /// 貼圖（預設 ⌘⇧V）
    static let pin = Self("pin", default: .init(.v, modifiers: [.command, .shift]))
    /// 滾動截圖（預設 ⌘⇧X——⌘⇧S 會撞自家框選「另存為」與系統 Duplicate，spec D1）
    static let scrollCapture = Self("scrollCapture", default: .init(.x, modifiers: [.command, .shift]))
    /// 動畫截圖（預設 ⌘⇧R——R=record，不撞既有 A/V/X；框選內的 R 重拍是 overlay 本地鍵、非全域，不衝突）
    static let animatedCapture = Self("animatedCapture", default: .init(.r, modifiers: [.command, .shift]))
    /// 錄影（預設 ⌘⇧M——M=Movie，避開已用的 A/V/X/R；直接落地存 MP4,不開預覽）
    static let record = Self("record", default: .init(.m, modifiers: [.command, .shift]))
}
