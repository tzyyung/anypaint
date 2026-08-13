import CoreGraphics
import Foundation
import Vision

/// 一格影格的處理結果。Session 只依此更新 HUD／決定收尾，不重複演算法邏輯。
public enum ScrollStitchOutcome: Equatable, Sendable {
    /// 第一格：當長圖基準。
    case baseCaptured(height: Int)
    /// 畫面沒變（影像指紋相同），或軌跡累積的位移還不足以產生可信的接合——
    /// 跳過本格、**不計失敗**。等待是安全的：匹配基準是固定的長圖尾端，位移會累積到下一次一併接上。
    case waitingForMotion
    /// 靜態帶鎖定成功（此格只用於鎖定，不拼接）。
    case bandsLocked(BandInsets)
    /// 鎖定尚未成功，遞延到下一格重試。
    case awaitingBandLock(attempts: Int)
    /// 下捲：接上 dy 列。
    case appended(dy: Int, totalHeight: Int)
    /// 回捲：長圖尾端裁掉 amount 列。
    case trimmed(amount: Int, totalHeight: Int)
    /// 回捲已到 session 起點，不再裁。
    case atOrigin
    /// 匹配成功但位移為 0。也涵蓋「畫面在變但沒有一致平移」＝局部動畫／廣告／loading spinner
    /// （步進估計**有信心地**確認沒有平移，見 `StepOutcome`）。
    case noMotion
    /// 有位移但還無法安全接合，且軌跡顯示「再等一格是安全的」——內容可能正要進入重疊區。
    /// **不是失敗**：快捲時重疊區可能暫時全是空白，此時猜位移只會拼錯，等一格才是對的。
    case awaitingOverlap(pendingDy: Int)
    /// 匹配鏈全敗，但軌跡累積已逼近「再等就會失去重疊」的界線，於是依**軌跡外推**接上
    /// （接縫可能有數像素誤差，**但內容不會遺失**）。軌跡來自真實的 f2f 影像匹配，
    /// 不是拿輸入事件推算。
    case appendedApproximate(dy: Int, totalHeight: Int)
    /// 匹配鏈全敗且軌跡也失效（步進估不出＝連相鄰格都失去重疊）→ 真的無從得知位移。
    case rejected(consecutiveFailures: Int)
    /// 已達長度上限，該收工。
    case limitReached

    /// 「等待中」＝畫面沒變或重疊尚不足,跳過本格但不計失敗（waitingForMotion／awaitingOverlap）。
    /// Session 用它決定 log 節流；抽成純屬性可測。
    public var isWaiting: Bool {
        switch self {
        case .waitingForMotion, .awaitingOverlap: return true
        default: return false
        }
    }
}

/// 滾動截圖的影格消化引擎：擁有 stitcher／靜態帶鎖定／軌跡追蹤與匹配鏈。
/// **不碰 UI、不碰 SCStream**，因此可在 selftest 用合成影格序列端到端驗證。
///
/// ### 為什麼要有軌跡（本次重新設計的核心）
/// 舊版把 30fps 的影格序列當成一堆互不相關的單張影像：每格只跟長圖尾端做一次獨立匹配，
/// 時間維度的資訊整個丟掉。問題是「對長圖尾端」的位移大、搜尋範圍大，等行距內容的
/// 週期解就落在那個範圍內；而「對上一格」的位移小、重疊 95% 以上，歧義幾乎為零。
///
/// 現在先用容易的題目（frame-to-frame）累積出預測位移，再用它把難題目的搜尋窗縮到 ±12px。
/// 軌跡只縮小搜尋窗，**不把 drift 帶進長圖**——寫進長圖的位移永遠由對長圖尾端的
/// 原解析度全列 ZNCC 裁決（見 `ScrollTrajectory`）。
///
/// ### 位移的唯一來源是影像
/// 舊版有一條「用滾輪累積量×自我校準比例推算位移」的退路（dead reckoning），
/// 那是拿輸入事件量測世界，已移除。滾輪事件仍有用，但只用於表達**使用者意圖**
/// （啟動、以及「還在捲但畫面不動」的到底判定），那部分留在 session 層。
///
/// ### 執行緒約定（`@unchecked Sendable` 的成立條件）
/// 這個類別的**所有**成員只能在呼叫端的單一序列佇列（session 的 `engineQueue`）上被觸碰，
/// 包含唯讀屬性與 `finalize()`。呼叫端要的狀態一律透過 `Snapshot` 帶出去，
/// 不可從其他執行緒直接讀屬性。
///
/// 這條約定原本只寫在註解裡而實際被違反：session 在 `@MainActor` 上讀 `trajectory` 寫診斷、
/// 並同步呼叫 `finalize()`——而 `finalize()` 會讀 stitcher 的 buffer，若此時佇列上正在跑
/// `consume` 寫入同一塊 buffer 就是真的資料競爭（快捲時按「完成」即可撞上）。
/// 現在改由 `Snapshot` 把資料帶出佇列，讓約定真正成立而不只是宣稱成立。
public final class ScrollStitchEngine: @unchecked Sendable {
    /// engine 的狀態快照。呼叫端（MainActor）需要的所有資訊都在這裡，
    /// 這樣 engine 本身可以嚴格侷限在單一佇列上。
    ///
    /// 刻意**不含** outcome：outcome 是「這一格的結果」，而收尾時並沒有這一格
    /// （硬塞一個假值只會讓呼叫端讀到無意義的欄位）。需要 outcome 的地方由 `consumeSnapshot`
    /// 一併回傳。
    public struct Snapshot: Sendable {
        public let height: Int
        public let consecutiveFailures: Int
        public let appendedFrameCount: Int
        public let isLocked: Bool
        public let hasQualityDoubt: Bool
        public let trajectory: ScrollTrajectory
        public let stepNote: String
        public let matchNote: String
    }

    public private(set) var appendedFrameCount = 1
    public private(set) var consecutiveFailures = 0
    /// 最近一次 matcher 主判的結果字串（診斷用：區分 ambiguous／lowConfidence／noOverlap）。
    public private(set) var lastMatchNote = ""
    /// 診斷用：軌跡狀態快照（f2f 累積 vs 實際提交，兩者長期背離＝f2f 在撞假峰）。
    public private(set) var trajectory = ScrollTrajectory()
    /// 診斷用：最近一次步進估計的結果字串。
    public private(set) var lastStepNote = ""
    /// 最近一次步進估計的分數（nil＝估不出）。用來決定軌跡外推能不能突破
    /// 「重疊需足夠以供驗證」的保守上限——見 `rescue`。
    private var lastStepScore: Float?
    /// 步進分數低於此值＝**高信心**（實測正確步進的分數在 0.0～0.0002 之間，
    /// 而步進估計本身的放行閘是 0.15，所以這道門檻留了兩個數量級的餘裕）。
    private let strongStepScore: Float = 0.05
    /// 步進估不出時，最多連續用速度推測幾格。超過就判定真的失去重疊。
    private let assumedStepLimit = 2
    /// 本次 session 是否曾發生匹配失敗或近似接合＝長圖品質有疑慮。
    /// session 層據此決定「到底」時是否要求使用者回捲確認（正常情況不打擾使用者）。
    public private(set) var hasQualityDoubt = false
    public var height: Int { stitcher?.height ?? 0 }
    public var isLocked: Bool { insets != nil }

    private let maxHeightPx: Int
    private var stitcher: ScrollStitcher?
    private var insets: BandInsets?
    private var lastAcceptedFullFrame: PixelBuffer?
    private var lockAttempts = 0
    /// 最近一格內容影格的高度（算 maxDy 用）。
    private var lastFrameHeight = 0
    /// 上次「實際跑過匹配」的那格指紋（動作判定基準）。
    private var lastProcessedFingerprint: [UInt8]?
    /// 上一格的 luma，步進估計的基準。
    ///
    /// 存 **luma 而非 PixelBuffer**：luma 轉換是全圖逐像素運算（實測 1.31ms／1957×736），
    /// 上一格已經算過一次，沒有理由每格再為 prev 重算——記憶體占用兩者相同（都是 4 bytes/px）。
    ///
    /// 用 **full frame 的 luma** 而非 contentFrame：鎖帶前後 contentFrame 的尺寸會變，
    /// 存 full 可讓步進估計的兩張圖尺寸永遠一致。靜態帶對 `dy=0` 的偏好不構成問題——
    /// 靜態帶只佔全格一小部分，`dy=0` 時其餘內容不相關，分數過不了步進估計的 0.15 閘。
    private var prevStepLuma: LumaPlane?

    public init(maxHeightPx: Int) {
        self.maxHeightPx = maxHeightPx
    }

    // MARK: - 對外介面（狀態一律經 Snapshot 帶出佇列）

    /// 消化一格，回傳這格的結果與 engine 狀態。
    /// **呼叫端只能用回傳值**，不要在別的執行緒讀 engine 屬性。
    public func consumeSnapshot(frame full: PixelBuffer)
        -> (outcome: ScrollStitchOutcome, state: Snapshot) {
        let outcome = consume(frame: full)
        return (outcome, snapshot())
    }

    /// 收尾：產出長圖並附上最終狀態。必須和 `consumeSnapshot` 在同一個佇列上呼叫，
    /// 否則會與進行中的 `consume` 競爭 stitcher 的 buffer。
    ///
    /// 判準是 `> 1` 而不是 `>= 1`：`appendedFrameCount` **初始值就是 1**（基準格），
    /// 所以 `>= 1` 恆真——「一格都沒拼到就靜默」的規則從來沒生效過，
    /// 拉框後什麼都沒捲就按完成會開一個只有單張影格的預覽視窗。
    public func finalizeSnapshot() -> (image: CGImage?, state: Snapshot) {
        let image = appendedFrameCount > 1 ? finalize() : nil
        return (image, snapshot())
    }

    private func snapshot() -> Snapshot {
        Snapshot(height: height, consecutiveFailures: consecutiveFailures,
                 appendedFrameCount: appendedFrameCount, isLocked: isLocked,
                 hasQualityDoubt: hasQualityDoubt, trajectory: trajectory,
                 stepNote: lastStepNote, matchNote: lastMatchNote)
    }

    /// 消化一格。位移的判定完全來自影像——不再接收任何滾輪參數。
    /// - Note: engine 的可變狀態只在單一（背景）執行緒上被觸碰。
    public func consume(frame full: PixelBuffer) -> ScrollStitchOutcome {
        guard let stitcher else {
            stitcher = ScrollStitcher(firstFrame: full, maxHeightPx: maxHeightPx)
            lastAcceptedFullFrame = full
            lastProcessedFingerprint = fingerprint(of: full)   // 基準格也要當動作判定的基準
            prevStepLuma = LumaPlane(full)
            return .baseCaptured(height: full.height)
        }
        // 動作判定用**影像變化**，不可用滾輪事件量（實機證據：整場 session 累積滾輪只有 3 點，
        // 卻收到 116 格影格＝畫面確實一直在動，全部被 10 點的門檻擋掉，一次匹配都沒跑）。
        // SCStream 只在畫面改變時供格，所以「這格與上次處理過的格不同」才是動作的唯一可靠證據。
        guard frameDiffers(from: full) else { return .waitingForMotion }

        let contentFrame: PixelBuffer
        if let insets {
            contentFrame = full.cropped(x: insets.left, y: insets.top,
                                        width: full.width - insets.left - insets.right,
                                        height: full.height - insets.top - insets.bottom)
        } else { contentFrame = full }

        lastFrameHeight = contentFrame.height
        lastProcessedFingerprint = fingerprint(of: full)

        // ① 步進估計：對「上一格」而非長圖尾端。位移小、重疊 95%+，歧義幾乎為零。
        let fullLuma = LumaPlane(full)
        let step = prevStepLuma.map {
            ScrollMatcher.matchStep(new: fullLuma, prev: $0,
                                    priorStep: trajectory.lastStep, allowZero: true)
        } ?? .unknown
        prevStepLuma = fullLuma
        lastStepNote = "\(step)"
        switch step {
        case let .step(_, score): lastStepScore = score
        case .unknown: lastStepScore = nil
        }
        switch step {
        case let .step(dy, _) where dy == 0:
            // **有信心地**確認畫面在變但沒有一致平移＝局部動畫／廣告／loading spinner。
            // 直接跳過，不進救援層（省掉無謂嘗試，也消掉一類誤接）。
            // 注意這與 `.unknown`（估不出）必須分開處理，混為一談會把真實捲動的內容
            // 當成動畫丟掉，違反「完整性優先於接縫完美」。
            consecutiveFailures = 0
            return .noMotion
        case let .step(dy, _):
            trajectory.recordStep(dy)
        case .unknown:
            // 估不出。畫面確實在動（指紋 gate 已確認），只是這格的重疊區剛好沒有可辨識特徵
            // ——稀疏內容下每隔幾格就會遇到一次。讓軌跡依速度連續性推進一格，否則那格的位移
            // 會永久遺失（實測每 9 格一次、共丟 4 格 ×180px）。推測有連續次數上限，
            // 且只進入軌跡不直接接上（見 recordAssumedStep 的說明）。
            trajectory.recordAssumedStep(maxConsecutive: assumedStepLimit)
        }

        let reference = stitcher.referenceTail(maxHeight: contentFrame.height)
        guard reference.height == contentFrame.height else { return .waitingForMotion }

        // ② 累積位移還不足以產生可信的接合 → 等下一格（匹配基準是固定的長圖尾端，不會漏內容）。
        let pending = trajectory.pendingDy
        if case .step = step, abs(pending) < ScrollMatcher.Config.default.minDelta {
            return .waitingForMotion
        }

        // ③ 主匹配。方向與 prior 都由軌跡給——軌跡是影像證據，與輸入裝置及系統設定無關。
        let newLuma = LumaPlane(contentFrame)
        let refLuma = LumaPlane(reference)
        let outcome = runMainMatch(new: newLuma, ref: refLuma, pending: pending)
        lastMatchNote = "\(outcome)"

        switch outcome {
        case let .accepted(dy, _) where dy > 0:
            return accept(dy: dy, full: full, contentFrame: contentFrame)
        case let .accepted(dy, _) where dy < 0:
            consecutiveFailures = 0
            let trimmed = stitcher.cropTail(-dy)
            if trimmed > 0 {
                trajectory.commit(actualDy: -trimmed, minTrustworthy: ScrollMatcher.Config.default.minDelta)
                return .trimmed(amount: trimmed, totalHeight: stitcher.height)
            }
            trajectory.resetToOrigin()
            return .atOrigin
        case .accepted:
            consecutiveFailures = 0
            return .noMotion
        case .ambiguous, .lowConfidence, .noOverlap:
            return rescue(contentFrame: contentFrame, reference: reference, full: full)
        }
    }

    /// 主匹配。軌跡有值時走「受信任 prior」快路徑（實測 4.6ms，比全域的 7.9ms 快）；
    /// 該路徑在過不了閘時會自行 fallback 到全域候選複評，所以錯的 prior 不會把結果帶跑
    /// （實測：即使餵行倍數錯解或荒謬值當 prior，仍找回正解）。
    ///
    /// 軌跡完全沒有資訊時（開場步進就估不出）方向未知，兩個方向各試一次全域。
    private func runMainMatch(new: LumaPlane, ref: LumaPlane, pending: Int) -> MatchOutcome {
        if pending != 0 {
            return ScrollMatcher.match(new: new, reference: ref,
                                       wheelDirection: pending >= 0 ? 1 : -1,
                                       prior: pending, priorIsTrusted: true)
        }
        let positive = ScrollMatcher.match(new: new, reference: ref, wheelDirection: 1, prior: nil)
        if case .accepted = positive { return positive }
        let negative = ScrollMatcher.match(new: new, reference: ref, wheelDirection: -1, prior: nil)
        if case .accepted = negative { return negative }
        return positive
    }

    public func finalize() -> CGImage? { stitcher?.finalize() }

    // MARK: - 私有

    private func accept(dy: Int, full: PixelBuffer, contentFrame: PixelBuffer) -> ScrollStitchOutcome {
        guard let stitcher else { return .waitingForMotion }
        consecutiveFailures = 0

        guard insets != nil else {
            // T7 契約：鎖定必須在任何 append 之前，本格只當偵測素材。
            return attemptLock(dy: dy, full: full)
        }
        guard stitcher.append(contentFrame: contentFrame, dy: dy) else { return .limitReached }
        appendedFrameCount += 1
        lastAcceptedFullFrame = full
        // 用絕對匹配的結果把軌跡的預測歸零＝每次接合都清掉一次 f2f 的累積 drift。
        trajectory.commit(actualDy: dy, minTrustworthy: ScrollMatcher.Config.default.minDelta)
        return .appended(dy: dy, totalHeight: stitcher.height)
    }

    /// 便宜的影像變化偵測：抽樣約 2000 個像素比對上次「處理過」的格。
    /// 差異像素比例超過 0.5% 即視為畫面有動（門檻遠高於編碼雜訊，遠低於一次可辨識的捲動）。
    private func frameDiffers(from full: PixelBuffer) -> Bool {
        guard let prev = lastProcessedFingerprint, prev.count == fingerprintSize else {
            lastProcessedFingerprint = fingerprint(of: full)
            return true          // 沒有基準可比＝當作有動（第一次匹配機會不放掉）
        }
        let now = fingerprint(of: full)
        var diff = 0
        for i in 0..<fingerprintSize where abs(Int(now[i]) - Int(prev[i])) > 6 { diff += 1 }
        return diff * 200 > fingerprintSize        // > 0.5%
    }

    private var fingerprintSize: Int { 2048 }

    private func fingerprint(of p: PixelBuffer) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: fingerprintSize)
        guard p.bytes.count > 4 else { return out }
        let stride = max(4, (p.bytes.count / fingerprintSize) & ~3)
        var i = 0
        for k in 0..<fingerprintSize {
            out[k] = p.bytes[min(i, p.bytes.count - 1)]
            i += stride
        }
        return out
    }

    /// 靜態帶鎖定嘗試；連續 5 次失敗改用 zero insets 強制鎖定，避免永遠鎖不上卡死。
    private func attemptLock(dy: Int, full: PixelBuffer) -> ScrollStitchOutcome {
        defer { lastAcceptedFullFrame = full }
        guard let stitcher else { return .waitingForMotion }
        if let prev = lastAcceptedFullFrame,
           let detected = StaticBandDetector.detect(frameA: LumaPlane(full), frameB: LumaPlane(prev), dy: dy),
           stitcher.lockBands(detected, bottomBandFrom: full) {
            insets = detected
            lockAttempts = 0
            return .bandsLocked(detected)
        }
        lockAttempts += 1
        if lockAttempts >= 5, stitcher.lockBands(.zero, bottomBandFrom: full) {
            insets = .zero
            lockAttempts = 0
            return .bandsLocked(.zero)
        }
        return .awaitingBandLock(attempts: lockAttempts)
    }

    /// 救援：Vision 全圖對位當**演算法完全獨立**的第二意見（不同失敗模式），仍必經 matcher 複核；
    /// 全敗時依「軌跡是否已逼近失去重疊的界線」決定是等下一格還是外推接上。
    ///
    /// 這裡**沒有**相位相關了。移除的依據是四種內容類型各 10 組已知位移的實測：
    /// 1-D 投影相位相關命中率只有 20%，給錯值時連符號都錯（真 150→估 −30、真 90→估 −135），
    /// 而同一批測資上 ZNCC 是 40/40 零判錯。關鍵不只是命中率低，而是**它被觸發的時機
    /// （ZNCC 已失敗時）正好是它最不可靠的時機**。
    private func rescue(contentFrame: PixelBuffer, reference: PixelBuffer,
                        full: PixelBuffer) -> ScrollStitchOutcome {
        if let visionDy = visionEstimate(new: contentFrame, reference: reference),
           visionDy > 0,
           case let .accepted(dy, _) = ScrollMatcher.match(
               new: LumaPlane(contentFrame), reference: LumaPlane(reference),
               wheelDirection: 1, prior: visionDy, priorIsTrusted: true),
           abs(dy - visionDy) <= max(18, visionDy / 3) {
            return accept(dy: dy, full: full, contentFrame: contentFrame)
        }

        // 連相鄰格都估不出，而且速度推測的額度也用完了＝**真的失去重疊**（使用者捲太快）。
        // 此時 pendingDy 全部來自推測、不可信，拿它外推只會把錯誤內容拼進長圖。
        // 明確回報失敗，讓 HUD 提示使用者回捲——這與「等內容進入重疊區」是兩回事，
        // 前者需要使用者介入，後者只要再等一格。
        if lastStepScore == nil, trajectory.assumedRun >= assumedStepLimit {
            consecutiveFailures += 1
            hasQualityDoubt = true
            return .rejected(consecutiveFailures: consecutiveFailures)
        }

        let verifiableMaxDy = maxAcceptableDy()
        let pending = trajectory.pendingDy

        // 外推上限有兩級（實機自檢抓到的錯）：
        // ① 保守級 `verifiableMaxDy` = 內容格高 − minOverlap。minOverlap 的用途是「留足夠重疊
        //    來**驗證**匹配」，在沒有其他證據時該遵守。
        // ② 放行級 = 整個內容格高。當**步進估計高信心成立**時，位移已經在 full frame 上被
        //    獨立驗證過了（實測：內容格 228px、步進 180px，f2f 在 372px 的 full frame 上有
        //    192px 重疊、分數 0.0），此時再套 minOverlap 只會硬生生截掉內容——實測每格丟 48px、
        //    累積成 44% 的內容遺失。上限仍不得超過內容格高，否則長圖會出現未填充的空洞。
        let strongStep = (lastStepScore.map { $0 <= strongStepScore }) ?? false
        let maxDy = strongStep ? max(verifiableMaxDy, lastFrameHeight) : verifiableMaxDy

        // 軌跡還有餘裕 → **先等下一格，不猜**。快捲時重疊區可能暫時全是空白
        // （實測：真解的重疊區兩邊皆平坦時 ZNCC 回「無資訊」），這時猜位移只會拼錯；
        // 畫面還在捲，內容馬上就會進入重疊區。
        if pending > 0, maxDy > 0, !trajectory.mustCommitNow(maxDy: maxDy) {
            hasQualityDoubt = true
            return .awaitingOverlap(pendingDy: pending)
        }

        // 再等就會失去重疊 → 用**軌跡外推**接上（軌跡來自真實的 f2f 影像匹配，不是輸入事件推算）。
        // 內容完整性優先於接縫完美（使用者裁定）。
        if pending >= ScrollMatcher.Config.default.minDelta, maxDy > 0, let stitcher {
            let dy = min(pending, maxDy)
            // 仍要守 T7 契約：鎖帶必須在任何 append 之前。未鎖帶時本格先用於鎖定嘗試
            // （否則之後 lockBands 會因「已 append 過」被永久拒絕，靜態帶再也鎖不上）。
            guard insets != nil else { return attemptLock(dy: dy, full: full) }
            if stitcher.append(contentFrame: contentFrame, dy: dy) {
                appendedFrameCount += 1
                lastAcceptedFullFrame = full
                consecutiveFailures = 0
                hasQualityDoubt = true
                trajectory.commit(actualDy: dy, minTrustworthy: ScrollMatcher.Config.default.minDelta)
                return .appendedApproximate(dy: dy, totalHeight: stitcher.height)
            }
            return .limitReached
        }

        // 匹配失敗且軌跡也沒有可用資訊（連相鄰格都失去重疊）→ 真的無從得知位移。
        consecutiveFailures += 1
        hasQualityDoubt = true
        return .rejected(consecutiveFailures: consecutiveFailures)
    }

    /// 這格還能接受的最大位移（超過就沒有足夠重疊可驗證）。
    private func maxAcceptableDy() -> Int {
        let h = lastFrameHeight
        guard h > 0 else { return 0 }
        let cfg = ScrollMatcher.Config.default
        let minOverlap = max(cfg.minOverlapPx, Int(Double(h) * cfg.minOverlapFraction))
        return h - minOverlap
    }

    /// Vision 全圖位移估計。ty 正負依 Task 2 實測（scrollDownPixels = -ty，勿用 abs）。
    private func visionEstimate(new: PixelBuffer, reference: PixelBuffer) -> Int? {
        guard new.height > 80, let cgNew = new.makeCGImage(), let cgRef = reference.makeCGImage() else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: cgNew)
        let handler = VNImageRequestHandler(cgImage: cgRef, options: [:])
        try? handler.perform([request])
        guard let ty = (request.results?.first)?.alignmentTransform.ty else { return nil }
        return Int((-ty).rounded())
    }
}
