import Foundation
import AnypaintKit

func recordOptionsTests() {
    UserDefaults.standard.set(false, forKey: "recordShowsCursor")
    UserDefaults.standard.set(true, forKey: "recordUseHEVC")
    let o = RecordOptions.fromSettings()
    T.checkEq("options.fromSettings 讀 cursor", o.showsCursor, false)
    T.checkEq("options.fromSettings 讀 HEVC", o.useHEVC, true)
    UserDefaults.standard.removeObject(forKey: "recordShowsCursor")
    UserDefaults.standard.removeObject(forKey: "recordUseHEVC")
    T.checkEq("options.selfCheck 固定配方", RecordOptions.selfCheck,
              RecordOptions(showsCursor: false, useHEVC: false))
}
