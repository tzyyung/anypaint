import AVFoundation
import CoreAudio
import CoreMedia

/// 錄影期間把 HAL 麥克風 PCM 包成 `CMSampleBuffer`，餵進既有 mic `AVAssetWriterInput`。
/// 取代原本 SCK `.microphone` 來源（那條在本 app 收不到封包，見 `AudioInputTap` 註解）。
///
/// **一律降混成單聲道**（robustness 審查 finding #1/#3）：不論裝置是幾聲道、交錯或非交錯（planar），
/// 都把所有聲道平均成 mono 再寫入。這樣（a）mic AAC 軌固定 1 聲道，**永遠不需要 `AVChannelLayoutKey`**
/// ——避免 >2 聲道裝置（專業音效介面／aggregate）建 `AVAssetWriterInput` 時因缺 layout 而
/// `writer.add` 丟不可攔的 ObjC 例外整個 app 崩；（b）planar 多 buffer 也能正確處理，不會只讀第一個
/// buffer 當交錯而錄成垃圾。mic 收人聲，單聲道語意上足夠。
public final class RecordMicSource {

    private let tap: AudioInputTap?

    /// `deviceID` nil／空＝系統預設輸入。建構即開 HAL tap（查裝置格式），IOProc 由 `start` 才啟動。
    public init(deviceID: String?) {
        self.tap = AudioInputTap(deviceUID: (deviceID?.isEmpty == true) ? nil : deviceID)
    }

    /// 啟動麥克風 IOProc：每個封包降混成 mono → 包成單聲道 `CMSampleBuffer` → 派進 `sampleQueue` 交給
    /// `box.appendAudio`。回 false＝沒有可用裝置或啟動失敗（錄影仍可繼續、只是 mic 軌為空）。
    /// `box` 是 `@unchecked Sendable`，可安全跨佇列傳遞；降混與 CMSampleBuffer 建立在 IOProc 執行緒上
    /// **同步**完成（buffer 只在 callback 內有效），只把成品（`SendableBox`）帶進 `sampleQueue`。
    public func start(deliveringTo box: WriterBox, on sampleQueue: DispatchQueue) -> Bool {
        guard let tap else { return false }
        return tap.start { bufferList, hostTime, asbd in
            guard let mono = Self.downmixToMonoFloat32(bufferList, asbd: asbd) else { return }
            let sb: CMSampleBuffer? = mono.withUnsafeBytes { raw in
                Self.makeSampleBuffer(fromInterleavedFloat32: raw, frames: mono.count,
                                      channels: 1, sampleRate: asbd.mSampleRate, hostTime: hostTime)
            }
            guard let sb else { return }
            let boxed = SendableBox(sb)
            sampleQueue.async { box.appendAudio(boxed.value, type: .microphone) }
        }
    }

    public func stop() { tap?.stop() }

    /// 把 HAL 輸入 buffer list 降混成單聲道 Float32。支援交錯（單 buffer、N 聲道）與非交錯（planar，
    /// 每聲道一個 buffer）。只認 Float32（HAL 虛擬格式慣例）；非 Float32 或空回 nil。
    public static func downmixToMonoFloat32(_ list: UnsafePointer<AudioBufferList>,
                                            asbd: AudioStreamBasicDescription) -> [Float]? {
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if nonInterleaved {
            // planar：每個 buffer 是一個聲道、同樣的 frame 數；逐 frame 跨 buffer 平均。
            let buffers = Array(abl).filter { $0.mData != nil }
            guard let first = buffers.first else { return nil }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return nil }
            var mono = [Float](repeating: 0, count: frames)
            var used = 0
            for b in buffers {
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                guard n >= frames, let d = b.mData else { continue }
                let p = d.bindMemory(to: Float.self, capacity: n)
                for f in 0..<frames { mono[f] += p[f] }
                used += 1
            }
            guard used > 0 else { return nil }
            if used > 1 { let inv = 1 / Float(used); for f in 0..<frames { mono[f] *= inv } }
            return mono
        } else {
            // 交錯：單 buffer、N 聲道（用 buffer 自報的 mNumberChannels，最準）；逐 frame 平均 N 聲道。
            guard let buf = abl.first, let data = buf.mData else { return nil }
            let ch = max(1, Int(buf.mNumberChannels))
            let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / ch
            guard frames > 0 else { return nil }
            let p = data.bindMemory(to: Float.self, capacity: total)
            var mono = [Float](repeating: 0, count: frames)
            if ch == 1 {
                for f in 0..<frames { mono[f] = p[f] }
            } else {
                let inv = 1 / Float(ch)
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<ch { s += p[f * ch + c] }
                    mono[f] = s * inv
                }
            }
            return mono
        }
    }

    /// 把 `CMSampleBuffer`（非 Sendable）安全帶過佇列邊界：建立在 IOProc 執行緒、消費在 sampleQueue，
    /// 中間沒有共享可變狀態（同 `WriterBox` 的 `@unchecked Sendable` 成立條件）。
    private final class SendableBox: @unchecked Sendable {
        let value: CMSampleBuffer
        init(_ value: CMSampleBuffer) { self.value = value }
    }

    /// 交錯 Float32 PCM → `CMSampleBuffer`（LPCM）。PTS 用 host-time 時鐘，與 SCK 影片同一時間軸
    /// （`CMClockMakeHostTimeFromSystemUnits`）。失敗回 nil（呼叫端跳過這個 buffer）。
    /// **只支援交錯**——內建麥克風（單聲道）與一般交錯多聲道皆可；非交錯（deinterleaved）來源
    /// 不在此支援範圍（本專案用不到，如日後要支援再擴充）。
    public static func makeSampleBuffer(fromInterleavedFloat32 bytes: UnsafeRawBufferPointer,
                                        frames: Int, channels: Int, sampleRate: Double,
                                        hostTime: UInt64) -> CMSampleBuffer? {
        guard frames > 0, channels > 0, let base = bytes.baseAddress else { return nil }
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let dataLen = frames * bytesPerFrame

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: dataLen, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: dataLen, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer,
              CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: dataLen) == noErr else { return nil }

        let pts = CMClockMakeHostTimeFromSystemUnits(hostTime)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame

        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: formatDesc, sampleCount: frames,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
