import Foundation

/// 四向靜態帶偵測（spec §7.2）。輸入兩張已確認捲動 dy>0 的 luma 影格。
/// 封頂：頂/底 ≤ min(H/5, 160)、左/右 ≤ min(W/6, 120)——結構性保證靜態帶吃不掉搜尋主體，
/// 也讓「整張純色頁」不可能被誤判成全靜態（Snapzy 同款防線）。
public enum StaticBandDetector {
    static let rowDiffThreshold: Float = 3.0   // 未位移列均差低於此 = 靜態列（luma 0-255 尺度）
    static let colDiffThreshold: Float = 3.0

    public static func detect(frameA: LumaPlane, frameB: LumaPlane, dy: Int) -> BandInsets? {
        guard dy > 0, frameA.width == frameB.width, frameA.height == frameB.height else { return nil }
        let w = frameA.width, h = frameA.height
        let capTB = min(h / 5, 160), capLR = min(w / 6, 120)

        func rowDiff(_ r: Int) -> Float {
            var s: Float = 0
            for c in 0..<w { s += abs(frameA.v[r * w + c] - frameB.v[r * w + c]) }
            return s / Float(w)
        }
        // 頂帶：從上往下連續「未位移相同」的列
        var top = 0
        while top < capTB, rowDiff(top) < rowDiffThreshold { top += 1 }
        // 底帶：從下往上
        var bottom = 0
        while bottom < capTB, rowDiff(h - 1 - bottom) < rowDiffThreshold { bottom += 1 }

        // 側帶：只看內容列區間（排除頂/底帶），未位移逐欄均差
        let r0 = top, r1 = h - bottom
        guard r1 - r0 > h / 3 else { return nil }   // 內容列太少 → 本格判定不可信
        func colDiff(_ c: Int) -> Float {
            var s: Float = 0
            for r in r0..<r1 { s += abs(frameA.v[r * w + c] - frameB.v[r * w + c]) }
            return s / Float(r1 - r0)
        }
        var left = 0
        while left < capLR, colDiff(left) < colDiffThreshold { left += 1 }
        var right = 0
        while right < capLR, colDiff(w - 1 - right) < colDiffThreshold { right += 1 }

        // 退化守門：四向同時打到封頂＝畫面缺乏可鑑別的捲動內容（純色/全靜態頁），
        // 判定不可信回 nil。真實頁面不會四向全頂——這補上 r1-r0 > h/3 防呆
        // 在「上下皆封頂」時數學不可達的缺口（3h/5 恆 > h/3，實作審查發現）。
        if top >= capTB, bottom >= capTB, left >= capLR, right >= capLR { return nil }

        // 內容區高度防呆（活碼：h=600 且上下帶合計 380 時觸發）。寬度不需對稱防呆——
        // capLR=min(w/6,120) 結構性保證 w−left−right ≥ 2w/3，恆寬於任何合理下限（審查驗證 0 反例）。
        guard (r1 - r0) >= 240 || (r1 - r0) >= h / 2 else { return nil }
        return BandInsets(top: top, bottom: bottom, left: left, right: right)
    }
}
