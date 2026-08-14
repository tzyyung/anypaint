import Foundation

/// 完成態（morph 工具列錄後）的純策略值：自動收起秒數＋終結動作分類。
/// 框架殼（NSPanel、DispatchWorkItem、NSWorkspace）不放這裡；這裡只有可測的純值/純函式。
public enum RecordDonePolicy {
    /// 安全自動收起秒數（非快關——正常靠使用者按按鈕/✕ 收）。見 spec §3.4。
    public static let dismissAfterSeconds: Double = 15

    /// 完成面板的動作。`play/reveal/copy/reRecord` 是「終結動作」（按下即收面板）；
    /// `close` 直接收；`drag` 不收（使用者可能連續拖到多個 app）。
    public enum Action: Equatable {
        case play, reveal, copy, reRecord, close, drag
    }

    /// 按下該動作後是否應收起完成面板（純邏輯,可測）。拖曳不收；其餘皆收。
    public static func dismissesPanel(after action: Action) -> Bool {
        action != .drag
    }
}
