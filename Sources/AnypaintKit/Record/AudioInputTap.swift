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
    /// HAL 拆卸專用**單一 serial** 佇列（所有 tap 共用）：`AudioDeviceStop`/`Destroy` 是會卡在 HAL
    /// 行程級鎖上的同步 IPC，用 `.global()` 併發派工在 start/stop 風暴下會每個 block 各佔一條 worker
    /// thread、短暫爆執行緒（robustness 審查第三輪 finding #3）。serial 佇列與 HAL 自身序列化相符、
    /// 封頂一條執行緒，又仍然不阻塞呼叫端。
    private static let teardownQueue = DispatchQueue(label: "anypaint.audioinputtap.teardown")

    /// `deviceUID` nil ＝ 系統預設輸入。裝置不存在／查不到格式 → 回 nil（呼叫端靜默降級）。
    init?(deviceUID: String?) {
        guard let dev = Self.resolveDevice(uid: deviceUID), dev != kAudioObjectUnknown else { return nil }
        guard let fmt = Self.inputFormat(device: dev) else { return nil }
        self.deviceID = dev
        self.format = fmt
    }

    deinit { stop() }

    /// 開 IOProc + AudioDeviceStart。回 false＝失敗（裝置忙等），不 crash、不丟例外。
    ///
    /// callback 由 IOProc block **直接捕獲**（不存進共用屬性）——這樣 ioQueue（realtime）與呼叫端
    /// 之間沒有任何共用可變狀態要同步：block 強持有 cb，CoreAudio 持有 block 直到
    /// `AudioDeviceDestroyIOProcID`，cb 的生命週期就綁在 IOProc 上，不需要 `onInput` 屬性、也就沒有
    /// 「一邊讀一邊被 stop() 清 nil」的資料競爭（robustness 審查 finding #2）。
    func start(onInput cb: @escaping (UnsafePointer<AudioBufferList>, UInt64, AudioStreamBasicDescription) -> Void) -> Bool {
        guard !running else { return true }
        let fmt = format
        var pid: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, ioQueue) {
            _, inInputData, inInputTime, _, _ in
            // mHostTime 有效才用；否則以當下 host time 補（避免 PTS 亂跳）。
            let ts = inInputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : mach_absolute_time()
            cb(inInputData, host, fmt)
        }
        guard createStatus == noErr, let pid else { return false }
        procID = pid
        guard AudioDeviceStart(deviceID, pid) == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil; return false
        }
        running = true
        return true
    }

    /// `AudioDeviceStop`／`AudioDeviceDestroyIOProcID` 是對 `coreaudiod` 的**同步**往返（可能數~數十 ms）。
    /// 派到 `teardownQueue`（單一 serial 背景佇列）上做，**不阻塞呼叫端（多半是 MainActor）**。
    ///
    /// **絕不能派到 `ioQueue`**（＝傳給 `AudioDeviceCreateIOProcIDWithBlock` 的 IOProc 遞送佇列）：
    /// HAL 若在 Stop/Destroy 內部對該佇列 `dispatch_sync` 排空 in-flight block，而我們正在那條佇列上，
    /// 就會自我死鎖、teardown 永不完成 → 裝置/IOProcID 洩漏（robustness 審查第二輪 finding #1）。
    /// 也不用 `.global()` 併發佇列——start/stop 風暴下會爆 worker thread（第三輪 finding #3）。
    /// Stop/Destroy 設計上本來就從控制執行緒呼叫、不是從 IOProc 佇列。之所以能安全離開 `ioQueue`：
    /// callback 的釋放已改成由 block 直接捕獲（見 `start`），不再需要「排在 IOProc block 後」當同步柵欄。
    /// 只捕獲 dev/pid（不捕獲 self），`deinit` 呼叫也安全（不會在釋放中復活 self）；pid 到 `Destroy`
    /// 前都有效、GCD 保留 queue 到 block 跑完，即使 tap 先釋放也無 use-after-free。
    func stop() {
        guard running, let pid = procID else { return }
        running = false
        procID = nil
        let dev = deviceID
        Self.teardownQueue.async {
            AudioDeviceStop(dev, pid)
            AudioDeviceDestroyIOProcID(dev, pid)
        }
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
