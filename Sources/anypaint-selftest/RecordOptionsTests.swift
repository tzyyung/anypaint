import Foundation
import AnypaintKit
import ScreenCaptureKit
import CoreMedia

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

nonisolated func makeStreamConfigurationTests() {
    let c = RecordFrameSource.makeStreamConfiguration(
        sourceRect: CGRect(x: 10, y: 20, width: 100, height: 50),
        pixelWidth: 200, pixelHeight: 100,
        options: RecordOptions(showsCursor: true, useHEVC: false))
    T.checkEq("config.sourceRect", c.sourceRect, CGRect(x: 10, y: 20, width: 100, height: 50))
    T.checkEq("config.width", Int(c.width), 200)
    T.checkEq("config.height", Int(c.height), 100)
    T.checkEq("config.fps=30", c.minimumFrameInterval, CMTime(value: 1, timescale: 30))
    T.checkEq("config.queueDepth=6", c.queueDepth, 6)
    T.checkTrue("config.showsCursor 跟 options", c.showsCursor)
    T.checkTrue("config 預設不錄音", !c.capturesAudio)
    T.checkEq("config.pixelFormat=BGRA", c.pixelFormat, kCVPixelFormatType_32BGRA)
    T.checkEq("config.colorSpace=sRGB", c.colorSpaceName, CGColorSpace.sRGB)

    let a = RecordFrameSource.makeStreamConfiguration(
        sourceRect: .zero, pixelWidth: 8, pixelHeight: 8,
        options: RecordOptions(showsCursor: false, useHEVC: false,
                               captureSystemAudio: true, captureMicrophone: true))
    T.checkTrue("config: 系統聲開", a.capturesAudio)
    T.checkTrue("config: 排除自家音效", a.excludesCurrentProcessAudio)
    T.checkTrue("config: 麥克風開", a.captureMicrophone)
    T.checkTrue("config: 預設仍全關", !c.capturesAudio && !c.captureMicrophone)
}
