import AnypaintKit
import CoreMedia

nonisolated func micHALSampleBufferTests() {
    let frames = 480, channels = 1, sr = 48000.0
    let samples = [Float](repeating: 0.25, count: frames * channels)
    let host = mach_absolute_time()
    let sb: CMSampleBuffer? = samples.withUnsafeBytes { raw in
        RecordMicSource.makeSampleBuffer(fromInterleavedFloat32: raw, frames: frames,
                                         channels: channels, sampleRate: sr, hostTime: host)
    }
    guard let sb else { T.checkTrue("micbuf: 建立成功", false); return }
    T.checkTrue("micbuf: 建立成功", true)
    T.checkEq("micbuf: frame 數正確", CMSampleBufferGetNumSamples(sb), frames)
    if let fd = CMSampleBufferGetFormatDescription(sb),
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
        T.checkEq("micbuf: 取樣率 48k", asbd.mSampleRate, 48000)
        T.checkEq("micbuf: 1 聲道", Int(asbd.mChannelsPerFrame), 1)
        T.checkTrue("micbuf: Float32", (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
    } else { T.checkTrue("micbuf: 可讀格式描述", false) }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    T.checkTrue("micbuf: PTS 有效", CMTIME_IS_VALID(pts) && pts.seconds > 0)
    if let bb = CMSampleBufferGetDataBuffer(sb) {
        T.checkEq("micbuf: 資料長度", CMBlockBufferGetDataLength(bb), frames * channels * 4)
        // 樣本值必須原樣保留（不是被歸零／截斷）——把資料讀回來比對第一與最後一個 sample。
        var out = [Float](repeating: -1, count: frames * channels)
        let st = out.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: frames * channels * 4, destination: $0.baseAddress!)
        }
        T.checkTrue("micbuf: 資料可讀回", st == noErr)
        T.checkTrue("micbuf: 樣本值原樣保留（非歸零）", abs(out.first! - 0.25) < 1e-6 && abs(out.last! - 0.25) < 1e-6)
    } else { T.checkTrue("micbuf: 可讀 data buffer", false) }
}

nonisolated func micHALRMSTests() {
    // 全 0.5 的訊號：RMS = 0.5
    let half = [Float](repeating: 0.5, count: 1024)
    let r1 = half.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkTrue("rms: 定值 0.5 → RMS≈0.5", abs(r1 - 0.5) < 1e-4)
    // 靜音 → 0
    let zero = [Float](repeating: 0, count: 512)
    let r2 = zero.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkEq("rms: 靜音 → 0", r2, 0)
    // 空輸入不 crash、回 0
    let r3 = [Float]().withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkEq("rms: 空輸入 → 0", r3, 0)
    // ±1 交替：RMS = 1
    let alt = (0..<1000).map { $0 % 2 == 0 ? Float(1) : Float(-1) }
    let r4 = alt.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkTrue("rms: ±1 交替 → RMS≈1", abs(r4 - 1) < 1e-4)
}
