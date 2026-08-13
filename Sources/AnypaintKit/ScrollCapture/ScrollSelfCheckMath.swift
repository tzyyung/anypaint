import CoreGraphics

/// 滾動截圖自檢的純計算（CLI 參數解析、拼接量判準）——與 AppKit/計時器無關,selftest 可測。
public enum ScrollSelfCheckMath {

    /// 解析 `--prefix=<double>` 形式的命令列參數;找不到或非數字回 nil（呼叫端套預設）。
    public static func parseDouble(_ args: [String], prefix: String) -> Double? {
        for a in args where a.hasPrefix(prefix) {
            if let v = Double(a.dropFirst(prefix.count)) { return v }
        }
        return nil
    }

    /// 拼接量判準（不只「有增長」）：預期高≈基準格高 + 總步數×每步位移×scale;
    /// 達成率＝實得/預期,通過條件＝appended>1 且 0.9≤ratio≤1.1（上下都卡:拼太多也算失敗）。
    public static func verdict(firstFrameHeight: Int, totalSteps: Int, stepPoints: CGFloat, scale: CGFloat,
                               actualHeight: Int, appendedFrameCount: Int)
        -> (expected: Int, ratio: Double, pass: Bool) {
        let expected = Double(firstFrameHeight) + Double(totalSteps) * Double(stepPoints) * Double(scale)
        let actual = Double(actualHeight)
        let ratio = expected > 0 ? actual / expected : 0
        let pass = appendedFrameCount > 1 && ratio >= 0.9 && ratio <= 1.1
        return (Int(expected), ratio, pass)
    }
}
