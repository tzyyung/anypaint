import CoreAudio
import Foundation

/// CoreAudio HAL 輸入封裝：把指定裝置的即時 PCM 透過 IOProc 丟出來。是本專案「從指定裝置
/// 拿麥克風輸入」的唯一出口（電平表 `MicLevelMonitor` 與錄影 `RecordMicSource` 都經它）。
///
/// 為什麼不走 AVCaptureSession/AVCaptureAudioDataOutput 或 SCK `.microphone`：實測（2026-08-13）
/// 那兩條 AVFoundation capture 路在本 app 內對麥克風完全收不到封包（session 正常啟動、無錯、
/// 卻零 buffer），而 HAL 這條在同一 app／簽章／啟動方式下穩定拿得到。詳見設計文件 §0
/// （`docs/superpowers/specs/2026-08-13-mic-hal-capture-design.md`）。
final class AudioInputTap {
    private let deviceID: AudioObjectID
    private(set) var format: AudioStreamBasicDescription
    private var procID: AudioDeviceIOProcID?
    private var running = false
    /// IOProc 派工佇列（HAL 要求一個 serial queue；realtime callback 在此跑）。
    private let ioQueue = DispatchQueue(label: "anypaint.audioinputtap.io")
    /// 強持有 callback，確保 IOProc 存活期間不被釋放。
    private var onInput: ((UnsafePointer<AudioBufferList>, UInt64, AudioStreamBasicDescription) -> Void)?

    /// `deviceUID` nil ＝ 系統預設輸入。裝置不存在／查不到格式 → 回 nil（呼叫端靜默降級）。
    init?(deviceUID: String?) {
        guard let dev = Self.resolveDevice(uid: deviceUID), dev != kAudioObjectUnknown else { return nil }
        guard let fmt = Self.inputFormat(device: dev) else { return nil }
        self.deviceID = dev
        self.format = fmt
    }

    deinit { stop() }

    /// 開 IOProc + AudioDeviceStart。回 false＝失敗（裝置忙等），不 crash、不丟例外。
    func start(onInput: @escaping (UnsafePointer<AudioBufferList>, UInt64, AudioStreamBasicDescription) -> Void) -> Bool {
        guard !running else { return true }
        self.onInput = onInput
        let fmt = format
        var pid: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, let cb = self.onInput else { return }
            // mHostTime 有效才用；否則以當下 host time 補（避免 PTS 亂跳）。
            let ts = inInputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : mach_absolute_time()
            cb(inInputData, host, fmt)
        }
        guard createStatus == noErr, let pid else { self.onInput = nil; return false }
        procID = pid
        guard AudioDeviceStart(deviceID, pid) == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil; self.onInput = nil; return false
        }
        running = true
        return true
    }

    func stop() {
        guard running, let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
        running = false
        onInput = nil
    }

    // MARK: - CoreAudio 查詢（全部先驗過 header，見計畫 Global Constraints）

    /// uid → AudioDeviceID；nil＝系統預設輸入。
    private static func resolveDevice(uid: String?) -> AudioObjectID? {
        if let uid {
            var cf = uid as CFString
            var dev = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let st = withUnsafeMutablePointer(to: &cf) { cfPtr -> OSStatus in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<CFString>.size), cfPtr, &size, &dev)
            }
            return st == noErr ? dev : nil
        } else {
            var dev = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
            return st == noErr ? dev : nil
        }
    }

    /// 裝置輸入 scope 第一條 stream 的 virtual format（ASBD）。查不到回 nil。
    private static func inputFormat(device: AudioObjectID) -> AudioStreamBasicDescription? {
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(device, &streamsAddr, 0, nil, &size, &streams) == noErr,
              let stream = streams.first else { return nil }
        var fmt = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fsize, &fmt) == noErr else { return nil }
        return fmt
    }
}
