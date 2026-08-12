import Foundation
import AnypaintKit

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
    // systemDefaultID 若非 nil，必在清單內
    if let def = AudioInputDeviceList.systemDefaultID() {
        T.checkTrue("系統預設 ID 在清單內", devices.contains { $0.uniqueID == def })
    }
}
