import Foundation
import AnypaintKit
import AVFoundation
import AppKit

nonisolated func audioInputDeviceTests() {
    let devices = AudioInputDeviceList.all()
    // headless 環境至少不 crash；有硬體時 name 非空、uniqueID 非空
    T.checkTrue("裝置列舉不 crash 且回陣列", devices.count >= 0)
    for d in devices {
        T.checkTrue("裝置 uniqueID 非空", !d.uniqueID.isEmpty)
        T.checkTrue("裝置 name 非空", !d.name.isEmpty)
    }
    // 至多一個 isDefault
    T.checkTrue("至多一個 isDefault", devices.filter(\.isDefault).count <= 1)
    // systemDefaultID 若非 nil 且非聚合裝置，必在清單內。
    // 邊界（見 AudioInputDeviceList 文件註解）：使用者若手動把 Aggregate Device 設成系統
    // 預設輸入，`all()` 會過濾掉它，此時清單裡沒有它是刻意行為，不驗這條斷言。
    if let defDevice = AVCaptureDevice.default(for: .audio) {
        let isAggregate = defDevice.localizedName.contains("CADefaultDeviceAggregate")
        if !isAggregate {
            T.checkTrue("系統預設 ID 在清單內",
                        devices.contains { $0.uniqueID == defDevice.uniqueID })
        }
    }
}

nonisolated func levelMathTests() {
    // dBFS：滿刻度 1.0 → 0 dB；0.001 → 約 -60；0 → clamp 至 -60
    T.checkTrue("dB 滿刻度≈0", abs(RecordMath.dbFromRMS(1.0)) < 0.5)
    T.checkTrue("dB 靜音 clamp -60", RecordMath.dbFromRMS(0) <= -59.9)
    T.checkTrue("dB 單調遞增", RecordMath.dbFromRMS(0.5) > RecordMath.dbFromRMS(0.05))
    // 格數：-60 dB → 0 格；0 dB → 滿格
    T.checkEq("靜音 0 格", RecordMath.levelBars(db: -60, totalBars: 12), 0)
    T.checkEq("滿刻度滿格", RecordMath.levelBars(db: 0, totalBars: 12), 12)
    T.checkTrue("中間值在範圍內", (0...12).contains(RecordMath.levelBars(db: -30, totalBars: 12)))
    // 無訊號判定：噪底量級靜音、人聲量級有訊號（門檻＝噪底數十倍，實作校準）
    T.checkTrue("噪底判為靜音", RecordMath.isSilent(rms: 0.0001))
    T.checkTrue("人聲判為有訊號", !RecordMath.isSilent(rms: 0.05))
}

nonisolated func levelMeterViewTests() {
    let v = LevelMeterView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
    func litPixels(level: Float) -> Int {
        v.level = level
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
        v.cacheDisplay(in: v.bounds, to: rep)
        var lit = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3,
               (c.redComponent + c.greenComponent + c.blueComponent) > 0.5 { lit += 1 }
        } }
        return lit
    }
    let loud = litPixels(level: 0.9)
    let quiet = litPixels(level: 0.0)
    T.checkTrue("有訊號時電平表有亮格", loud > 0)
    T.checkTrue("大訊號比靜音亮格多", loud > quiet)
}
