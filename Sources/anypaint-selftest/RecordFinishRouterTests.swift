import AnypaintKit

/// RecordFinishRouter：錄影收尾終端動作決策（outcome × direct × 存檔成敗）窮舉。
nonisolated func recordFinishRouterTests() {
    typealias R = RecordFinishRouter
    func act(_ c: R.Category, _ direct: Bool, _ saved: Bool) -> R.Action {
        R.action(category: c, direct: direct, saveSucceeded: saved)
    }

    // 取消：不論 direct/存檔皆 .none（HUD 已在 session 完整 teardown dismiss）
    T.checkEq("finish: 取消(direct)→none", act(.cancelled, true, false), .none)
    T.checkEq("finish: 取消(direct,saved旗標無意義)→none", act(.cancelled, true, true), .none)
    T.checkEq("finish: 取消(動畫)→none", act(.cancelled, false, false), .none)

    // 失敗：錄影→失敗面板；動畫截圖→只收 HUD（對抗式審查 #3）
    T.checkEq("finish: 失敗+錄影→presentDoneFailed", act(.failed, true, false), .presentDoneFailed)
    T.checkEq("finish: 失敗+動畫→dismissOnly", act(.failed, false, false), .dismissOnly)

    // 成功：
    //  動畫截圖→開預覽（不看 saveSucceeded）
    T.checkEq("finish: 成功+動畫→openPreview", act(.saved, false, false), .openPreview)
    T.checkEq("finish: 成功+動畫(saved旗標無意義)→openPreview", act(.saved, false, true), .openPreview)
    //  錄影+存檔成功→完成面板；錄影+存檔失敗→失敗面板（對抗式審查 #2/#3）
    T.checkEq("finish: 成功+錄影+存檔成功→presentDone", act(.saved, true, true), .presentDone)
    T.checkEq("finish: 成功+錄影+存檔失敗→presentDoneFailed", act(.saved, true, false), .presentDoneFailed)
}
