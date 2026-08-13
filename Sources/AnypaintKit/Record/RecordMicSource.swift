import AVFoundation
import CoreAudio
import CoreMedia

/// 錄影期間把 HAL 麥克風 PCM 包成 `CMSampleBuffer`，餵進既有 mic `AVAssetWriterInput`。
/// 取代原本 SCK `.microphone` 來源（那條在本 app 收不到封包，見 `AudioInputTap` 註解）。
/// tap 生命週期在 Task 6 補上；本檔核心是可純測的 `makeSampleBuffer`。
public final class RecordMicSource {

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
