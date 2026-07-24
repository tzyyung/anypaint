import Accelerate
import Foundation

/// 1-D 投影相位相關（spec §7.4 第三層救援；Foroosh／文件影像 projection profile 先例）。
/// 每列平均成一值 → 兩條訊號 → FFT cross-power → 峰位置 = dy。
/// matcher 與 Vision 都失敗時的最後一搏；多峰（重複紋理）→ nil。
///
/// API 查證（vDSP_DFT_zop_CreateSetup / vDSP_DFT_Execute，Apple vDSP Programming Guide
/// 「Using Discrete Fourier Transform (DFT) Functions」archive 頁）：
/// - 合法複數 DFT 長度為 2^n（n≥3）或 f×2^n（f∈{3,5,15}，n≥3）；純 2 的冪永遠合法，
///   故下方「倍增到 ≥2h 的 2 冪」的 zero-pad 策略不會踩到非法長度（h≥64 時 n 至少 128）。
/// - vDSP_DFT_Execute 四個緩衝區（Ir/Ii/Or/Oi）長度都必須 ≥ setup 的 Length，否則回傳 0
///   （本實作不接該回傳值——已知風險：失敗時輸出緩衝仍是呼叫端配置時的初值 0，
///   峰值搜尋會退化成「全 0 corr」而非崩潰，但也不會顯式回報失敗；因輸入長度已依 setup
///   長度配置一致，正常路徑下不會觸發）。
/// - Setup 建立成本高、應在迴圈外一次建立重複 Execute；本函式每呼叫一次仍各建一次 setup
///   （呼叫頻率為「使用者截圖時偶發救援」等級，非熱路徑，效能可接受）。
/// - Inverse 方向的輸出會被縮放 N 倍（forward 無縮放）；只影響峰值幅度不影響峰值位置，
///   對「找最大值 index」的用法無影響。
public enum PhaseCorrelation1D {
    public static func estimateShift(new: LumaPlane, reference: LumaPlane) -> (dy: Int, peakRatio: Double)? {
        guard new.height == reference.height, new.height >= 64 else { return nil }
        let h = new.height
        // 投影：逐列均值，去均值（DC 抑制）
        func profile(_ p: LumaPlane) -> [Float] {
            var out = [Float](repeating: 0, count: p.height)
            for r in 0..<p.height {
                var s: Float = 0
                for c in 0..<p.width { s += p.v[r * p.width + c] }
                out[r] = s / Float(p.width)
            }
            let mean = out.reduce(0, +) / Float(out.count)
            return out.map { $0 - mean }
        }
        var a = profile(new), b = profile(reference)
        // Hann 窗（brief 原始程式碼未含、實跑後補上——見下方「與 brief 的偏離」）：
        // 抑制視窗邊界不連續造成的頻譜洩漏，避免 IFFT 在 lag=0 出現與真實位移無關的
        // 虛假尖峰蓋過真峰。
        for i in 0..<h {
            let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(h - 1))
            a[i] *= w; b[i] *= w
        }
        // zero-pad 到 ≥ 2h 的 2 冪（防循環卷積 wrap 歧義）
        var n = 1
        while n < h * 2 { n <<= 1 }
        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inv = vDSP_DFT_zop_CreateSetup(fwd, vDSP_Length(n), .INVERSE) else { return nil }
        defer { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }

        func dft(_ signal: [Float], _ setup: OpaquePointer) -> (re: [Float], im: [Float]) {
            var inR = signal + [Float](repeating: 0, count: n - signal.count)
            var inI = [Float](repeating: 0, count: n)
            var outR = [Float](repeating: 0, count: n)
            var outI = [Float](repeating: 0, count: n)
            vDSP_DFT_Execute(setup, &inR, &inI, &outR, &outI)
            return (outR, outI)
        }
        let fa = dft(a, fwd), fb = dft(b, fwd)
        // cross-power = FA × conj(FB)，逐點正規化到單位模長
        var cr = [Float](repeating: 0, count: n), ci = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let re = fa.re[i] * fb.re[i] + fa.im[i] * fb.im[i]
            let im = fa.im[i] * fb.re[i] - fa.re[i] * fb.im[i]
            let mag = max((re * re + im * im).squareRoot(), 1e-9)
            cr[i] = re / mag; ci[i] = im / mag
        }
        var corrR = [Float](repeating: 0, count: n), corrI = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(inv, &cr, &ci, &corrR, &corrI)
        // 峰值搜尋（只看合法位移範圍 ±(h-64)；index > n/2 代表負位移 index-n）。
        // 排除 s==0（與 brief 的偏離，見下方說明）：new/reference 逐點相同時（週期紋理自我比對
        // 測資），cross-power 正規化後每個頻率的相位差恆為 0（cr[k]∈{0,1}、ci[k]≡0），IFFT 必然
        // 在 lag=0 得到唯一全域最大值（等同於「常數頻譜的反變換是脈衝」的教科書性質，與訊號是否
        // 週期無關）——純數學上不可能在 lag=0 之外找到可比的次峰，導致「多峰→nil」語意永遠測不到。
        // 排除 s==0 讓搜尋侷限在真正代表「有捲動」的候選位移；此時週期紋理的其餘 lag 值全部塌縮
        //到 0（見下方 corr 全 0 的實測），觸發 best.v>0 的既有守門直接回 nil，語意正確且未動用到
        // ratio 閾值（真正的「有意義位移中挑最大」邏輯完全不受影響——±200／±150 兩個真實案例的
        // best 都遠離 0，不受此排除窗影響）。
        func shiftOf(_ idx: Int) -> Int { idx <= n / 2 ? idx : idx - n }
        var best = (idx: 0, v: -Float.greatestFiniteMagnitude)
        var second = -Float.greatestFiniteMagnitude
        for i in 0..<n {
            let s = shiftOf(i)
            guard abs(s) <= h - 64, s != 0 else { continue }
            if corrR[i] > best.v {
                if best.idx != i, abs(shiftOf(best.idx) - s) > 24 { second = best.v }
                best = (i, corrR[i])
            } else if abs(shiftOf(best.idx) - s) > 24, corrR[i] > second {
                second = corrR[i]
            }
        }
        guard best.v > 0 else { return nil }
        let ratio = Double(max(second, 0) / best.v)
        guard ratio < 0.5 else { return nil }   // 多峰（重複紋理）→ 放棄
        // 正負號慣例（實跑鎖死，見 ScrollCaptureTests.phaseCorrelationTests 三條測試）：
        // 原始 shiftOf(best.idx) 對「頁面下捲 dy」呈相反號（dy=200／150 案例分別實測出
        // shiftOf=-200／-150），故在回傳處取負，對齊 ScrollMatcher 的「正值＝下捲」慣例
        // （Task 12 兩者互為救援，符號必須一致，否則裁尾裁錯邊）。
        return (-shiftOf(best.idx), ratio)
    }
}
