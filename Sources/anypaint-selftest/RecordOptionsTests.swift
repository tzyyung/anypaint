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

    // 清鍵後 fromSettings() 的音訊兩鍵預設：系統聲 true、麥克風 false。
    UserDefaults.standard.removeObject(forKey: "recordSystemAudio")
    UserDefaults.standard.removeObject(forKey: "recordMicrophone")
    let defaults = RecordOptions.fromSettings()
    T.checkEq("options.fromSettings 系統聲預設開", defaults.captureSystemAudio, true)
    T.checkEq("options.fromSettings 麥克風預設關", defaults.captureMicrophone, false)

    // 設鍵後 fromSettings() 跟著變。
    UserDefaults.standard.set(false, forKey: "recordSystemAudio")
    UserDefaults.standard.set(true, forKey: "recordMicrophone")
    let toggled = RecordOptions.fromSettings()
    T.checkEq("options.fromSettings 系統聲跟著設定變", toggled.captureSystemAudio, false)
    T.checkEq("options.fromSettings 麥克風跟著設定變", toggled.captureMicrophone, true)
    UserDefaults.standard.removeObject(forKey: "recordSystemAudio")
    UserDefaults.standard.removeObject(forKey: "recordMicrophone")

    // 清鍵後 recordMicrophoneDeviceID 預設 nil。
    UserDefaults.standard.removeObject(forKey: "recordMicrophoneDeviceID")
    let noDevice = RecordOptions.fromSettings()
    T.checkTrue("options.fromSettings 麥克風 deviceID 預設 nil", noDevice.microphoneDeviceID == nil)

    // 設鍵後 fromSettings() 跟著變。
    UserDefaults.standard.set("my-device-id", forKey: "recordMicrophoneDeviceID")
    let withDevice = RecordOptions.fromSettings()
    T.checkEq("options.fromSettings 麥克風 deviceID 跟著設定變", withDevice.microphoneDeviceID, "my-device-id")
    UserDefaults.standard.removeObject(forKey: "recordMicrophoneDeviceID")
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

    let withDeviceID = RecordFrameSource.makeStreamConfiguration(
        sourceRect: .zero, pixelWidth: 8, pixelHeight: 8,
        options: RecordOptions(showsCursor: false, useHEVC: false,
                               captureMicrophone: true, microphoneDeviceID: "test-device-id"))
    T.checkEq("config: 麥克風 deviceID 設定", withDeviceID.microphoneCaptureDeviceID, "test-device-id")

    let noDeviceID = RecordFrameSource.makeStreamConfiguration(
        sourceRect: .zero, pixelWidth: 8, pixelHeight: 8,
        options: RecordOptions(showsCursor: false, useHEVC: false, captureMicrophone: true))
    T.checkEq("config: 麥克風 deviceID 未設定為 nil", noDeviceID.microphoneCaptureDeviceID, nil)
}
