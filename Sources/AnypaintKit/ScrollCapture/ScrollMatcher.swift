import Foundation

public enum MatchOutcome: Equatable {
    case accepted(dy: Int, confidence: Double)
    case ambiguous
    case lowConfidence
    case noOverlap
}

/// 金字塔 ZNCC band 匹配（spec §7.1）。關係式：new[r] == ref[r+dy]（dy>0=下捲）。
/// 三層金字塔（1/4 全域 → 1/2 → 原解析度精修）；多 band 一致性；信心雙閘門；BPC 早停。
public enum ScrollMatcher {
    public struct Config {
        public var minDelta = 14              // 最小可信位移（px，原解析度）
        public var minOverlapFraction = 0.16  // 最小重疊 = max(96, H×此值)
        public var minOverlapPx = 96
        public var bandCount = 8
        public var bandHeight = 24            // 原解析度 band 高
        public var ratioGateMin = 1.3         // 次佳/最佳 需 ≥ 此值（次佳排除 ±exclusion）
        public var exclusionRadius = 24       // 次佳排除窗（原解析度 px）
        public var absoluteGateMax: Float = 0.35  // 最佳 band 平均分（1-ZNCC）絕對上限
        public var worstBandMax: Float = 0.60     // 最差 band 上限（局部污染防線）
        public var priorWeight = 0.15         // 速度先驗軟懲罰權重
        public static let `default` = Config()

        public init() {}
    }

    public static func match(new: LumaPlane, reference: LumaPlane,
                             wheelDirection: Int, prior: Int?,
                             config: Config = .default) -> MatchOutcome {
        guard new.width == reference.width, new.height == reference.height else { return .noOverlap }
        if wheelDirection < 0 {
            // 負向 = 翻轉兩圖跑正向再取負（一條路徑吃雙向；先驗同步鏡像）
            let r = matchPositive(new: new.flippedVertically(),
                                  reference: reference.flippedVertically(),
                                  prior: prior.map { -$0 }, config: config)
            if case let .accepted(dy, c) = r { return .accepted(dy: -dy, confidence: c) }
            return r
        }
        return matchPositive(new: new, reference: reference, prior: prior, config: config)
    }

    // MARK: - 正向主流程

    static func matchPositive(new: LumaPlane, reference: LumaPlane,
                              prior: Int?, config: Config) -> MatchOutcome {
        let h = new.height
        let minOverlap = max(config.minOverlapPx, Int(Double(h) * config.minOverlapFraction))
        let maxDy = h - minOverlap
        guard maxDy > config.minDelta else { return .noOverlap }

        // 金字塔：L0=原、L1=1/2、L2=1/4
        let n1 = new.downsampled(), n2 = n1.downsampled()
        let r1 = reference.downsampled(), r2 = r1.downsampled()

        // L2 全域掃（含先驗軟懲罰），保留 best 與排除窗外的 second 供 ambiguity 判定。
        // I1 修正：BPC 早停只對「次佳候選」設門檻（不能對 best，否則 best2 逼近 0 時
        // 門檻≈0，把所有真次佳候選提前殺光，second2 永遠登記不到、比值信心閘失效）。
        // M1 修正：second2 追蹤用未加先驗懲罰的 raw 分數；best 排序仍用含懲罰的 s；
        // 比值 = second2Raw / best2.raw，讓比值純反映影像證據、不被先驗污染。
        let l2Range = max(1, config.minDelta / 4)...max(1, maxDy / 4)
        var best2 = (dy: -1, score: Float.greatestFiniteMagnitude, raw: Float.greatestFiniteMagnitude)
        var second2Raw = Float.greatestFiniteMagnitude
        let excl2 = max(1, config.exclusionRadius / 4)
        for dy in l2Range {
            let raw = overlapScore(new: n2, ref: r2, dy: dy, earlyExit: second2Raw).mean
            guard raw.isFinite else { continue }                 // 被早停殺掉＝進不了 top-2
            var s = raw
            if let p = prior {
                s += Float(config.priorWeight) * min(1, abs(Float(dy * 4 - p)) / Float(h))
            }
            if s < best2.score {
                if best2.dy >= 0, abs(best2.dy - dy) > excl2 {
                    second2Raw = min(second2Raw, best2.raw)      // 舊 best 降級成次佳候選（raw）
                }
                best2 = (dy, s, raw)
            } else if abs(dy - best2.dy) > excl2, raw < second2Raw {
                second2Raw = raw
            }
        }
        guard best2.dy >= 0 else { return .noOverlap }
        // L2 ambiguity 早判：排除窗外的次佳貼著最佳 → 多解
        if second2Raw.isFinite, second2Raw / max(best2.raw, 1e-6) < 1.1 { return .ambiguous }

        // L1 → L0 逐層精修（±3）
        // 精修半徑 6（原為 3）：每上一層放大 2 倍，前一層的 ±1~2 量化誤差會變成 ±2~4，
        // ±3 只剩 1px 餘裕，實測會落在窗外導致 dy 差 1px（T5 審查已標記此風險）。
        let dy1 = refine(new: n1, ref: r1, center: best2.dy * 2, radius: 6, rowStep: 2)
        let dy0 = refine(new: new, ref: reference, center: dy1 * 2, radius: 6, rowStep: 1)
        guard dy0 >= config.minDelta, dy0 <= maxDy else { return .noOverlap }

        // 原解析度品質閘（絕對閘＋最差 band 閘）
        let q = overlapScore(new: new, ref: reference, dy: dy0, rowStep: 1)
        guard q.mean <= config.absoluteGateMax else { return .lowConfidence }
        guard q.worst <= config.worstBandMax else { return .ambiguous }   // 局部污染 → 不可信

        // 比值閘（用 L2 的全域 raw second 換算；epsilon 防除零；上限 cap 防 inf 外洩下游，I1 修正）
        let confidence = Double(min(second2Raw.isFinite ? second2Raw / max(best2.raw, 1e-6) : 1000, 1000))
        guard confidence >= config.ratioGateMin else { return .lowConfidence }
        return .accepted(dy: dy0, confidence: confidence)
    }

    static func refine(new: LumaPlane, ref: LumaPlane, center: Int, radius: Int,
                       rowStep: Int) -> Int {
        var best = (dy: center, score: Float.greatestFiniteMagnitude)
        for dy in max(1, center - radius)...(center + radius) {
            guard dy < new.height else { continue }
            let s = overlapScore(new: new, ref: ref, dy: dy, rowStep: rowStep,
                                 earlyExit: best.score).mean
            if s < best.score { best = (dy, s) }
        }
        return best.dy
    }


    /// 挑選 band 原點：**固定不隨候選 dy 改變**，橫跨整格等分成 n 槽，每槽取「逐列動態範圍
    /// 最大」的那一列（紋理最強）。
    ///
    /// 三個實測教訓都體現在這裡：
    /// 1. 位置必須固定：原本按 overlap 等分 → 大 dy 的 overlap 小、band 落在空白被剔除，
    ///    剩少數 band 更容易拿低分 → 系統性偏好過大位移（實測拼出 203% 的重複內容）。
    /// 2. 要挑有紋理的列：整片留白的 band 不具鑑別力，會讓分數曲面被抹平 → 永久判 ambiguous
    ///    （深色終端機／大片留白頁面的實機症狀）。
    /// 3. 不可只取「最小重疊」那一小段（曾限制在 [0, minOverlap-bh]）：那段剛好空白時全滅，
    ///    稀疏內容直接拼不動。橫跨整格取樣，再對「可用 band 較少」的候選加罰來維持公平。
    /// 對**整個重疊區**算正規化相關（ZNCC），回傳 (mean, worst)：
    /// - mean：全重疊區的 1−ZNCC。ZNCC 已正規化，因此不同大小的重疊可以公平比較，
    ///   不需要 band 取樣，也就沒有「band 位置隨位移改變造成偏差」的問題。
    /// - worst：把重疊區切四等分各算一次，取最差的一份——用來抓局部污染（影片區、動態元件）。
    ///
    /// 為什麼放棄原本的多 band 取樣（三次實測教訓）：
    /// ① 平坦 band 若當成「完美相關」會抹平分數曲面 → 大片留白／深色終端機永久判 ambiguous；
    /// ② 改成剔除平坦 band 後，band 位置隨位移改變 → 大位移剩少數 band 更容易得低分 →
    ///    系統性偏好過大位移（實測拼出 203% 的重複內容）；
    /// ③ 想用「固定 band 位置」兩全，卻在「窄（大位移才有效）vs 寬（稀疏內容才有料）」之間
    ///    無法同時滿足。整區 ZNCC 沒有這個取捨：去均值後平坦區對分子分母都貢獻趨零，
    ///    既不會冒充相關、也不會壓過真正有紋理的區域。
    /// 取樣：列與欄各取 1/2 以控制成本（不影響相關性判斷的統計意義）。
    /// public：selftest 需跨模組直接呼叫，驗證 L2 粗估的內部一致性。
    /// - Parameter rowStep: 列取樣間隔。粗掃層用 2 省成本；**最終層必須用 1**——
    ///   隔列取樣會讓分數對 ±1px 不敏感甚至排名反轉（實測 dy=201 的分數比正解 dy=200 還低）。
    public static func overlapScore(new: LumaPlane, ref: LumaPlane, dy: Int,
                                    rowStep: Int = 2,
                                    earlyExit: Float = .greatestFiniteMagnitude) -> (mean: Float, worst: Float) {
        guard dy > 0, dy < ref.height else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        let overlap = new.height - dy
        guard overlap >= 16 else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        let w = new.width
        let colStep = 2

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

    /// 兩段列區間的 ZNCC（零均值正規化互相關）。1=完全相關、0=不相關。
    /// 對線性亮度變化免疫（vibrancy／次像素重繪的位準漂移，spec §7.1）。
    static func zncc(new: LumaPlane, newRow: Int, ref: LumaPlane, refRow: Int,
                     rows: Int, width: Int) -> Float {
        let count = rows * width
        var sumA: Float = 0, sumB: Float = 0
        for i in 0..<count {
            sumA += new.v[newRow * width + i]
            sumB += ref.v[refRow * width + i]
        }
        let meanA = sumA / Float(count), meanB = sumB / Float(count)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<count {
            let a = new.v[newRow * width + i] - meanA
            let b = ref.v[refRow * width + i] - meanB
            num += a * b; da += a * a; db += b * b
        }
        let denom = (da * db).squareRoot()
        guard denom > 1e-6 else {
            // 兩邊皆平坦＝**無資訊**（回 .nan 由呼叫端剔除），不可回 1「完美相關」：
            // 平坦 band 在任何位移下都會投「完美」，把分數曲面抹平 → 最佳與次佳同分 →
            // 全部判 ambiguous。實測（深色終端機／大片留白的頁面）就是這樣永久拒絕拼接。
            // 一邊平坦一邊有紋理＝確實不相關，回 0。
            return (da < 1e-6 && db < 1e-6) ? Float.nan : 0
        }
        return num / denom
    }
}
