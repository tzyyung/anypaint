import Foundation

/// 捲動軌跡：把 30fps 的影格序列當成**時間序列**而不是一堆互不相關的單張影像。
///
/// ### 為什麼需要它
/// 相鄰兩格的位移小（慢捲時 2–8px）、重疊 95% 以上，是歧義幾乎為零的最容易題目；
/// 而「這格對長圖尾端」的位移大，是歧義最大的題目。既有實作只解後者，於是要在
/// 一個很大的搜尋範圍裡找峰——等行距內容的週期解就落在那個範圍內。
///
/// 軌跡把兩件事分開：用 frame-to-frame 的容易題目累積出**預測位移**，
/// 再用它把難題目的搜尋窗縮到 ±12px——週期解根本進不了窗。
///
/// ### drift 為什麼不會累積進長圖
/// f2f 每格有 ±1px 誤差，串接 30 格就是 ±30px。所以軌跡**只用來縮小搜尋窗**，
/// 真正寫進長圖的位移永遠由「對長圖尾端的原解析度全列 ZNCC」裁決；
/// `commit(actualDy:)` 收到絕對匹配的結果後會把 `pendingDy` 歸零，
/// 等於每次接合都把累積誤差清掉一次。這是文獻上 pairwise＋校正的組合——
/// 只做 pairwise 串接才會 drift（Civera et al., IJCV 2009）。
public struct ScrollTrajectory: Equatable, Sendable {
    /// 自上次接合（或 session 起點）以來的 f2f 累積步進＝**對長圖尾端的預測位移**。
    /// 正＝下捲、負＝回捲。
    public private(set) var pendingDy = 0
    /// 上次的步進值，當作下次步進搜尋的中心（捲動速度短時間內是連續的）。
    /// nil＝尚未有任何步進（開場第一格）。
    public private(set) var lastStep: Int?
    /// 診斷用：f2f 視角的總累積量。
    public private(set) var totalTracked = 0
    /// 診斷用：實際寫進長圖的總量。與 `totalTracked` 的差就是 f2f 的累積 drift，
    /// 兩者長期背離代表 f2f 在撞假峰（寫進 session 診斷）。
    public private(set) var totalCommitted = 0
    /// 診斷用：連續多少格沒能提交（無資訊／匹配失敗都會累積）。
    public private(set) var pendingSteps = 0

    public init() {}

    /// 診斷用：連續用速度推測（而非真實影像匹配）的格數。
    public private(set) var assumedRun = 0

    /// 記錄一次 frame-to-frame 步進。**只累積，不裁決**。
    public mutating func recordStep(_ dy: Int) {
        pendingDy += dy
        totalTracked += dy
        lastStep = dy
        pendingSteps += 1
        assumedRun = 0
    }

    /// 步進估計失敗時，依速度連續性推進一格。
    ///
    /// 必要性（實機自檢）：稀疏內容下每隔幾格就會有一格的重疊區剛好沒有可辨識特徵，
    /// f2f 估不出。若讓軌跡就此停滯，那格的位移會永久遺失——實測每 9 格一次、
    /// 共丟掉 4 格 ×180px。畫面確實在動（影像指紋 gate 已經確認過），只是這一格估不準。
    ///
    /// 與舊版「用上次位移猜速度」的關鍵差異，這也是它不會重演過量 47% 的原因：
    /// ① 推測只進入**軌跡**，不直接接上——最終仍要經 rescue 的閘門判斷；
    /// ② 連續推測有上限，估不出的情況一旦持續就停止盲推；
    /// ③ 不更新 `lastStep`，所以速度基準永遠來自真實的影像匹配，推測不會自我增強。
    /// - Returns: 是否真的推進了（false＝沒有速度基準，或已達連續推測上限）。
    @discardableResult
    public mutating func recordAssumedStep(maxConsecutive: Int) -> Bool {
        guard let last = lastStep, last != 0, assumedRun < maxConsecutive else { return false }
        pendingDy += last
        totalTracked += last
        pendingSteps += 1
        assumedRun += 1
        return true
    }

    /// 接合成功：從預測量裡扣掉已經接上的部分。
    ///
    /// **不可直接歸零**（實機自檢抓到的錯）：原本假設 `actualDy ≈ pendingDy`，於是把預測歸零
    /// 當作「清掉 f2f 的累積 drift」。但當這格的位移被上限夾住、或 matcher 只匹配到較小的
    /// 位移時，差額是**還沒接上的真實內容**而不是誤差——歸零等於讓那段內容永久消失。
    /// 實測（稀疏＋大步進自檢）：f2f 正確估出每格 180px，只接上 132px，被歸零丟掉的 48px
    /// 累積成 44% 的內容遺失。
    ///
    /// 餘額如何分辨「drift」與「沒接完」：小於可信位移下限的餘額視為 f2f 的累積誤差而清掉，
    /// 否則保留給下一格繼續接。這樣正常情況下 drift 仍然每次被吸收，而被夾住時內容不遺失。
    /// - Parameters:
    ///   - actualDy: matcher 對長圖尾端裁決出的真實位移，可正可負（負＝回捲裁尾）。
    ///   - minTrustworthy: 可信位移下限（等同 matcher 的 minDelta）。
    public mutating func commit(actualDy: Int, minTrustworthy: Int = 14) {
        let remainder = pendingDy - actualDy
        pendingDy = abs(remainder) >= minTrustworthy ? remainder : 0
        pendingSteps = 0
        totalCommitted += actualDy
    }

    /// 回捲已到 session 起點：長圖無法再裁，預測量沒有意義了。
    public mutating func resetToOrigin() {
        pendingDy = 0
        pendingSteps = 0
        lastStep = nil
    }

    /// 步進搜尋窗（原解析度像素）。以上次步進為中心；使用者加速時窗要跟著放大，
    /// 且背壓丟格時「上一格」可能不是真正的相鄰格（位移會是好幾格的總和），
    /// 所以半徑至少 `minRadius`，並隨上次步進的量成比例放大。
    public func stepSearchWindow(minRadius: Int = 12) -> (center: Int, radius: Int) {
        guard let last = lastStep else { return (0, 0) }   // radius 0＝呼叫端該走全域小範圍掃
        return (last, max(minRadius, abs(last) / 2))
    }

    /// 現在就必須接上嗎？判準是「**再等一格**會不會超過上限」，不是「現在有沒有超過」。
    ///
    /// 這個區別是實機自檢抓到的（達成率卡在 83%）：原本寫成 `pendingDy >= maxDy` 才接，
    /// 於是 pending=180、上限 228 時判定「還有餘裕」而等下一格——下一格 pending 變 360，
    /// 遠超上限，只好截到 228，每次白白丟掉 132px。捲動速度短時間內是連續的，
    /// 所以用上一次的步進量當「下一格會再前進多少」的估計。
    public func mustCommitNow(maxDy: Int) -> Bool {
        guard maxDy > 0 else { return false }
        return abs(pendingDy) + abs(lastStep ?? 0) >= maxDy
    }
}
