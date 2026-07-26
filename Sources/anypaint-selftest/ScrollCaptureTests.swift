import CoreGraphics
import Foundation
import Vision
import AnypaintKit

/// Task 2 實測結論：Vision alignmentTransform.ty 的單位（true=pixel）。
/// 實測（visionTyUnitTest，400×600 合成影格，B 相對 A 於頁面內向下捲 137px）：ty == -137.0（精確值，
/// 無次像素模糊——合成測資無縮放/濾波）。|ty|==137 與影像位移像素數一致 → 單位是 pixel（非 point、非
/// 0–1 normalized）。
///
/// 正負號規則（B 為 targeted/floating、A 為 handler/reference 時）：
/// Vision 內部座標系原點左下、y 軸向上（與 raster 的左上原點、y 向下相反）。alignmentTransform 是把
/// floating（B）對齊到 reference（A）的變換，即 P_A = P_B + (tx, ty)（純平移下）。
/// 因此 ty = (A 在 Vision y-up 座標系的 y) − (B 在 Vision y-up 座標系的 y)。
/// B 的內容若在 raster 座標（左上原點）相對 A 向下捲動（raster row 增加、頁面往下滑），
/// 在 y-up 座標系裡等於「變高」，故 ty 為負；換算回 raster 的向下捲動量（正值＝向下捲）＝ -ty。
/// Task 12 對帳時直接用：scrollDownPixels = -ty。
/// 由 visionTyUnitTest 持續看守——Vision 行為改變時此測試會先紅。
let visionTyIsInPixels = true




func runScrollCaptureTests() {
    fastScrollRecoveryTests()
    wheelSignIndependenceTests()
    sparseContentTests()
    scrollStitchEngineTests()
    visionTyUnitTest()
    pixelBufferTests()
    scrollCoordsTests()
    staticBandTests()
    scrollMatcherTests()
    phaseCorrelationTests()
    scrollStitcherTests()
    scrollGuidanceTests()
}

/// 量測 Vision registration 回傳的 ty 單位：
/// 造兩張 400×600 的合成影格，B 相對 A 往下捲 137 px（質數避開巧合）。
/// 期望 ty == -137（B 需上移 137px 對齊 A）或 +137——正負號與 pixel/point 皆以本測試輸出為準，
/// 測出後把斷言鎖死成文件。
func visionTyUnitTest() {
    let page = SyntheticPage.make(width: 400, height: 1200, seed: 42)
    let a = SyntheticPage.window(page, y: 0, height: 600)
    let b = SyntheticPage.window(page, y: 137, height: 600)
    guard let cgA = a.makeCGImage(), let cgB = b.makeCGImage() else {
        T.checkTrue("vision-ty: 測資轉 CGImage", false); return
    }
    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: cgB)
    let handler = VNImageRequestHandler(cgImage: cgA, options: [:])
    do { try handler.perform([request]) } catch {
        T.checkTrue("vision-ty: perform 不丟錯（\(error)）", false); return
    }
    guard let obs = request.results?.first else {
        T.checkTrue("vision-ty: 有 observation", false); return
    }
    let ty = obs.alignmentTransform.ty
    // 第一次執行時先印出實測值，據此把下面斷言的期望值鎖死：
    print("ℹ️ vision-ty 實測值：\(ty)（影像位移 137px）")
    // 實測鎖死：ty == -137.0（精確、無次像素模糊——合成測資無縮放/濾波）。
    // 單位＝pixel：|ty| 與影像位移像素數相符（非 0–1 normalized、非 point）。
    T.checkTrue("vision-ty: |ty| == 137（單位為 pixel）", abs(abs(ty) - 137) < 1.5)
    // 正負號：B（targeted/floating）相對 A（reference）在頁面內向下捲 137px → ty 為負
    // （見上方 visionTyIsInPixels 常數註解的完整推導；Task 12 用 scrollDownPixels = -ty）。
    T.checkTrue("vision-ty: 向下捲動時 ty 為負（符號規則）", ty < 0)
}

func pixelBufferTests() {
    // CGImage 往返
    let page = SyntheticPage.make(width: 64, height: 64, seed: 1)
    if let cg = page.makeCGImage(), let back = PixelBuffer(cgImage: cg) {
        T.checkEq("pixelbuffer: CGImage 往返尺寸", back.width * 10000 + back.height, 64 * 10000 + 64)
        T.checkTrue("pixelbuffer: CGImage 往返內容一致",
                    zip(back.bytes, page.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })  // 色彩管理容差
    } else { T.checkTrue("pixelbuffer: CGImage 往返", false) }

    // 通道順序鑑別：灰階測資對 R/B 對調零鑑別力（審查 Important）——用彩色像素守 RGBA 順序。
    var colored = [UInt8](repeating: 255, count: 2 * 2 * 4)
    colored[0] = 200; colored[1] = 10; colored[2] = 30    // (0,0) 偏紅
    colored[4] = 10; colored[5] = 200; colored[6] = 30    // (1,0) 偏綠
    colored[8] = 10; colored[9] = 30; colored[10] = 200   // (0,1) 偏藍
    let cbuf = PixelBuffer(width: 2, height: 2, bytes: colored)
    if let ccg = cbuf.makeCGImage(), let cback = PixelBuffer(cgImage: ccg) {
        T.checkTrue("pixelbuffer: 通道順序（R 像素 R>B）", cback.bytes[0] > 100 && cback.bytes[2] < 100)
        T.checkTrue("pixelbuffer: 通道順序（B 像素 B>R）", cback.bytes[10] > 100 && cback.bytes[8] < 100)
        T.checkTrue("pixelbuffer: 通道順序（G 像素）", cback.bytes[5] > 100)
    } else { T.checkTrue("pixelbuffer: 通道順序往返", false) }

    // crop
    let c = page.cropped(x: 8, y: 8, width: 16, height: 16)
    T.checkEq("pixelbuffer: crop 尺寸", c.width * 100 + c.height, 1616)
    T.checkEq("pixelbuffer: crop 內容（左上像素）",
              Int(c.bytes[0]), Int(page.bytes[(8 * 64 + 8) * 4]))

    // luma 翻轉自反
    let l = LumaPlane(page)
    T.checkTrue("luma: 翻轉兩次 == 原圖", l.flippedVertically().flippedVertically().v == l.v)
    // 降採樣尺寸
    T.checkEq("luma: 降採樣尺寸", l.downsampled().width * 100 + l.downsampled().height, 3232)

    // 奇數尺寸：捨去最後一列/欄（65→32）
    let odd = LumaPlane(width: 65, height: 65, v: [Float](repeating: 7, count: 65 * 65))
    T.checkEq("luma: 奇數降採樣 65→32", odd.downsampled().width * 100 + odd.downsampled().height, 3232)
}

func scrollCoordsTests() {
    // Retina 2x：主螢幕 1728×1117 點、選區 (100.3, 200.7, 300.2, 400.9)
    let g = ScrollCoords.streamGeometry(
        selectionGlobal: CGRect(x: 100.3, y: 200.7, width: 300.2, height: 400.9),
        screenFrameGlobal: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        scale: 2)
    // 手算（unit=0.5pt，origin 向下取整、max 向上取整到 0.5 倍數，已對答案鎖死）：
    //   alignedX   = floor(100.3/0.5)*0.5 = 100.0
    //   alignedY   = floor(200.7/0.5)*0.5 = 200.5
    //   alignedMaxX= ceil(400.5/0.5)*0.5  = 400.5   （selection.maxX = 100.3+300.2 = 400.5，恰為格點）
    //   alignedMaxY= ceil(601.6/0.5)*0.5  = 602.0   （selection.maxY = 200.7+400.9 = 601.6 → 上取到 602.0）
    //   w = 400.5-100.0 = 300.5, h = 602.0-200.5 = 401.5
    //   pixelWidth  = round(300.5*2) = 601
    //   pixelHeight = round(401.5*2) = 803
    T.checkEq("coords: pixelWidth", g.pixelWidth, Int(((400.5 - 100.0) * 2).rounded()))
    T.checkEq("coords: pixelHeight", g.pixelHeight, Int(((602.0 - 200.5) * 2).rounded()))
    T.checkTrue("coords: sourceRect minX", abs(g.sourceRect.minX - 100.0) < 0.001)
    T.checkTrue("coords: sourceRect width", abs(g.sourceRect.width - 300.5) < 0.001)
    T.checkTrue("coords: sourceRect Y 翻轉（上左原點）",
                abs(g.sourceRect.minY - (1117 - 200.5 - (602.0 - 200.5))) < 0.001)
    // scale=1 螢幕：對齊到整數點
    let g1 = ScrollCoords.streamGeometry(
        selectionGlobal: CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.9),
        screenFrameGlobal: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        scale: 1)
    T.checkTrue("coords: 副螢幕（負 x 全域座標）sourceRect 為螢幕相對", g1.sourceRect.minX >= 0)
    T.checkEq("coords: scale=1 pixelWidth == 點寬", g1.pixelWidth, 101)
    T.checkEq("coords: scale=1 pixelHeight == 點高", g1.pixelHeight, 52)
}

func staticBandTests() {
    let page = SyntheticPage.make(width: 600, height: 2000, seed: 7)
    func framePair(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0,
                   dy: Int) -> (LumaPlane, LumaPlane) {
        var a = SyntheticPage.window(page, y: 100, height: 700)
        var b = SyntheticPage.window(page, y: 100 + dy, height: 700)
        SyntheticPage.stamp(&a, top: top, bottom: bottom, left: left, right: right, seed: 99)
        SyntheticPage.stamp(&b, top: top, bottom: bottom, left: left, right: right, seed: 99)
        return (LumaPlane(a), LumaPlane(b))
    }
    let (a1, b1) = framePair(top: 80, dy: 200)
    T.checkEq("staticband: 頂帶 80", StaticBandDetector.detect(frameA: a1, frameB: b1, dy: 200)?.top ?? -1, 80)
    let (a2, b2) = framePair(bottom: 60, dy: 200)
    // 期望值調整（測資物理，非演算法偏離）：SyntheticPage.make 的行高 14＋行距 6＝週期 20px，
    // 逐列判定是「整頁」層級的性質（與 x 縮排無關），window offset 100、300 皆是 20 的倍數，
    // dy=200 也剛好是 20 的倍數 → 兩格在 r%20 相同時對到同一相位，行距空白列（r%20 ∈ [14,20)）
    // 在整頁範圍內天生逐列全白、恆等。stamp 只蓋到列 640..<700（bottom=60）；列 634..639
    // （相對 h-1-bottom 掃描方向，r%20 ∈ [14,20) 共 6 列）落在下一個「行距空白」相位、
    // 兩格恰好同時為純白，於閾值 3.0 下持續判定為「未位移」，直到列 633（r%20=13，進入行內容
    // 相位）才真正出現隨機字詞內容差異而停止。故偵測到的底帶比 stamp 出的 60 多 6 列，是
    // 「dy 恰為行週期倍數」這個測資選擇造成的邊界延伸，非演算法實作錯誤（已用
    // r%20 手算核對：634~639 全屬 [14,20) 空白相位、633 起才進入 [0,14) 內容相位）。
    T.checkEq("staticband: 底帶 60（+6 因 SyntheticPage 行週期 20 與 dy=200 對齊，見上方註解）",
              StaticBandDetector.detect(frameA: a2, frameB: b2, dy: 200)?.bottom ?? -1, 66)
    let (a3, b3) = framePair(left: 90, right: 15, dy: 200)
    let i3 = StaticBandDetector.detect(frameA: a3, frameB: b3, dy: 200)
    T.checkEq("staticband: 左帶 90", i3?.left ?? -1, 90)
    T.checkEq("staticband: 右帶 15（捲軸寬）", i3?.right ?? -1, 15)
    let (a4, b4) = framePair(top: 80, bottom: 60, left: 20, right: 15, dy: 200)
    // 同上「底帶 60」的行週期／dy 對齊理由：此處 stamp 的 bottom=60，掃描仍會多吃到 6 列
    // 空白相位列才停在真正的內容差異，故底帶同樣是 66 而非 60；top/left/right 不受影響
    // （它們的掃描邊界落在行內容相位，第一列就出現隨機字詞差異，如實停在 stamp 邊界）。
    T.checkEq("staticband: 四向同時（bottom +6，理由同上）", StaticBandDetector.detect(frameA: a4, frameB: b4, dy: 200),
              BandInsets(top: 80, bottom: 66, left: 20, right: 15))
    let (a5, b5) = framePair(dy: 200)
    // 期望值調整（測資物理）：無 stamp 時，同樣的行週期／dy 對齊效應使底帶多出 6 列
    // （h-1=699，r%20=19 為空白相位起點，往上數到 693 為止皆空白，693 之後才是內容相位）。
    // 另外左帶多出 1：SyntheticPage.make 每行縮排是 `rng.int(30)`（0~29 隨機），欄 0 只有極少數
    // 行的縮排恰為 0 時才會被文字覆蓋，其餘多數列在欄 0 是白底——對 694 列取欄 0 的逐列均差，
    // 白底列稀釋掉少數字詞列的差異，均差落在 3.0 閾值以下，故欄 0 判定為「靜態」，欄 1 起因文字
	// 覆蓋機率上升、均差超過閾值而停止。此為 seed=7 頁面內容分布造成的邊界延伸，非演算法偏離。
    T.checkEq("staticband: 無靜態帶 → bottom 6／left 1（見上方註解，非全 0）",
              StaticBandDetector.detect(frameA: a5, frameB: b5, dy: 200),
              BandInsets(top: 0, bottom: 6, left: 1, right: 0))
    // 整張純色：兩格逐位元組完全相同（同一個 LumaPlane 實例）。
    // 【控制者裁決 Task 4：加退化守門，修回 brief 原意】：
    // r1-r0 > h/3 防呆在「上下帶皆封頂」時數學上不可達（3h/5 恆大於 h/3），若無額外守門，
    // 整張純色頁會誤回滿頂 BandInsets(140,140,100,100)。StaticBandDetector.detect 已補上
    // 「四向同時封頂 → nil」的退化守門（真實頁面不會四向全頂到 cap，只有純色/全靜態頁會），
    // 堵住這個數學缺口，使此案例如 spec 原意般回傳 nil（「無法判定」）。
    let solid = LumaPlane(SyntheticPage.solid(width: 600, height: 700, gray: 200))
    T.checkEq("staticband: 純色頁 → nil（四向全頂退化守門，見上方註解）",
              StaticBandDetector.detect(frameA: solid, frameB: solid, dy: 200),
              nil)
    // 封頂：塞一個 300px 的「假頂帶」也只回報 cap（min(700/5,160)=140）
    let (a6, b6) = framePair(top: 300, dy: 350)
    T.checkEq("staticband: 頂帶封頂 140", StaticBandDetector.detect(frameA: a6, frameB: b6, dy: 350)?.top ?? -1, 140)
    // 偽 vibrancy：頂帶相同紋理再加 ±4 雜訊——閾值 3.0 抓不到？故意驗：加雜訊後每列均差≈2.0 仍 < 3.0 → 仍測得到
    var av = SyntheticPage.window(page, y: 100, height: 700)
    var bv = SyntheticPage.window(page, y: 300, height: 700)
    SyntheticPage.stamp(&av, top: 80, seed: 99); SyntheticPage.stamp(&bv, top: 80, seed: 99)
    SyntheticPage.addNoise(&av, amplitude: 2, seed: 11); SyntheticPage.addNoise(&bv, amplitude: 2, seed: 22)
    let iv = StaticBandDetector.detect(frameA: LumaPlane(av), frameB: LumaPlane(bv), dy: 200)
    T.checkTrue("staticband: 偽 vibrancy（±2 雜訊）頂帶 78~82", (78...82).contains(iv?.top ?? -1))
}

func scrollMatcherTests() {
    let page = SyntheticPage.make(width: 500, height: 4000, seed: 3)
    func nb0() -> PixelBuffer { SyntheticPage.window(page, y: 500, height: 800) }
    func frames(_ dy: Int, h: Int = 800) -> (LumaPlane, LumaPlane) {
        (LumaPlane(SyntheticPage.window(page, y: 500 + dy, height: h)),
         LumaPlane(SyntheticPage.window(page, y: 500, height: h)))
    }
    func acceptedDy(_ o: MatchOutcome) -> Int? {
        if case let .accepted(dy, _) = o { return dy }; return nil
    }
    // 已知位移 小/中/大
    for dy in [30, 200, 620] {   // 620 < 800−max(96, 800×0.16)=672 上限內
        let (n, r) = frames(dy)
        T.checkEq("matcher: dy=\(dy) 精確命中",
                  acceptedDy(ScrollMatcher.match(new: n, reference: r, wheelDirection: 1, prior: nil)) ?? -1, dy)
    }
    // I1 迴歸：唯一匹配的 confidence 必須有限且過閘（修前為 inf/垃圾值——BPC 早停用
    // min(best2.score, second2) 對 best 也早停，best2 逼近 0 時門檻≈0，真次佳候選被提前
    // 殺掉、second2 永遠登記不到 → confidence 溢位）
    for dy in [30, 200, 620] {
        let (n, r) = frames(dy)
        if case let .accepted(_, c) = ScrollMatcher.match(new: n, reference: r, wheelDirection: 1, prior: nil) {
            T.checkTrue("matcher: dy=\(dy) confidence 有限且 ≥1.3（I1 迴歸）", c.isFinite && c >= 1.3 && c <= 1000)
        } else { T.checkTrue("matcher: dy=\(dy) confidence 迴歸取樣", false) }
    }
    // 位移 0（低於 minDelta）→ 不可 accepted
    let (n0, r0) = frames(0)
    T.checkTrue("matcher: dy=0 不為 accepted",
                acceptedDy(ScrollMatcher.match(new: n0, reference: r0, wheelDirection: 1, prior: nil)) == nil)
    // 負向（回捲）：鏡像機制
    let (nn, rn) = frames(200)
    T.checkEq("matcher: 負向 dy=-200（角色互換＋wheel=-1）",
              acceptedDy(ScrollMatcher.match(new: rn, reference: nn, wheelDirection: -1, prior: nil)) ?? 0, -200)
    // 滾輪閘門未開（wheel=+1）時同樣輸入不可回報負值
    let posOnly = ScrollMatcher.match(new: rn, reference: nn, wheelDirection: 1, prior: nil)
    T.checkTrue("matcher: 閘門未開不輸出負 dy", (acceptedDy(posOnly) ?? 0) >= 0)
    // 重複紋理 → ambiguous
    let stripes = LumaPlane(SyntheticPage.periodicStripes(width: 500, height: 800, period: 48))
    T.checkEq("matcher: 週期紋理 → ambiguous",
              ScrollMatcher.match(new: stripes, reference: stripes, wheelDirection: 1, prior: nil), MatchOutcome.ambiguous)
    // 純色 → 非 accepted（lowConfidence 或 ambiguous 皆可，鎖「不硬猜」）
    let solid = LumaPlane(SyntheticPage.solid(width: 500, height: 800, gray: 128))
    T.checkTrue("matcher: 純色不硬猜",
                acceptedDy(ScrollMatcher.match(new: solid, reference: solid, wheelDirection: 1, prior: nil)) == nil)
    // 雜訊（±6，模擬次像素重繪）仍精確
    var na = SyntheticPage.window(page, y: 700, height: 800)
    var nb = SyntheticPage.window(page, y: 500, height: 800)
    SyntheticPage.addNoise(&na, amplitude: 6, seed: 5); SyntheticPage.addNoise(&nb, amplitude: 6, seed: 9)
    T.checkEq("matcher: ±6 雜訊 dy=200",
              acceptedDy(ScrollMatcher.match(new: LumaPlane(na), reference: LumaPlane(nb), wheelDirection: 1, prior: nil)) ?? -1, 200)
    // 非整數位移：dy=200 的影格經 0.5px 垂直重採樣 → 容差 ±1
    let half = SyntheticPage.window(page, y: 700, height: 801)
    var resampled = [UInt8](repeating: 0, count: 500 * 800 * 4)
    for r in 0..<800 { for c in 0..<(500 * 4) {
        let a = Int(half.bytes[r * 500 * 4 + c]), b = Int(half.bytes[(r + 1) * 500 * 4 + c])
        resampled[r * 500 * 4 + c] = UInt8((a + b) / 2)
    } }
    let halfShift = LumaPlane(PixelBuffer(width: 500, height: 800, bytes: resampled))
    let got = acceptedDy(ScrollMatcher.match(new: halfShift, reference: LumaPlane(nb0()), wheelDirection: 1, prior: nil)) ?? -999
    T.checkTrue("matcher: 0.5px 重採樣 dy≈200（±1）", abs(got - 200) <= 1)
    // 動態塊污染：new 影格中央蓋 120×120 隨機塊，多 band 仍算對
    var dyn = SyntheticPage.window(page, y: 700, height: 800)
    SyntheticPage.stampDynamicBlock(&dyn, x: 190, y: 340, w: 120, h: 120, seed: 77)
    T.checkEq("matcher: 動態塊污染仍 dy=200",
              acceptedDy(ScrollMatcher.match(new: LumaPlane(dyn), reference: LumaPlane(nb0()), wheelDirection: 1, prior: nil)) ?? -1, 200)
    // 先驗軟懲罰不鎖死：prior=500 但真值 200，仍應命中 200（軟不是硬）
    let (np, rp) = frames(200)
    T.checkEq("matcher: 先驗偏差大仍命中真值（軟懲罰）",
              acceptedDy(ScrollMatcher.match(new: np, reference: rp, wheelDirection: 1, prior: 500)) ?? -1, 200)
    // 金字塔一致性：dy=200 在 L2（÷4=50）就該在正確位置附近（此為內部函式測試）
    let (nq, rq) = frames(200)
    let n2 = nq.downsampled().downsampled(), r2 = rq.downsampled().downsampled()
    var bestL2 = (dy: -1, s: Float.greatestFiniteMagnitude)
    for d in 1...170 {
        let s = ScrollMatcher.overlapScore(new: n2, ref: r2, dy: d).mean
        if s < bestL2.s { bestL2 = (d, s) }
    }
    T.checkTrue("matcher: L2 粗估在 50±1", abs(bestL2.dy - 50) <= 1)
}

func phaseCorrelationTests() {
    let page = SyntheticPage.make(width: 500, height: 4000, seed: 3)
    let ref = LumaPlane(SyntheticPage.window(page, y: 500, height: 800))
    let new = LumaPlane(SyntheticPage.window(page, y: 700, height: 800))
    let r = PhaseCorrelation1D.estimateShift(new: new, reference: ref)
    T.checkTrue("phasecorr: dy=200 誤差 ≤1", abs((r?.dy ?? -999) - 200) <= 1)
    // 重複紋理 → 多峰 → nil
    let stripes = LumaPlane(SyntheticPage.periodicStripes(width: 500, height: 800, period: 48))
    T.checkTrue("phasecorr: 週期紋理 → nil", PhaseCorrelation1D.estimateShift(new: stripes, reference: stripes) == nil)
    // 獨立性：特徵稀疏（大片純色+一條細線）讓 band matcher 失敗、相位相關仍中
    var sparseA = SyntheticPage.solid(width: 500, height: 800, gray: 250)
    var sparseB = SyntheticPage.solid(width: 500, height: 800, gray: 250)
    // 只有一條 3px 深色橫線：A 在 y=400、B 在 y=250（=下捲 150）
    for r0 in 400..<403 { for c in 0..<500 {
        let o = (r0 * 500 + c) * 4; sparseA.bytes[o] = 20; sparseA.bytes[o+1] = 20; sparseA.bytes[o+2] = 20 } }
    for r0 in 250..<253 { for c in 0..<500 {
        let o = (r0 * 500 + c) * 4; sparseB.bytes[o] = 20; sparseB.bytes[o+1] = 20; sparseB.bytes[o+2] = 20 } }
    let sr = PhaseCorrelation1D.estimateShift(new: LumaPlane(sparseB), reference: LumaPlane(sparseA))
    T.checkTrue("phasecorr: 特徵稀疏救援 dy=150±1", abs((sr?.dy ?? -999) - 150) <= 1)
}

func scrollStitcherTests() {
    let page = SyntheticPage.make(width: 400, height: 3000, seed: 21)
    let h = 600

    // 端到端：位移序列 [180, 250, 90]，拼完應逐像素等於 page[0, 600+520)
    var st = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 30000)
    st.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h))
    var pos = 0
    for dy in [180, 250, 90] {
        pos += dy
        T.checkTrue("stitcher: append dy=\(dy)",
                    st.append(contentFrame: SyntheticPage.window(page, y: pos, height: h), dy: dy))
    }
    T.checkEq("stitcher: 總高 = 600+Σdy", st.height, 600 + 520)
    let expected = SyntheticPage.window(page, y: 0, height: 600 + 520)
    if let cg = st.finalize(), let got = PixelBuffer(cgImage: cg) {
        T.checkTrue("stitcher: 端到端逐像素相同",
                    zip(got.bytes, expected.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    } else { T.checkTrue("stitcher: finalize", false) }

    // 回捲組（裁尾是不可逆操作——此組是防線非裝飾，spec §11）
    var st2 = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 30000)
    st2.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h))
    _ = st2.append(contentFrame: SyntheticPage.window(page, y: 300, height: h), dy: 300)
    T.checkEq("stitcher: 裁尾 120 → 實裁 120", st2.cropTail(120), 120)
    T.checkEq("stitcher: 裁尾後高度", st2.height, 600 + 300 - 120)
    // 裁到起點即停：再裁 500 只能裁 180
    T.checkEq("stitcher: 裁到 base 停（600）", st2.cropTail(500), 180)
    T.checkEq("stitcher: 起點後高度不再減", st2.cropTail(50), 0)
    // 回捲後重拼：來回多次端到端仍逐像素正確
    _ = st2.append(contentFrame: SyntheticPage.window(page, y: 250, height: h), dy: 250)
    _ = st2.cropTail(100)
    _ = st2.append(contentFrame: SyntheticPage.window(page, y: 400, height: h), dy: 250)
    let expect2 = SyntheticPage.window(page, y: 0, height: 600 + 400)
    if let cg2 = st2.finalize(), let got2 = PixelBuffer(cgImage: cg2) {
        T.checkTrue("stitcher: 下上下上下端到端仍正確",
                    zip(got2.bytes, expect2.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    } else { T.checkTrue("stitcher: finalize 2", false) }

    // 上限＋額度退還：max=1300，600+300=900 → append 500 拒；裁 200 後 append 500 收（1200≤1300）
    var st3 = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 1300)
    st3.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h))
    _ = st3.append(contentFrame: SyntheticPage.window(page, y: 300, height: h), dy: 300)
    T.checkTrue("stitcher: 超上限拒收", !st3.append(contentFrame: SyntheticPage.window(page, y: 800, height: h), dy: 500))
    _ = st3.cropTail(200)
    T.checkTrue("stitcher: 裁尾退還額度後可續拼",
                st3.append(contentFrame: SyntheticPage.window(page, y: 600, height: h), dy: 500))

    // 底帶回裁＋finalize 補回：帶 bottom=50 的影格流
    var f0 = SyntheticPage.window(page, y: 0, height: h)
    SyntheticPage.stamp(&f0, bottom: 50, seed: 88)
    var st4 = ScrollStitcher(firstFrame: f0, maxHeightPx: 30000)
    st4.lockBands(BandInsets(bottom: 50), bottomBandFrom: f0)
    T.checkEq("stitcher: 鎖帶後 base 高 550", st4.height, 550)
    // 內容影格（已扣 bottom）
    let cf = SyntheticPage.window(page, y: 200, height: h - 50)
    _ = st4.append(contentFrame: cf, dy: 200)
    if let cg4 = st4.finalize(), let got4 = PixelBuffer(cgImage: cg4) {
        T.checkEq("stitcher: finalize 高 = 550+200+50", got4.height, 800)
        // 最底 50 列 == 鎖定影格的底帶
        let bandGot = got4.cropped(x: 0, y: 750, width: 400, height: 50)
        let bandWant = f0.cropped(x: 0, y: 550, width: 400, height: 50)
        T.checkTrue("stitcher: 底帶補回在最底端",
                    zip(bandGot.bytes, bandWant.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    } else { T.checkTrue("stitcher: finalize 4", false) }

    // referenceTail
    T.checkEq("stitcher: referenceTail 高度", st.referenceTail(maxHeight: 600).height, 600)

    // lockBands 契約組（審查 I1/I2/M4——契約做成可測拒絕）
    var stc = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 30000)
    _ = stc.append(contentFrame: SyntheticPage.window(page, y: 300, height: h), dy: 300)
    let hBefore = stc.height
    T.checkTrue("stitcher: 先拼後鎖 → 拒絕", !stc.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h)))
    T.checkEq("stitcher: 拒絕後 buffer 不動", stc.height, hBefore)
    var std = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: 300), maxHeightPx: 30000)
    T.checkTrue("stitcher: 底帶≥高 → 拒絕", !std.lockBands(BandInsets(bottom: 300), bottomBandFrom: SyntheticPage.window(page, y: 0, height: 300)))
    var ste = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 30000)
    let narrow = SyntheticPage.window(page, y: 0, height: h).cropped(x: 0, y: 0, width: 200, height: h)
    T.checkTrue("stitcher: 鎖帶影格寬不符 → 拒絕", !ste.lockBands(.zero, bottomBandFrom: narrow))
    T.checkTrue("stitcher: 合法鎖帶仍成功", ste.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h)))
    // appendedFrameCount 語意（審查 M3）：dy≤0 no-op 不計、超限不計、成功計
    var stf = ScrollStitcher(firstFrame: SyntheticPage.window(page, y: 0, height: h), maxHeightPx: 700)
    stf.lockBands(.zero, bottomBandFrom: SyntheticPage.window(page, y: 0, height: h))
    T.checkEq("stitcher: 初始 frameCount=1", stf.appendedFrameCount, 1)
    _ = stf.append(contentFrame: SyntheticPage.window(page, y: 0, height: h), dy: 0)
    T.checkEq("stitcher: dy=0 no-op 不計", stf.appendedFrameCount, 1)
    _ = stf.append(contentFrame: SyntheticPage.window(page, y: 50, height: h), dy: 50)
    T.checkEq("stitcher: 成功 append 計數", stf.appendedFrameCount, 2)
    T.checkTrue("stitcher: 超限拒收", !stf.append(contentFrame: SyntheticPage.window(page, y: 500, height: h), dy: 500))
    T.checkEq("stitcher: 拒收不計數", stf.appendedFrameCount, 2)
}

func scrollGuidanceTests() {
    var g = ScrollGuidance(selectionHeight: 800)
    T.checkEq("guidance: 正常 → progress", g.frameAccepted(dy: 200, totalPx: 1000), GuidanceMessage.progress(px: 1000))
    T.checkEq("guidance: dy>70% → slowDown", g.frameAccepted(dy: 561, totalPx: 1561), GuidanceMessage.slowDown)
    // 失敗計數：1、2 次靜默，3 次 hardToMatch
    T.checkEq("guidance: 失敗1 靜默", g.frameDropped(), nil as GuidanceMessage?)
    T.checkEq("guidance: 失敗2 靜默", g.frameDropped(), nil as GuidanceMessage?)
    T.checkEq("guidance: 失敗3 → hardToMatch", g.frameDropped(), GuidanceMessage.hardToMatch)
    // 複合訊號：失敗中＋滾輪累計 > 選區高
    T.checkEq("guidance: 複合訊號 gapNotStitched", g.wheelAccumulated(sinceLastAccept: 900), GuidanceMessage.gapNotStitched)
    T.checkEq("guidance: 滾輪累計不足 → nil", g.wheelAccumulated(sinceLastAccept: 700), nil as GuidanceMessage?)
    // 接受格重置失敗計數
    _ = g.frameAccepted(dy: 100, totalPx: 2000)
    T.checkEq("guidance: 接受後失敗計數歸零", g.consecutiveFailures, 0)
    T.checkEq("guidance: 歸零後複合訊號不觸發", g.wheelAccumulated(sinceLastAccept: 900), nil as GuidanceMessage?)
    // 回捲格不計失敗（spec §10 計數器語意）
    _ = g.frameDropped(); _ = g.frameDropped()
    _ = g.frameDroppedBackscroll()
    T.checkEq("guidance: 回捲格不進失敗計數", g.consecutiveFailures, 2)
    T.checkEq("guidance: 回捲訊息", g.frameDroppedBackscroll(), GuidanceMessage.backscrollTrimming)
}


/// 端到端整合測試：模擬真實 30fps 影格序列（含慢捲小位移）跑完整 engine 鏈。
/// 這組是實機「長圖不增長、剛捲就結束」bug 的回歸防線——舊邏輯在此必紅。
func scrollStitchEngineTests() {
    let page = SyntheticPage.make(width: 400, height: 4000, seed: 31)
    let frameH = 420

    // 慢捲：每格只前進 5px（< minDelta=14），滾輪每格 2.5 點。
    // 舊邏輯：每格判失敗 → 10 格收工、長圖不增長。新邏輯：累積過閘後一次接上。
    func runSlowScroll(motionGate: CGFloat) -> (height: Int, failures: Int, appended: Int) {
        let engine = ScrollStitchEngine(maxHeightPx: 30000, motionGatePoints: motionGate)
        var y = 0
        var accum: CGFloat = 0
        for _ in 0..<40 {
            accum += 2.5
            let out = engine.consume(frame: SyntheticPage.window(page, y: y, height: frameH),
                                     wheelAccumulatedPoints: accum, wheelDirection: 1)
            switch out {
            case .appended, .trimmed, .bandsLocked: accum = 0
            default: break
            }
            y += 5
        }
        return (engine.height, engine.consecutiveFailures, engine.appendedFrameCount)
    }
    let slow = runSlowScroll(motionGate: ScrollStitchEngine.defaultMotionGatePoints)
    T.checkTrue("engine: 慢捲 5px/格 長圖有增長（\(slow.height) > \(frameH)）", slow.height > frameH)
    T.checkTrue("engine: 慢捲不累積失敗（failures=\(slow.failures) < 10）", slow.failures < 10)
    T.checkTrue("engine: 慢捲有多次 append（\(slow.appended) 格）", slow.appended >= 3)
    // gate 的作用是省掉「必然失敗」的匹配（30fps 下相鄰格位移常 <minDelta=14），不是拼接正確性的
    // 前提：匹配基準是固定的長圖尾端，位移會累積（5→10→15px）到達標，所以 gate=0 也拼得出來，
    // 只是白跑很多次昂貴的金字塔匹配、且接合點分段不同（故高度不必相同，只需同樣有增長）。
    // 實機的真正瓶頸是「匹配放在主執行緒」——debug build 單格 1.3–1.7 秒，主執行緒被塞爆。
    let noGate = runSlowScroll(motionGate: 0)
    T.checkTrue("engine: gate=0 也能拼出來（\(noGate.height)）", noGate.height > frameH)

    // 正常速度：每格 40px、滾輪 20 點/格。
    let engine = ScrollStitchEngine(maxHeightPx: 30000, motionGatePoints: ScrollStitchEngine.defaultMotionGatePoints)
    var y = 0
    var appendedTotal = 0
    var accum2: CGFloat = 0
    for _ in 0..<16 {
        accum2 += 20
        let out = engine.consume(frame: SyntheticPage.window(page, y: y, height: frameH),
                                 wheelAccumulatedPoints: accum2, wheelDirection: 1)
        if case let .appended(dy, _) = out { appendedTotal += dy; accum2 = 0 }
        if case .bandsLocked = out { accum2 = 0 }
        y += 40
    }
    T.checkTrue("engine: 正常速度累積拼接（拼進 \(appendedTotal)px）", appendedTotal > 500)
    T.checkEq("engine: 正常速度零失敗", engine.consecutiveFailures, 0)

    // 端到端逐像素：拼完的長圖須等於原頁面對應區段。
    if let cg = engine.finalize(), let got = PixelBuffer(cgImage: cg) {
        let expected = SyntheticPage.window(page, y: 0, height: got.height)
        T.checkTrue("engine: 端到端逐像素正確（高 \(got.height)）",
                    zip(got.bytes, expected.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    } else { T.checkTrue("engine: finalize 成功", false) }

    // motion gate 語意：閘未過不得算失敗
    let gated = ScrollStitchEngine(maxHeightPx: 30000)
    _ = gated.consume(frame: SyntheticPage.window(page, y: 0, height: frameH),
                      wheelAccumulatedPoints: 0, wheelDirection: 1)   // base
    let out = gated.consume(frame: SyntheticPage.window(page, y: 3, height: frameH),
                            wheelAccumulatedPoints: 3, wheelDirection: 1)
    T.checkEq("engine: 閘未過回 waitingForMotion", out, ScrollStitchOutcome.waitingForMotion)
    T.checkEq("engine: 閘未過不計失敗", gated.consecutiveFailures, 0)

    // 回捲：先下捲累積再上捲，長圖尾端要縮
    let back = ScrollStitchEngine(maxHeightPx: 30000, motionGatePoints: 10)
    _ = back.consume(frame: SyntheticPage.window(page, y: 0, height: frameH),
                     wheelAccumulatedPoints: 0, wheelDirection: 1)
    _ = back.consume(frame: SyntheticPage.window(page, y: 60, height: frameH),
                     wheelAccumulatedPoints: 30, wheelDirection: 1)    // 鎖帶
    _ = back.consume(frame: SyntheticPage.window(page, y: 120, height: frameH),
                     wheelAccumulatedPoints: 30, wheelDirection: 1)    // append
    let hBefore = back.height
    let backOut = back.consume(frame: SyntheticPage.window(page, y: 60, height: frameH),
                               wheelAccumulatedPoints: 30, wheelDirection: -1)
    if case let .trimmed(amount, _) = backOut {
        T.checkTrue("engine: 回捲裁尾 \(amount)px、高度變小", back.height < hBefore)
    } else {
        T.checkTrue("engine: 回捲應回 trimmed（實得 \(backOut)）", false)
    }
}

/// 稀疏內容回歸：實機在深色終端機上「長圖幾乎不增長」的重現。
/// 選區大半是均勻背景（終端機空白區），只有小部分有文字紋理。
func sparseContentTests() {
    let w = 400, pageH = 4000, frameH = 420
    // 造一頁：只有每個視窗的下方 25% 有紋理，其餘為均勻深色（模擬終端機空白區）
    var bytes = [UInt8](repeating: 0, count: w * pageH * 4)
    for i in 0..<(w * pageH) {           // 均勻深色底 (28,28,30)
        bytes[i*4] = 28; bytes[i*4+1] = 28; bytes[i*4+2] = 30; bytes[i*4+3] = 255
    }
    var rng = SyntheticPage.LCG(seed: 77)
    var y = 0
    while y < pageH {
        // 每 4 段中只有 1 段有文字（＝約 25% 有紋理）
        if (y / 100) % 4 == 3 {
            for line in stride(from: y, to: min(y + 100, pageH), by: 18) {
                var x = 10 + rng.int(30)
                while x < w - 30 {
                    let bw = 25 + rng.int(90)
                    let g = UInt8(170 + rng.int(80))
                    for r in line..<min(line + 11, pageH) {
                        for c in x..<min(x + bw, w) {
                            let o = (r * w + c) * 4
                            bytes[o] = g; bytes[o+1] = g; bytes[o+2] = g
                        }
                    }
                    x += bw + 8 + rng.int(18)
                }
            }
        }
        y += 100
    }
    let page = PixelBuffer(width: w, height: pageH, bytes: bytes)

    let engine = ScrollStitchEngine(maxHeightPx: 30000)
    var pos = 0
    var accum: CGFloat = 0
    var appends = 0
    for _ in 0..<24 {
        accum += 20
        let out = engine.consume(frame: SyntheticPage.window(page, y: pos, height: frameH),
                                 wheelAccumulatedPoints: accum, wheelDirection: 1)
        switch out {
        case .appended: appends += 1; accum = 0
        case .bandsLocked, .trimmed: accum = 0
        default: break
        }
        pos += 40
    }
    T.checkTrue("sparse: 稀疏內容仍能拼接（appends=\(appends), 高=\(engine.height)）", appends >= 8)
    T.checkTrue("sparse: 稀疏內容長圖有增長（\(engine.height) > \(frameH)）", engine.height > frameH + 300)
}

/// 滾輪符號無關性回歸：內容確實往下捲，但呼叫端給了**相反**的方向提示
/// （AppKit scrollingDeltaY 正負會隨裝置／自然捲動設定翻轉）。
/// 修正前：matcher 只搜反向 → 零拼接（實機症狀：長圖＝單張影格 1476x517）。
func wheelSignIndependenceTests() {
    let page = SyntheticPage.make(width: 400, height: 3000, seed: 53)
    let frameH = 420
    func run(direction: Int) -> (appends: Int, height: Int) {
        let engine = ScrollStitchEngine(maxHeightPx: 30000)
        var pos = 0, appends = 0
        var accum: CGFloat = 0
        for _ in 0..<16 {
            accum += 20
            let out = engine.consume(frame: SyntheticPage.window(page, y: pos, height: frameH),
                                     wheelAccumulatedPoints: accum, wheelDirection: direction)
            switch out {
            case .appended: appends += 1; accum = 0
            case .bandsLocked, .trimmed: accum = 0
            default: break
            }
            pos += 40
        }
        return (appends, engine.height)
    }
    let correct = run(direction: 1)
    let inverted = run(direction: -1)
    T.checkTrue("wheelsign: 方向提示正確時可拼接（appends=\(correct.appends)）", correct.appends >= 8)
    T.checkTrue("wheelsign: 方向提示相反時仍可拼接（appends=\(inverted.appends), 高=\(inverted.height)）",
                inverted.appends >= 8)
    T.checkEq("wheelsign: 兩種方向提示得到相同長圖高（符號無關）", inverted.height, correct.height)
}

/// 快捲（超過可匹配範圍）與其復原：實機在終端機甩一下就跳數百 px 的情境。
/// maxDy = 選區高 − max(96, 高×16%)；超過就沒有重疊帶，匹配必然失敗。
/// 關鍵行為要求：失敗**不可**很快就自動收工（spec 原訂「連續 10 格失敗」在 30fps 下只有 1/3 秒），
/// 且回到可匹配的步幅後必須能續拼（匹配基準是固定的長圖尾端，故天然可復原）。
func fastScrollRecoveryTests() {
    let page = SyntheticPage.make(width: 400, height: 6000, seed: 61)
    let frameH = 420
    let engine = ScrollStitchEngine(maxHeightPx: 30000)
    var pos = 0
    var accum: CGFloat = 0
    // 先正常拼幾格（建立 base＋鎖帶）
    for _ in 0..<6 {
        accum += 20
        let out = engine.consume(frame: SyntheticPage.window(page, y: pos, height: frameH),
                                 wheelAccumulatedPoints: accum, wheelDirection: 1)
        if case .appended = out { accum = 0 }
        if case .bandsLocked = out { accum = 0 }
        pos += 40
    }
    let heightBeforeBurst = engine.height
    T.checkTrue("fastscroll: 前置正常拼接成立（高=\(heightBeforeBurst)）", heightBeforeBurst > frameH)

    // 快捲：每次跳 600px（> maxDy=420−96=324）→ 無重疊，必然失敗
    var rejects = 0
    for _ in 0..<8 {
        pos += 600                        // 先跳再擷：確保每一格都超出可匹配範圍
        accum += 300
        let out = engine.consume(frame: SyntheticPage.window(page, y: pos, height: frameH),
                                 wheelAccumulatedPoints: accum, wheelDirection: 1)
        if case .rejected = out { rejects += 1 }
    }
    T.checkTrue("fastscroll: 快捲確實造成匹配失敗（rejects=\(rejects)）", rejects >= 5)
    T.checkEq("fastscroll: 失敗期間長圖不被破壞", engine.height, heightBeforeBurst)

    // 復原：使用者回捲到斷點附近（長圖尾端仍是舊內容），再以正常步幅前進
    pos = heightBeforeBurst - frameH + 40      // 回到與長圖尾端有重疊的位置
    var recovered = 0
    for _ in 0..<8 {
        accum += 20
        let out = engine.consume(frame: SyntheticPage.window(page, y: pos, height: frameH),
                                 wheelAccumulatedPoints: accum, wheelDirection: 1)
        if case .appended = out { recovered += 1; accum = 0 }
        pos += 40
    }
    T.checkTrue("fastscroll: 回到可匹配步幅後能續拼（recovered=\(recovered), 高=\(engine.height)）",
                recovered >= 4)
}
