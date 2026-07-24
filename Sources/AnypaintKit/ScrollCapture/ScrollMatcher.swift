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

        // L2 全域掃（含先驗軟懲罰），保留 best 與排除窗外的 second 供 ambiguity 判定
        let l2Range = max(1, config.minDelta / 4)...max(1, maxDy / 4)
        var best2 = (dy: -1, score: Float.greatestFiniteMagnitude)
        var second2 = Float.greatestFiniteMagnitude
        let excl2 = max(1, config.exclusionRadius / 4)
        for dy in l2Range {
            var s = bandScore(new: n2, ref: r2, dy: dy, config: config, level: 4,
                              earlyExit: min(best2.score, second2))
            if let p = prior {
                s += Float(config.priorWeight) * min(1, abs(Float(dy * 4 - p)) / Float(h))
            }
            if s < best2.score {
                if best2.dy >= 0, abs(best2.dy - dy) > excl2 { second2 = best2.score }
                best2 = (dy, s)
            } else if abs(dy - best2.dy) > excl2, s < second2 {
                second2 = s
            }
        }
        guard best2.dy >= 0 else { return .noOverlap }
        // L2 ambiguity 早判：排除窗外的次佳貼著最佳 → 多解
        if second2.isFinite, second2 / max(best2.score, 1e-6) < 1.1 { return .ambiguous }

        // L1 → L0 逐層精修（±3）
        let dy1 = refine(new: n1, ref: r1, center: best2.dy * 2, radius: 3, config: config, level: 2)
        let dy0 = refine(new: new, ref: reference, center: dy1 * 2, radius: 3, config: config, level: 1)
        guard dy0 >= config.minDelta, dy0 <= maxDy else { return .noOverlap }

        // 原解析度品質閘（絕對閘＋最差 band 閘）
        let q = bandScoreDetail(new: new, ref: reference, dy: dy0, config: config, level: 1)
        guard q.mean <= config.absoluteGateMax else { return .lowConfidence }
        guard q.worst <= config.worstBandMax else { return .ambiguous }   // 局部污染 → 不可信

        // 比值閘（用 L2 的全域 second 換算；epsilon 防除零）
        let confidence = Double(second2.isFinite ? second2 / max(best2.score, 1e-6) : 10)
        guard confidence >= config.ratioGateMin else { return .lowConfidence }
        return .accepted(dy: dy0, confidence: confidence)
    }

    static func refine(new: LumaPlane, ref: LumaPlane, center: Int, radius: Int,
                       config: Config, level: Int) -> Int {
        var best = (dy: center, score: Float.greatestFiniteMagnitude)
        for dy in max(1, center - radius)...(center + radius) {
            guard dy < new.height else { continue }
            let s = bandScore(new: new, ref: ref, dy: dy, config: config, level: level,
                              earlyExit: best.score)
            if s < best.score { best = (dy, s) }
        }
        return best.dy
    }

    /// 多 band 平均 (1-ZNCC)。earlyExit：部分和已超過門檻即棄（BPC 早停——
    /// 各 band 分數非負，部分和是總分下界）。
    /// public：測試需跨模組（anypaint-selftest）直接呼叫驗證金字塔 L2 內部一致性。
    public static func bandScore(new: LumaPlane, ref: LumaPlane, dy: Int,
                          config: Config, level: Int, earlyExit: Float) -> Float {
        let d = bandScoreDetail(new: new, ref: ref, dy: dy, config: config,
                                level: level, earlyExit: earlyExit)
        return d.mean
    }

    static func bandScoreDetail(new: LumaPlane, ref: LumaPlane, dy: Int,
                                config: Config, level: Int,
                                earlyExit: Float = .greatestFiniteMagnitude)
        -> (mean: Float, worst: Float) {
        let overlap = new.height - dy               // new rows [0, overlap) ↔ ref rows [dy, dy+overlap)
        let bh = max(4, config.bandHeight / level)
        let n = config.bandCount
        guard overlap >= bh else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        var total: Float = 0, worst: Float = 0, counted = 0
        for i in 0..<n {
            let r0 = (overlap - bh) * i / max(1, n - 1)
            let s = 1 - zncc(new: new, newRow: r0, ref: ref, refRow: r0 + dy,
                             rows: bh, width: new.width)
            total += s; worst = max(worst, s); counted += 1
            if total > earlyExit * Float(n) { return (.greatestFiniteMagnitude, worst) }  // BPC
        }
        return (total / Float(counted), worst)
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
        guard denom > 1e-6 else { return da < 1e-6 && db < 1e-6 ? 1 : 0 }  // 兩邊皆平坦=相同；一邊平坦=不相關
        return num / denom
    }
}
