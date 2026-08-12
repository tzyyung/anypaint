import Foundation
import AnypaintKit
import AVFoundation

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
