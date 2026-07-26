import CoreGraphics
import Foundation
import Vision

/// 一格影格經過三層匹配鏈後的結果。Session 只依此更新 HUD／決定收尾，不重複演算法邏輯。
public enum ScrollStitchOutcome: Equatable {
    /// 第一格：當長圖基準。
    case baseCaptured(height: Int)
    /// 累積捲動量還不足以產生可辨識位移——跳過本格，**不計失敗**（見 motionGate 說明）。
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
    /// 匹配成功但位移為 0（畫面沒動）。
    case noMotion
    /// 三層匹配鏈全敗。
    case rejected(consecutiveFailures: Int)
    /// 已達長度上限，該收工。
    case limitReached
}

/// 滾動截圖的影格消化引擎：擁有 stitcher／靜態帶鎖定／三層匹配鏈（金字塔 ZNCC → Vision 對帳
/// → 1-D 相位相關救援）與 motion gate。**不碰 UI、不碰 SCStream**，因此可在 selftest 用合成
/// 影格序列端到端驗證（spec §11 的整合覆蓋缺口就是靠這個補上）。
///
/// ### motionGate 的必要性（實測結論）
/// SCStream 以 30fps 供格，但使用者慢捲時「相鄰兩格」的位移常只有 2–8px。matcher 的
/// `minDelta = 14px` 是防雜訊誤匹配的底線，因此這些格必然被判 ambiguous／noOverlap。
/// 若把它們算成「失敗」，連續 10 次失敗只需 1/3 秒就會誤觸發收工——實機表現就是
/// 「長圖完全不增長、剛開始捲就結束」。
///
/// 解法不是調低 minDelta（會讓純色／雜訊區誤匹配），而是**先累積再匹配**：匹配基準永遠是
/// 長圖尾端（固定不動），所以只要使用者持續捲動，位移就會累積到超過門檻，屆時一次匹配成功
/// 接上完整距離，不會漏內容。門檻用滾輪累積量當「閘」而非「量測」——即使某 app 的實際捲動量
/// 與滾輪 delta 不成比例（spec §13 已知風險），保守跳過的格也會在下一格補上。
public final class ScrollStitchEngine {
    /// 累積滾輪位移（點）達此值才跑匹配鏈。約當 Retina 上 20px，略高於 minDelta=14px。
    public static let defaultMotionGatePoints: CGFloat = 10

    public private(set) var appendedFrameCount = 1
    public private(set) var consecutiveFailures = 0
    /// 最近一次 matcher 主判的結果字串（診斷用：區分 ambiguous／lowConfidence／noOverlap）。
    public private(set) var lastMatchNote = ""
    public var height: Int { stitcher?.height ?? 0 }
    public var isLocked: Bool { insets != nil }

    private let maxHeightPx: Int
    private let motionGatePoints: CGFloat
    private var stitcher: ScrollStitcher?
    private var insets: BandInsets?
    private var lastAcceptedFullFrame: PixelBuffer?
    private var priorDy: Int?
    private var lockAttempts = 0
    /// 滾輪符號 → 影像位移符號的對應（nil＝尚未學到）。AppKit 的 scrollingDeltaY 正負會隨裝置與
    /// 系統「自然捲動」設定翻轉，賭錯會讓 matcher 只搜反向、永遠拼不出東西。做法：未學到前允許
    /// 兩個方向都試，第一次成功匹配就把對應記下來，之後只搜推算出的方向——既與系統設定無關，
    /// 也不會在「本來就無法匹配」的快捲格上因反向搜尋撿到假峰（實測會污染長圖）。
    private var wheelToImageSign: Int?

    public init(maxHeightPx: Int, motionGatePoints: CGFloat = ScrollStitchEngine.defaultMotionGatePoints) {
        self.maxHeightPx = maxHeightPx
        self.motionGatePoints = motionGatePoints
    }

    /// - Parameters:
    ///   - wheelAccumulatedPoints: 呼叫端自上次「接受格」以來累積的滾輪位移（點）。engine 只把它
    ///     當 motion gate 的閘（見型別註解），不當位移量測；歸零由呼叫端在收到 appended/trimmed 後做。
    ///   - wheelDirection: +1 下捲／-1 上捲／0 無（決定 matcher 的方向閘門）。
    /// - Note: engine 的可變狀態只在單一（背景）執行緒上被觸碰——滾輪累積刻意不放在 engine 內，
    ///   否則主執行緒的滾輪事件會與背景的 consume 競態。
    public func consume(frame full: PixelBuffer,
                        wheelAccumulatedPoints: CGFloat,
                        wheelDirection: Int) -> ScrollStitchOutcome {
        guard let stitcher else {
            stitcher = ScrollStitcher(firstFrame: full, maxHeightPx: maxHeightPx)
            lastAcceptedFullFrame = full
            return .baseCaptured(height: full.height)
        }
        // motion gate：累積捲動不足就不浪費一次完整金字塔匹配，也不算失敗（見型別註解）。
        guard wheelAccumulatedPoints >= motionGatePoints else { return .waitingForMotion }

        let contentFrame: PixelBuffer
        if let insets {
            contentFrame = full.cropped(x: insets.left, y: insets.top,
                                        width: full.width - insets.left - insets.right,
                                        height: full.height - insets.top - insets.bottom)
        } else { contentFrame = full }

        let reference = stitcher.referenceTail(maxHeight: contentFrame.height)
        guard reference.height == contentFrame.height else { return .waitingForMotion }

        // 方向**不信任滾輪符號**：AppKit 的 scrollingDeltaY 正負會隨裝置與系統「自然捲動」設定翻轉，
        // 賭錯的話 matcher 只搜反向、真正的位移永遠找不到 → 零拼接（實機症狀：長圖＝單張影格）。
        // 做法：先試滾輪暗示的方向，失敗再試反向。成功時只跑一次（無額外成本），
        // 失敗時多跑一次換來對系統設定的完全免疫。
        let newLuma = LumaPlane(contentFrame)
        let refLuma = LumaPlane(reference)
        let rawWheelSign = wheelDirection >= 0 ? 1 : -1
        let primary = (wheelToImageSign ?? 1) * rawWheelSign
        var outcome = ScrollMatcher.match(new: newLuma, reference: refLuma,
                                          wheelDirection: primary, prior: priorDy)
        if wheelToImageSign == nil, case .accepted = outcome {} else if wheelToImageSign == nil {
            // 僅在對應未知時試反向（開場幾格），避免在無法匹配的快捲格上撿假峰
            let alternate = ScrollMatcher.match(new: newLuma, reference: refLuma,
                                                wheelDirection: -primary, prior: nil)
            if case .accepted = alternate { outcome = alternate }
        }
        lastMatchNote = "\(outcome)"
        if wheelToImageSign == nil, case let .accepted(dy, _) = outcome, dy != 0 {
            wheelToImageSign = (dy > 0 ? 1 : -1) * rawWheelSign
        }
        switch outcome {
        case let .accepted(dy, _) where dy > 0:
            return accept(dy: dy, full: full, contentFrame: contentFrame)
        case let .accepted(dy, _) where dy < 0:
            consecutiveFailures = 0
            priorDy = nil
            let trimmed = stitcher.cropTail(-dy)
            return trimmed > 0 ? .trimmed(amount: trimmed, totalHeight: stitcher.height) : .atOrigin
        case .accepted:
            consecutiveFailures = 0
            return .noMotion
        case .ambiguous, .lowConfidence, .noOverlap:
            return rescue(contentFrame: contentFrame, reference: reference, full: full,
                          wheelDirection: wheelDirection)
        }
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
        priorDy = dy
        appendedFrameCount += 1
        lastAcceptedFullFrame = full
        return .appended(dy: dy, totalHeight: stitcher.height)
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

    /// 第二層 Vision 對帳／引導重搜 → 第三層 1-D 相位相關救援（PC 不自帶 minDelta 閘，此處自套）。
    private func rescue(contentFrame: PixelBuffer, reference: PixelBuffer, full: PixelBuffer,
                        wheelDirection: Int) -> ScrollStitchOutcome {
        if let visionDy = visionEstimate(new: contentFrame, reference: reference),
           visionDy > 0,
           case let .accepted(dy, _) = ScrollMatcher.match(
               new: LumaPlane(contentFrame), reference: LumaPlane(reference),
               wheelDirection: 1, prior: visionDy, priorIsTrusted: true),
           abs(dy - visionDy) <= max(18, visionDy / 3) {
            return accept(dy: dy, full: full, contentFrame: contentFrame)
        }
        // PC 的 dy 來自 1-D 投影，實測常有 ±1px 誤差，且它自己沒有任何 ambiguity 閘門——
        // 因此**不可直接採用**（實測：完全沒有重疊的快捲影格會被 PC 給出假 dy 而拼進長圖）。
        // 一律交回 matcher 以它為 prior 複核：matcher 的 L0 精修會修掉 ±1px 誤差，
        // 而它的絕對閘＋比值閘（真匹配分數 0.0 vs 無重疊 0.43 且次低幾乎同分）能擋掉假匹配。
        if let (pcDy, _) = PhaseCorrelation1D.estimateShift(new: LumaPlane(contentFrame),
                                                           reference: LumaPlane(reference)),
           pcDy >= ScrollMatcher.Config.default.minDelta,
           case let .accepted(dy, _) = ScrollMatcher.match(
               new: LumaPlane(contentFrame), reference: LumaPlane(reference),
               wheelDirection: 1, prior: pcDy, priorIsTrusted: true),
           abs(dy - pcDy) <= max(18, pcDy / 3) {
            return accept(dy: dy, full: full, contentFrame: contentFrame)
        }
        consecutiveFailures += 1
        return .rejected(consecutiveFailures: consecutiveFailures)
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
