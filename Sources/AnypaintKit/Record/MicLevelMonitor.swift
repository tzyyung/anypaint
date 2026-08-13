import AVFoundation
import CoreAudio
import Foundation

/// 待命試音錶：對指定 uniqueID 的音訊輸入裝置即時算線性 RMS（0..1），供設定頁
/// `LevelMeterView` 與 RPC `micLevel` 使用。改走 CoreAudio HAL（`AudioInputTap`）——AVFoundation
/// capture 路（AVCaptureSession/SCK `.microphone`）在本 app 收不到麥克風封包，HAL 這條穩定拿得到，
/// 見 `AudioInputTap` 註解與設計文件 §0。
///
/// **不在這裡要求麥克風權限**：本 app 既有的權限請求走 `CaptureSettingsViewController` 勾選
/// 「錄製麥克風」核取方塊那條路（`AVCaptureDevice.requestAccess`），試音錶只消費既有授權狀態
/// （用 `AVCaptureDevice.authorizationStatus` 查，不重複觸發系統對話框；查授權不等於用 AVCapture 擷取）。
@MainActor
public final class MicLevelMonitor: NSObject {
    /// 節流後的線性 RMS（0..1）回呼，~20Hz。
    public var onLevel: ((Float) -> Void)?
    /// 最新一次算出的線性 RMS（0..1）；不節流，供 RPC `micLevel` 之類輪詢式呼叫端隨時讀到最新值。
    public private(set) var latestLevel: Float = 0

    private var tap: AudioInputTap?
    /// session 世代號：每次 `start()`／`stop()` 遞增。`handleLevel` 只接受與當下相符的世代，
    /// 擋掉 `stop()` 後仍在飛的遲到回呼把 `latestLevel` 蓋回舊值（原 AVCapture 版 fix round 1 的守衛，
    /// HAL 版一樣需要——IOProc callback 也可能在 stop 後排進的 Task 遲到執行）。
    private var generation = 0
    private let throttleInterval: TimeInterval = 0.05   // 20Hz（在 ioQueue 端節流）

    public override init() { super.init() }
    deinit { tap?.stop() }

    /// nil／空字串＝系統預設輸入。未授權／無裝置／啟動失敗 → 靜默不啟動（`latestLevel` 停 0、
    /// `onLevel` 不呼叫、不 crash）。換裝置的唯一入口：先 `stop()` 再開，不疊兩條 tap。
    public func start(deviceID: String?) {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard let newTap = AudioInputTap(deviceUID: (deviceID?.isEmpty == true) ? nil : deviceID) else { return }
        generation += 1
        let gen = generation
        latestLevel = 0
        // 節流搬到 realtime/ioQueue 端：IOProc callback ~90–190/s，若每次都 spawn 一個 MainActor Task
        // 是 realtime 執行緒上的持續堆積配置（違反「callback 內只做最小事」，robustness 審查 finding #5）。
        // `lastHop` 只在 tap 的 serial ioQueue 上讀寫（callback 天然序列化），無需額外同步。只有超過
        // 節流間隔才算 RMS、才跳 MainActor。RPC 輪詢頻率遠低於 20Hz，`latestLevel` 這樣更新已足夠即時。
        var lastHop = 0.0
        let interval = throttleInterval
        let ok = newTap.start { [weak self] bufferList, _, asbd in
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastHop >= interval else { return }
            lastHop = now
            let rms = Self.rms(fromInputBufferList: bufferList, asbd: asbd)
            Task { @MainActor [weak self] in self?.handleLevel(rms, generation: gen) }
        }
        guard ok else { return }
        tap = newTap
    }

    public func stop() {
        generation += 1
        tap?.stop()
        tap = nil
        latestLevel = 0
    }

    /// 更新 `latestLevel`＋呼叫 `onLevel`（節流已在 ioQueue 端做，這裡不再重複）。
    /// 世代不符＝舊 session 的遲到結果，整個丟棄（`stop()`／換裝置後仍在飛的 Task 不會蓋回舊值）。
    private func handleLevel(_ rms: Float, generation: Int) {
        guard generation == self.generation else { return }
        latestLevel = rms
        onLevel?(rms)
    }

    /// 從 HAL 輸入 buffer list 算線性 RMS。只認 Float32（HAL 虛擬格式慣例）；非 Float32 回 0。
    /// 走遍所有 buffer（非交錯多聲道會是多個 buffer），全部樣本當一串算整體 RMS（同 `RecordMath.rms`
    /// 的精神，這裡直接吃 buffer list 免去複製）。
    nonisolated static func rms(fromInputBufferList list: UnsafePointer<AudioBufferList>,
                                asbd: AudioStreamBasicDescription) -> Float {
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var sum = 0.0
        var count = 0
        for buf in abl {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { sum += Double(p[i]) * Double(p[i]) }
            count += n
        }
        guard count > 0 else { return 0 }
        return Float((sum / Double(count)).squareRoot())
    }
}
