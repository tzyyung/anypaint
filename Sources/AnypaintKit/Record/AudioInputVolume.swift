import AppKit
import CoreAudio
import Foundation

/// 麥克風**輸入音量**讀寫（CoreAudio `kAudioDevicePropertyVolumeScalar`，輸入 scope）。
/// 這改的是**系統層的裝置輸入增益**（等同系統設定→聲音→輸入的滑桿），錄進去的音量跟著變大/變小。
/// 不是所有裝置都支援可設音量（部分 USB 麥克風/聚合裝置只讀或完全不支援）——查不到就回 nil,呼叫端隱藏滑桿。
public enum AudioInputVolume {

    /// clamp 進 [0,1]（純函式,可測）。
    public static func clamped(_ v: Float) -> Float { max(0, min(1, v)) }

    /// uid→裝置（nil＝系統預設輸入）。
    private static func device(uid: String?) -> AudioObjectID? {
        if let uid, !uid.isEmpty {
            var cf = uid as CFString
            var dev = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let st = withUnsafeMutablePointer(to: &cf) { p -> OSStatus in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
            }
            return (st == noErr && dev != kAudioObjectUnknown) ? dev : nil
        } else {
            var dev = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
            return (st == noErr && dev != kAudioObjectUnknown) ? dev : nil
        }
    }

    private static func addr(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }
    private static func scalar(_ dev: AudioObjectID, _ element: AudioObjectPropertyElement) -> Float? {
        var a = addr(element)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    @discardableResult
    private static func setScalar(_ dev: AudioObjectID, _ element: AudioObjectPropertyElement, _ v: Float32) -> Bool {
        var a = addr(element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &a),
              AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var value = v
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    /// 目前輸入音量（0..1）；先試 master(0),再試聲道 1;都讀不到＝裝置不支援,回 nil。
    public static func volume(deviceUID: String?) -> Float? {
        guard let dev = device(uid: deviceUID) else { return nil }
        return scalar(dev, 0) ?? scalar(dev, 1)
    }

    /// 設輸入音量（clamp 0..1）；先試 master,不可設就設聲道 1/2（L/R）。回是否至少設成一個。
    @discardableResult
    public static func setVolume(deviceUID: String?, _ volume: Float) -> Bool {
        guard let dev = device(uid: deviceUID) else { return false }
        let v = clamped(volume)
        if setScalar(dev, 0, v) { return true }
        let l = setScalar(dev, 1, v)
        let r = setScalar(dev, 2, v)
        return l || r
    }

    /// 開啟系統設定→聲音（輸入）。macOS 13+ 用新 URL,失敗退回舊 pane id。
    public static func openSoundSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Sound-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.sound"]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}
