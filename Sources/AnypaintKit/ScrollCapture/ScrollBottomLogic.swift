import CoreGraphics

/// 滾動截圖 session 的**純決策**（滾輪方向、到底探測狀態機）——與計時器/HUD/NSEvent 無關,可測。
public enum ScrollBottomLogic {

    /// 滾輪方向：deltaY<0＝下捲(+1)、>0＝上捲(-1)、0＝無變化(nil,維持前值)。
    /// AppKit 慣例：deltaY<0＝內容上移＝頁面下捲（自然捲動）。
    public static func wheelDirection(deltaY: CGFloat) -> Int? {
        deltaY == 0 ? nil : (deltaY < 0 ? 1 : -1)
    }

    /// 到底探測的下一步（bottomTick 的純核心）。
    /// - finish：停滯過久,或探測已滿次數 → 收工。
    /// - wait：本輪條件未滿（沒滾輪 or 影格還在流）→ 繼續等；影格還在流時 probeCount 已歸零。
    /// - probe：累計一次探測（顯示「已到底,收尾中」）,還沒到門檻。
    /// - requestBackscroll：品質有疑慮 → 請使用者回捲確認（一次性,重置 probeCount）。
    public enum BottomTickResult: Equatable { case finish, wait, probe, requestBackscroll }

    public static func bottomTickDecision(stalledTooLong: Bool, framesStalled: Bool, wheelTicks: Int,
                                          probeCount: Int, hasQualityDoubt: Bool, backscrollRequested: Bool)
        -> (result: BottomTickResult, probeCount: Int, backscrollRequested: Bool) {
        if stalledTooLong { return (.finish, probeCount, backscrollRequested) }
        // 需要「滾輪說在捲」且「影格不再更新」兩條同時成立才算一次探測;影格還在流＝沒到底,歸零。
        guard wheelTicks > 0, framesStalled else {
            return (.wait, framesStalled ? probeCount : 0, backscrollRequested)
        }
        let n = probeCount + 1
        if n < 3 { return (.probe, n, backscrollRequested) }     // 約 1.5 秒「捲了但畫面不動」才判到底
        // 品質有疑慮 → 請回捲確認（只做一次）；否則直接收工。
        if hasQualityDoubt, !backscrollRequested { return (.requestBackscroll, 0, true) }
        return (.finish, n, backscrollRequested)
    }
}
