import AVFoundation
import CoreAudio
import CoreMedia

/// 錄影期間把 HAL 麥克風 PCM 包成 `CMSampleBuffer`，餵進既有 mic `AVAssetWriterInput`。
/// 取代原本 SCK `.microphone` 來源（那條在本 app 收不到封包，見 `AudioInputTap` 註解）。
/// tap 生命週期在 Task 6 補上；本檔核心是可純測的 `makeSampleBuffer`。
public final class RecordMicSource {

    private let tap: AudioInputTap?

    /// `deviceID` nil／空＝系統預設輸入。建構即開 HAL tap（查裝置格式），IOProc 由 `start` 才啟動。
    public init(deviceID: String?) {
        self.tap = AudioInputTap(deviceUID: (deviceID?.isEmpty == true) ? nil : deviceID)
    }

    /// 開 tap 後的裝置聲道數（用來設 mic `AVAssetWriterInput` 的聲道數）。tap 開不成回 0。
    public var channels: Int { tap.map { Int($0.format.mChannelsPerFrame) } ?? 0 }

    /// 啟動麥克風 IOProc，把每個封包包成 `CMSampleBuffer` 後派進 `sampleQueue` 交給 `box.appendAudio`。
    /// 回 false＝沒有可用裝置或啟動失敗（錄影仍可繼續、只是 mic 軌為空）。
    /// `box` 是 `@unchecked Sendable`，可安全跨佇列傳遞；PCM→CMSampleBuffer 的建立在 IOProc 執行緒
    /// 上做，只把成品（包成 `SendableBox`）帶進 `sampleQueue`。
    /// **假設交錯單一 buffer**（內建麥克風＝1 buffer 交錯）；非交錯多聲道不支援，見 builder 註解。
    public func start(deliveringTo box: WriterBox, on sampleQueue: DispatchQueue) -> Bool {
        guard let tap else { return false }
        return tap.start { bufferList, hostTime, asbd in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let buf = abl.first, let data = buf.mData else { return }
            let channels = Int(asbd.mChannelsPerFrame)
            let bytesPerFrame = channels * MemoryLayout<Float>.size
            guard bytesPerFrame > 0 else { return }
            let frames = Int(buf.mDataByteSize) / bytesPerFrame
            let raw = UnsafeRawBufferPointer(start: data, count: Int(buf.mDataByteSize))
            guard let sb = Self.makeSampleBuffer(fromInterleavedFloat32: raw, frames: frames,
                    channels: channels, sampleRate: asbd.mSampleRate, hostTime: hostTime) else { return }
            let boxed = SendableBox(sb)
            sampleQueue.async { box.appendAudio(boxed.value, type: .microphone) }
        }
    }

    public func stop() { tap?.stop() }

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
