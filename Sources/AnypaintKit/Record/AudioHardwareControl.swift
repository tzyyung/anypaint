import CoreAudio

/// 只給 `RecordAudioSelfCheck` 用：查／設系統預設輸入輸出、以 transport type 解析內建裝置
/// （不硬寫 UID，沿用 BetterCapture 不硬編碼教訓）。自檢時把預設切到內建喇叭↔內建麥克風做
/// 聲學耦合，跑完還原（正式路徑不碰這個型別）。
enum AudioHardwareControl {
    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }
    static func defaultInputDevice() -> AudioObjectID { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutputDevice() -> AudioObjectID { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ dev: AudioObjectID) {
        var d = dev
        var addr = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &d)
    }
    static func setDefaultInput(_ dev: AudioObjectID) { setDefault(kAudioHardwarePropertyDefaultInputDevice, dev) }
    static func setDefaultOutput(_ dev: AudioObjectID) { setDefault(kAudioHardwarePropertyDefaultOutputDevice, dev) }

    static func builtInInputDevice() -> AudioObjectID? { builtIn(scope: kAudioObjectPropertyScopeInput) }
    static func builtInOutputDevice() -> AudioObjectID? { builtIn(scope: kAudioObjectPropertyScopeOutput) }

    /// scope: input=有輸入聲道、output=有輸出聲道；回第一個 transport==builtIn 的裝置。
    private static func builtIn(scope: AudioObjectPropertyScope) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids where transportType(id) == kAudioDeviceTransportTypeBuiltIn && channelCount(id, scope: scope) > 0 {
            return id
        }
        return nil
    }

    private static func transportType(_ dev: AudioObjectID) -> UInt32 {
        var t: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t)
        return t
    }

    private static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size)))
        defer { free(abl.unsafeMutablePointer) }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, abl.unsafeMutablePointer) == noErr else { return 0 }
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
