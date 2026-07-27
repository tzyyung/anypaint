import Foundation

public enum MatchOutcome: Equatable, Sendable {
    case accepted(dy: Int, confidence: Double)
    case ambiguous
    case lowConfidence
    case noOverlap
}

/// frame-to-frame 步進估計的結果。
///
/// **`.step(dy: 0)` 與 `.unknown` 的區別是安全關鍵**：前者是「有信心地確認畫面沒有一致平移」
/// （＝局部動畫／廣告／loading spinner，可以安全跳過）；後者是「估不出來」，該格仍必須進
/// 救援層。把兩者混為一談會讓真實捲動的內容被當成動畫丟掉，違反「完整性優先」的產品裁決。
public enum StepOutcome: Equatable, Sendable {
    case step(dy: Int, score: Float)
    case unknown
}

/// 垂直位移估計。關係式：`new[r] == ref[r+dy]`（dy>0＝下捲、dy<0＝回捲）。
///
/// 兩個入口，解的是不同難度的問題：
/// - `matchStep`：對**上一格**估位移。重疊 95% 以上、位移小，歧義幾乎為零。
/// - `match`：對**長圖尾端**估位移。位移大、搜尋範圍大，等行距內容的週期解就落在範圍內；
///   靠 `matchStep` 累積出的軌跡當 prior 把搜尋窗縮小（見 `ScrollTrajectory`）。
///
/// 計分一律是**整個重疊區的 ZNCC**（見 `overlapScore`——那裡記著為什麼不用 band 取樣）。
/// 金字塔三層：L2 (1/4) 提名候選 → L1 (1/2) 篩選排序 → L0 原解析度裁決。
/// **粗掃層只提名、不裁決**：它的分數常糊在一起，而原解析度是乾淨的。
public enum ScrollMatcher {
    public struct Config {
        public var minDelta = 14              // 最小可信位移（px，原解析度）
        public var minOverlapFraction = 0.16  // 最小重疊 = max(96, H×此值)
        public var minOverlapPx = 96
        public var ratioGateMin = 1.3         // 次佳/最佳 需 ≥ 此值（次佳排除 ±exclusion）
        public var exclusionRadius = 24       // 次佳排除窗（原解析度 px）
        public var absoluteGateMax: Float = 0.35  // 重疊區平均分（1−ZNCC）的絕對上限
        public var worstBandMax: Float = 0.60     // 重疊區四等分裡最差那份的上限（局部污染防線）
        public var priorWeight = 0.15         // 速度先驗軟懲罰權重
        /// 受信任 prior（軌跡預測）的搜尋半徑（原解析度 px）。要容納 f2f 幾格的累積誤差，
        /// 又要小到讓等行距內容的週期解落在窗外。
        public var trustedPriorRadius = 12
        /// 候選集上限。固定 k=5 太邊緣（實測病態內容的真解在 L2 排名第 5），
        /// 改為自適應收集後再以此為上限。
        public var maxCandidates = 8
        /// 候選集的分數放行倍數：L2 分數 < best×此值 者都進候選（自適應集合大小）。
        public var candidateScoreFactor: Float = 3
        public static let `default` = Config()

        public init() {}
    }

    /// - Parameter priorIsTrusted: prior 來自**獨立的影像證據**時設 true——常態是
    ///   `ScrollTrajectory` 的軌跡預測，救援時則是 Vision 全圖對位。此模式跳過 L2 全域粗掃，
    ///   直接在 prior 附近由粗到細精修（見 `matchPositive` 的快路徑）。
    ///
    ///   必要性（實機重現）：稀疏內容（大半空白、只有少數幾行字）在 1/4 金字塔層訊號幾乎消失，
    ///   L2 粗掃必判 ambiguous 而提前返回——於是即使算出正確位移也永遠救不回來
    ///   （症狀：長圖等於單張影格）。此模式改由「絕對閘＋最差區塊閘」把關。
    ///
    ///   **錯的 prior 不會把結果帶跑**：快路徑過不了閘就自動落到全域候選複評
    ///   （實測餵行倍數錯解或荒謬值當 prior，仍找回正解）。
    public static func match(new: LumaPlane, reference: LumaPlane,
                             wheelDirection: Int, prior: Int?,
                             priorIsTrusted: Bool = false,
                             config: Config = .default) -> MatchOutcome {
        guard new.width == reference.width, new.height == reference.height else { return .noOverlap }
        if wheelDirection < 0 {
            // 負向 = 翻轉兩圖跑正向再取負（一條路徑吃雙向；先驗同步鏡像）
            let r = matchPositive(new: new.flippedVertically(),
                                  reference: reference.flippedVertically(),
                                  prior: prior.map { -$0 }, priorIsTrusted: priorIsTrusted,
                                  config: config)
            if case let .accepted(dy, c) = r { return .accepted(dy: -dy, confidence: c) }
            return r
        }
        return matchPositive(new: new, reference: reference, prior: prior,
                             priorIsTrusted: priorIsTrusted, config: config)
    }

    // MARK: - frame-to-frame 步進估計

    public struct StepConfig {
        /// 步進的絕對品質閘，**比主匹配的 0.35 嚴**：f2f 的重疊有 95% 以上，
        /// 真匹配的分數應該極低（實測合成內容為 0.0000）。過不了這關就是估不出，不可硬用。
        public var absoluteGate: Float = 0.15
        /// 搜尋窗最小半徑（原解析度 px）。背壓只留最新格，所以「上一格」可能不是真正的
        /// 相鄰格（位移是好幾格的總和），窗要留餘裕。
        public var minRadius = 12
        /// 無 prior 時的全域搜尋上限（原解析度 px），只在開場那格用到。
        public var globalMaxStep = 260
        /// 欄取樣間隔（比主匹配的 2 疏）。見 `score1` 的說明：垂直位移的資訊在水平邊緣，
        /// 疏化欄取樣不損失垂直鑑別力，而 f2f 的重疊區極大、是每格最貴的一段計分。
        public var colStep = 4
        public static let `default` = StepConfig()

        public init() {}
    }

    /// 對「上一格」估位移，而不是對長圖尾端。
    ///
    /// 這是整個重新設計的核心：相鄰兩格重疊 95% 以上、位移小，歧義幾乎為零；
    /// 而「對長圖尾端」的大位移才是歧義的來源（等行距內容的週期解就落在那個大搜尋範圍裡）。
    /// 用容易的題目累積出預測位移，再用它把難題目的搜尋窗縮小。
    ///
    /// 解析度選擇（實作時修正原設計）：**在 L1 (1/2) 做**。原訂 L2 (1/4) 是錯的——
    /// L2 的 1px 等於原解析度 4px，慢捲時 2–8px 的位移會被量化成 0，軌跡系統性低估。
    /// L1 單次 0.067ms，配拋物線次像素插值把精度提到約 ±1px（原解析度）。
    ///
    /// - Parameters:
    ///   - prev: 上一格（同尺寸）。鎖帶後呼叫端應傳 contentFrame——靜態帶在 `dy=0` 時
    ///     完美相關，會把估計拉向 0。
    ///   - priorStep: 上次的步進值（速度連續性）。nil＝開場，改走 L2 全域粗掃。
    ///   - allowZero: 是否允許回報 `dy=0`。鎖帶前用 full frame，靜態帶會讓 0 的分數偏低，
    ///     此時應傳 false 把 0 排除在搜尋範圍外。
    public static func matchStep(new: LumaPlane, prev: LumaPlane,
                                 priorStep: Int?, allowZero: Bool,
                                 config: StepConfig = .default) -> StepOutcome {
        guard new.width == prev.width, new.height == prev.height, new.height >= 32 else {
            return .unknown
        }
        let n1 = new.downsampled(), p1 = prev.downsampled()
        guard n1.height >= 16 else { return .unknown }
        let limit1 = min(config.globalMaxStep / 2, n1.height - 8)
        // 欄取樣要對窄影格自適應：選區**寬度沒有下限**（只有高度有 320px 的門檻），
        // 使用者可以拉細長框。固定 colStep=4 在窄圖上每列只剩十幾個取樣點，訊號不足。
        let stepColStep = max(1, min(config.colStep, n1.width / 64))
        guard limit1 >= 1 else { return .unknown }

        /// L1 座標的分數。負位移＝交換兩圖跑正向（overlapScore 的關係式是 new[r]==ref[r+dy]，
        /// 取負等價於把角色互換），一條路徑吃雙向。
        ///
        /// 成本控制用 **colStep 而非 rowStep**：垂直位移的資訊在**水平邊緣**（文字行的上下緣、
        /// 分隔線），水平方向抽樣不會損失它；隔列取樣才會——實測把 rowStep 調成 2 會讓
        /// 「大片純色＋一條 3px 細線」的測資直接失配（降採樣後那條線只剩 1–2px，隔列剛好跳過）。
        /// f2f 的重疊區有 95% 以上，是每格最貴的一段計分，所以這裡用比主匹配更疏的欄取樣。
        func score1(_ dy: Int) -> Float {
            if dy >= 0 { return overlapScore(new: n1, ref: p1, dy: dy, rowStep: 1, colStep: stepColStep, needsWorst: false).mean }
            return overlapScore(new: p1, ref: n1, dy: -dy, rowStep: 1, colStep: stepColStep, needsWorst: false).mean
        }

        /// L2 全域粗掃找落點（65 候選 × 0.017ms ≈ 1.1ms），回傳 L1 座標的中心。
        func globalCenter1() -> Int? {
            let n2 = n1.downsampled(), p2 = p1.downsampled()
            guard n2.height >= 12 else { return nil }
            let limit2 = min(limit1 / 2, n2.height - 6)
            guard limit2 >= 1 else { return nil }
            var best2 = (dy: 0, s: Float.greatestFiniteMagnitude)
            for dy in -limit2...limit2 {
                if dy == 0, !allowZero { continue }
                let s = dy >= 0 ? overlapScore(new: n2, ref: p2, dy: dy, rowStep: 1, colStep: stepColStep, needsWorst: false).mean
                                : overlapScore(new: p2, ref: n2, dy: -dy, rowStep: 1, colStep: stepColStep, needsWorst: false).mean
                if s.isFinite, s < best2.s { best2 = (dy, s) }
            }
            return best2.s.isFinite ? best2.dy * 2 : nil
        }

        /// 在 L1 的指定窗內找最佳位移。
        func searchWindow(center: Int, radius: Int) -> (dy: Int, s: Float)? {
            let lo = max(-limit1, center - radius), hi = min(limit1, center + radius)
            guard lo <= hi else { return nil }
            var best = (dy: 0, s: Float.greatestFiniteMagnitude)
            for dy in lo...hi {
                if dy == 0, !allowZero { continue }
                let s = score1(dy)
                if s.isFinite, s < best.s { best = (dy, s) }
            }
            return best.s.isFinite ? best : nil
        }

        var best: (dy: Int, s: Float)?
        if let prior = priorStep {
            best = searchWindow(center: prior / 2, radius: max(config.minRadius / 2, abs(prior) / 4))
        }
        // 窗內找不到夠好的解 → 退回全域掃。
        //
        // 這條 fallback 是必要的，不是保險（實機自檢抓到）：搜尋窗以**上次步進**為中心，
        // 使用者一改變方向（下捲轉回捲）真解就落在窗外，於是回捲永遠估不出來。
        // 背壓丟格時也一樣——「上一格」其實隔了好幾格，位移遠大於窗寬。
        if best == nil || (best?.s ?? .greatestFiniteMagnitude) > config.absoluteGate {
            if let c = globalCenter1(), let g = searchWindow(center: c, radius: 3) {
                if best == nil || g.s < best!.s { best = g }
            }
        }
        guard let best, best.s <= config.absoluteGate else { return .unknown }

        // 拋物線次像素插值（三點擬合最小值）。分母同號檢查防止落在非凸處時外推到窗外。
        var refined = Double(best.dy)
        let sPrev = best.dy - 1 >= -limit1 ? score1(best.dy - 1) : Float.nan
        let sNext = best.dy + 1 <= limit1 ? score1(best.dy + 1) : Float.nan
        if sPrev.isFinite, sNext.isFinite {
            let denom = sPrev - 2 * best.s + sNext
            if denom > 1e-6 {
                let offset = 0.5 * Double(sPrev - sNext) / Double(denom)
                if abs(offset) <= 1 { refined += offset }
            }
        }
        return .step(dy: Int((refined * 2).rounded()), score: best.s)
    }

    // MARK: - 正向主流程

    static func matchPositive(new: LumaPlane, reference: LumaPlane,
                              prior: Int?, priorIsTrusted: Bool = false,
                              config: Config) -> MatchOutcome {
        let h = new.height
        let minOverlap = max(config.minOverlapPx, Int(Double(h) * config.minOverlapFraction))
        let maxDy = h - minOverlap
        guard maxDy > config.minDelta else { return .noOverlap }

        // 金字塔：L0=原、L1=1/2、L2=1/4
        let n1 = new.downsampled(), n2 = n1.downsampled()
        let r1 = reference.downsampled(), r2 = r1.downsampled()

        // 受信任的 prior（軌跡預測）＝新架構的主路徑。**先在 L1 掃窗、再在 L0 只精修 ±2**。
        // 為什麼不像原本那樣直接在 L0 精修 ±8：實測 L0 全列單次 0.631ms，17 個候選就要 10.7ms；
        // 改成 L1 掃 ±6（0.067ms×13）再 L0 精修 ±2（0.631ms×5）約 4ms，比原本的全域路徑
        // （實測 7.18ms）還快——軌跡 prior 讓我們不必再掃 L2 那 65 個全域候選。
        // 失敗時**不直接返回**，落到底下的全域候選複評（prior 可能因背壓丟格而失準）。
        if priorIsTrusted, let p = prior, p >= config.minDelta, p <= maxDy {
            let r1Radius = max(3, config.trustedPriorRadius / 2)
            let c1 = min(max(1, p / 2), max(1, r1.height - 2))
            let dy1 = refine(new: n1, ref: r1, center: c1, radius: r1Radius, rowStep: 1)
            let dy0 = refine(new: new, ref: reference, center: dy1 * 2, radius: 2, rowStep: 1)
            if dy0 >= config.minDelta, dy0 <= maxDy {
                let q = overlapScore(new: new, ref: reference, dy: dy0, rowStep: 1)
                if q.mean <= config.absoluteGateMax, q.worst <= config.worstBandMax {
                    // 信心：拿窗外的最佳分數當次佳（純影像證據）。軌跡 prior 本身已是獨立佐證，
                    // 因此這裡用比值只為擋掉「窗內外一樣好」的多解情況。
                    let outside = bestScoreOutsideWindow(new: n2, ref: r2, center: dy0 / 4,
                                                         exclusion: max(1, config.exclusionRadius / 4),
                                                         minDy: max(1, config.minDelta / 4),
                                                         maxDy: max(1, maxDy / 4))
                    let ratio = outside.isFinite ? Double(outside / max(q.mean, 1e-6)) : 1000
                    if ratio >= Double(config.ratioGateMin) {
                        return .accepted(dy: dy0, confidence: min(ratio, 1000))
                    }
                }
            }
        }

        // 全域候選複評（取代原本「L2 自己判 ambiguous 就結束」）。
        //
        // 為什麼改：實測顯示 L2（1/4 降採樣）的分數常常糊在一起（top3 為 0.0460 / 0.0546，
        // 比值 1.19 剛好擦過 1.1 的早判門檻），而**原解析度是乾淨的**（0.0000 / 0.0444）。
        // 用糊掉的那層做生死裁決是設計錯誤：粗掃層訊號一弱就提前判 ambiguous，
        // 之後再也回不到原解析度。改為粗掃層只**提名候選**，裁決一律在原解析度做——
        // 這就是文獻上「掃描多個峰再用重疊區誤差複評」的思想（Optics Communications 2015）
        // 移植到金字塔上。
        let l2Range = max(1, config.minDelta / 4)...max(1, maxDy / 4)
        var scored: [(dy2: Int, raw: Float, ranked: Float)] = []
        for dy in l2Range {
            let raw = overlapScore(new: n2, ref: r2, dy: dy, needsWorst: false).mean
            guard raw.isFinite else { continue }
            var s = raw
            if let p = prior {
                s += Float(config.priorWeight) * min(1, abs(Float(dy * 4 - p)) / Float(h))
            }
            scored.append((dy, raw, s))
        }
        guard !scored.isEmpty else { return .noOverlap }
        scored.sort { $0.ranked < $1.ranked }

        // 自適應候選集：分數 < best×factor 者都收，彼此間隔須大於排除窗（否則只是同一個峰的鄰居）。
        let cutoff = max(scored[0].ranked, 1e-6) * config.candidateScoreFactor
        let excl2 = max(1, config.exclusionRadius / 4)
        var candidates: [Int] = []
        for cand in scored {
            guard cand.ranked <= cutoff || candidates.isEmpty else { break }
            if candidates.contains(where: { abs($0 - cand.dy2) <= excl2 }) { continue }
            candidates.append(cand.dy2)
            if candidates.count >= config.maxCandidates { break }
        }

        // 兩段複評：先在 L1 便宜地精修＋排序（0.067ms/次），只有前 2 名進 L0 全列（0.631ms/次）。
        // 精修半徑 6：每上一層放大 2 倍，前層 ±1~2 量化誤差會變成 ±2~4，±3 只剩 1px 餘裕，
        // 實測會落在窗外導致 dy 差 1px。
        var l1Ranked: [(dy1: Int, s: Float)] = []
        for c in candidates {
            let dy1 = refine(new: n1, ref: r1, center: c * 2, radius: 6, rowStep: 2)
            l1Ranked.append((dy1, overlapScore(new: n1, ref: r1, dy: dy1, rowStep: 2, needsWorst: false).mean))
        }
        l1Ranked.sort { $0.s < $1.s }

        var finals: [(dy: Int, mean: Float, worst: Float)] = []
        for entry in l1Ranked.prefix(2) {
            let dy0 = refine(new: new, ref: reference, center: entry.dy1 * 2, radius: 6, rowStep: 1)
            guard dy0 >= config.minDelta, dy0 <= maxDy else { continue }
            let q = overlapScore(new: new, ref: reference, dy: dy0, rowStep: 1)
            guard q.mean.isFinite else { continue }
            finals.append((dy0, q.mean, q.worst))
        }
        guard let winner = finals.min(by: { $0.mean < $1.mean }) else { return .noOverlap }

        guard winner.mean <= config.absoluteGateMax else { return .lowConfidence }
        guard winner.worst <= config.worstBandMax else { return .ambiguous }   // 局部污染 → 不可信

        // 比值閘一律在**原解析度**判定（這是本次改動的重點）。次佳取兩處的較嚴者：
        // ① 複評名單裡與 winner 相距超過排除窗的另一個解；② L2 全域裡窗外的最佳分數。
        var second = Float.greatestFiniteMagnitude
        for f in finals where abs(f.dy - winner.dy) > config.exclusionRadius {
            second = min(second, f.mean)
        }
        let outside = bestScoreOutsideWindow(new: n2, ref: r2, center: winner.dy / 4,
                                             exclusion: excl2,
                                             minDy: max(1, config.minDelta / 4),
                                             maxDy: max(1, maxDy / 4))
        second = min(second, outside)
        let confidence = Double(min(second.isFinite ? second / max(winner.mean, 1e-6) : 1000, 1000))
        // 走到這裡 winner 已過絕對閘（解本身是好的），所以比值不足只可能是**存在旗鼓相當的
        // 另一個解**＝多解，語意是 ambiguous 而非 lowConfidence。週期紋理（等寬條紋、
        // 等行距文字）就是這條路徑：每個週期倍數都是完美匹配，必須拒絕而不是挑一個接上。
        guard confidence >= Double(config.ratioGateMin) else { return .ambiguous }
        return .accepted(dy: winner.dy, confidence: confidence)
    }

    /// L2 全域裡「排除窗外」的最佳（＝最小）分數，用來判定是否存在旗鼓相當的另一個解。
    /// 回 `.greatestFiniteMagnitude` 代表窗外沒有任何有效候選（單解，信心高）。
    static func bestScoreOutsideWindow(new n2: LumaPlane, ref r2: LumaPlane,
                                       center: Int, exclusion: Int,
                                       minDy: Int, maxDy: Int) -> Float {
        guard minDy <= maxDy else { return .greatestFiniteMagnitude }
        var best = Float.greatestFiniteMagnitude
        for dy in minDy...maxDy where abs(dy - center) > exclusion {
            let s = overlapScore(new: n2, ref: r2, dy: dy, earlyExit: best, needsWorst: false).mean
            if s.isFinite, s < best { best = s }
        }
        return best
    }

    static func refine(new: LumaPlane, ref: LumaPlane, center: Int, radius: Int,
                       rowStep: Int) -> Int {
        var best = (dy: center, score: Float.greatestFiniteMagnitude)
        for dy in max(1, center - radius)...(center + radius) {
            guard dy < new.height else { continue }
            let s = overlapScore(new: new, ref: ref, dy: dy, rowStep: rowStep,
                                 earlyExit: best.score, needsWorst: false).mean
            if s < best.score { best = (dy, s) }
        }
        return best.dy
    }


    /// 對**整個重疊區**算零均值正規化相關（ZNCC），回傳 (mean, worst)：
    /// - mean：全重疊區的 1−ZNCC。ZNCC 已正規化，因此不同大小的重疊可以公平比較。
    /// - worst：把重疊區切四等分各算一次，取最差的一份——用來抓局部污染（影片區、動態元件）。
    ///   只看有足夠訊號的區塊，否則低紋理區塊的相關性由雜訊主導、必然趨零，
    ///   納入判定會把正常影格誤判成局部污染（實測 ±6 雜訊即誤殺）。
    ///
    /// 為什麼是整個重疊區，而不是取幾條 band（三次實測教訓，三個坑互相牽制）：
    /// ① 平坦 band 若當成「完美相關」會抹平分數曲面 → 大片留白／深色終端機永久判 ambiguous；
    /// ② 改成剔除平坦 band 後，band 位置隨位移改變 → 大位移剩少數 band 更容易得低分 →
    ///    系統性偏好過大位移（實測拼出 203% 的重複內容）；
    /// ③ 想用「固定 band 位置」兩全，卻在「窄（大位移才有效）vs 寬（稀疏內容才有料）」之間
    ///    無法同時滿足。整區 ZNCC 沒有這個取捨：去均值後平坦區對分子分母都貢獻趨零，
    ///    既不會冒充相關、也不會壓過真正有紋理的區域。
    ///
    /// public：selftest 需跨模組直接呼叫，驗證 L2 粗估的內部一致性。
    ///
    /// - Parameter rowStep: 列取樣間隔。粗掃層用 2 省成本；**最終層必須用 1**——
    ///   隔列取樣會讓分數對 ±1px 不敏感甚至排名反轉（實測 dy=201 的分數比正解 dy=200 還低）。
    /// - Parameter colStep: 欄取樣間隔。**與 rowStep 不對稱**：垂直位移的資訊在水平邊緣
    ///   （文字行的上下緣、分隔線），加大 colStep 只是少看幾欄、不影響垂直鑑別力；
    ///   加大 rowStep 則會跳過細橫線而失配。要省成本就動 colStep。
    /// - Note: 接受 `dy == 0`（步進估計要能判定「畫面在變但沒有一致平移」＝局部動畫）。
    ///   此時重疊區＝整格，`(r+dy)*w == r*w`，計分與四等分邏輯都自然成立。
    /// - Parameter needsWorst: 是否要算四等分的最差分。**四等分等於把重疊區再掃一遍**，
    ///   而所有「找最佳位移」的掃描迴圈都只看 `mean`——那些呼叫一律傳 false。
    ///   預設留 true 以維持既有語意：誤用時會拿到真實的 worst 而不是靜默放行的假值。
    public static func overlapScore(new: LumaPlane, ref: LumaPlane, dy: Int,
                                    rowStep: Int = 2, colStep: Int = 2,
                                    earlyExit: Float = .greatestFiniteMagnitude,
                                    needsWorst: Bool = true) -> (mean: Float, worst: Float) {
        guard dy >= 0, dy < ref.height else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        let overlap = new.height - dy
        guard overlap >= 16 else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        let w = new.width

        /// 指定列範圍的 1−ZNCC＋該範圍的每像素變異數（用來判斷這段是否有足夠訊號）。
        /// 無資訊（兩邊皆平坦）回 nil。
        func zn(_ rLo: Int, _ rHi: Int) -> (score: Float, varA: Float)? {
            var sa: Float = 0, sb: Float = 0, count: Float = 0
            var r = rLo
            while r < rHi {
                var c = 0
                let an = r * w, bn = (r + dy) * w
                while c < w { sa += new.v[an + c]; sb += ref.v[bn + c]; count += 1; c += colStep }
                r += rowStep
            }
            guard count > 0 else { return nil }
            let ma = sa / count, mb = sb / count
            var num: Float = 0, da: Float = 0, db: Float = 0
            r = rLo
            while r < rHi {
                var c = 0
                let an = r * w, bn = (r + dy) * w
                while c < w {
                    let a = new.v[an + c] - ma, b = ref.v[bn + c] - mb
                    num += a * b; da += a * a; db += b * b
                    c += colStep
                }
                r += rowStep
            }
            let denom = (da * db).squareRoot()
            let varA = da / count
            // 兩邊皆平坦＝無資訊（回 nil 讓呼叫端剔除，不可冒充「完美相關」）；
            // 一邊平坦一邊有紋理＝確實不相關。
            if denom <= 1e-6 { return (da < 1e-6 && db < 1e-6) ? nil : (1, varA) }
            return (1 - num / denom, varA)
        }

        guard let whole = zn(0, overlap) else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        let mean = whole.score
        if mean > earlyExit { return (.greatestFiniteMagnitude, mean) }
        guard needsWorst else { return (mean, 0) }
        // 四等分找最差的一份（局部污染防線）。**只看有足夠訊號的區塊**：低紋理區塊的相關性
        // 由雜訊主導、必然趨零，若納入判定會把正常影格誤判成局部污染（實測 ±6 雜訊即誤殺）。
        var worst: Float = 0
        let q = max(8, overlap / 4)
        var lo = 0
        while lo < overlap {
            let hi = min(lo + q, overlap)
            if hi - lo >= 8, let v = zn(lo, hi), v.varA >= whole.varA * 0.35 {
                worst = max(worst, v.score)
            }
            lo += q
        }
        return (mean, worst)
    }
}
