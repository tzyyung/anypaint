import Foundation

/// 錄影收尾的終端 UI 動作決策（純函式,可測）。把 `AppDelegate.onFinished` 裡
/// 「outcome × direct × 存檔成敗」的分流抽出來——這正是對抗式審查 #1/#2/#3 的載重接縫
/// （單一還原出口之後、依結果決定顯示完成面板/失敗面板/預覽/收起），窮舉可測。
///
/// 注意：此函式**不含**「還原快鍵/選單」——那是無條件先做的單一出口，不在分流內（見 #1）。
public enum RecordFinishRouter {
    /// 收尾結果分類（對應 `RecordSession.Outcome` 的三類，去掉關聯值以保持純 Foundation、可測）。
    public enum Category: Equatable { case saved, failed, cancelled }

    /// 終端動作。
    public enum Action: Equatable {
        case presentDone          // 錄影成功存檔 → 完成面板（同一 HUD morph）
        case presentDoneFailed    // 錄影失敗（收尾失敗 or 存檔失敗）→ 失敗面板
        case openPreview          // 動畫截圖成功 → 開預覽（先收 HUD）
        case dismissOnly          // 收 HUD,不顯示任何完成面板（動畫截圖失敗）
        case none                 // 取消：HUD 已在 session 完整 teardown 中 dismiss,這裡不動
    }

    /// - Parameters:
    ///   - category: session 收尾結果分類。
    ///   - direct: true＝錄影（完成面板）；false＝動畫截圖（預覽）。
    ///   - saveSucceeded: 僅 `.saved && direct` 有意義——`saveMovie` 是否成功（對抗式審查 #2/#3：
    ///     存檔失敗也要走失敗面板，不能顯示指向不存在檔案的成功面板）。
    public static func action(category: Category, direct: Bool, saveSucceeded: Bool) -> Action {
        switch category {
        case .cancelled:
            return .none
        case .failed:
            return direct ? .presentDoneFailed : .dismissOnly
        case .saved:
            if !direct { return .openPreview }
            return saveSucceeded ? .presentDone : .presentDoneFailed
        }
    }
}
