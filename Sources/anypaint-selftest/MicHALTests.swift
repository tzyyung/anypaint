import AnypaintKit
import CoreAudio
import CoreMedia

nonisolated func micHALDownmixTests() {
    // 交錯立體聲：L=1.0、R=0.0 → mono 應為 0.5（平均），幀數保留。
    let frames = 100
    var interleaved = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { interleaved[i * 2] = 1.0; interleaved[i * 2 + 1] = 0.0 }
    let asbd = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    interleaved.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            let mono = RecordMicSource.downmixToMonoFloat32(ptr, asbd: asbd)
            T.checkEq("downmix: 立體聲→mono 幀數", mono?.count ?? -1, frames)
            T.checkTrue("downmix: (1+0)/2≈0.5", (mono?.first).map { abs($0 - 0.5) < 1e-6 } ?? false)
            T.checkTrue("downmix: 末幀也對", (mono?.last).map { abs($0 - 0.5) < 1e-6 } ?? false)
        }
    }
    // 非 Float32 → nil（只認 Float32）
    var intAsbd = asbd
    intAsbd.mFormatFlags = kAudioFormatFlagIsSignedInteger
    interleaved.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            T.checkTrue("downmix: 非 Float32 → nil", RecordMicSource.downmixToMonoFloat32(ptr, asbd: intAsbd) == nil)
        }
    }
}

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

/// 非交錯（planar）：每聲道各一個 buffer、同幀數。這裡 buffer0=全 1.0、buffer1=全 0.0，
/// 逐幀平均應為 0.5,幀數保留。也驗單聲道直通與 scratch 重用縮容。
nonisolated func micHALDownmixPlanarTests() {
    let frames = 64
    var ch0 = [Float](repeating: 1.0, count: frames)
    var ch1 = [Float](repeating: 0.0, count: frames)
    let planarASBD = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    ch0.withUnsafeMutableBytes { b0 in
        ch1.withUnsafeMutableBytes { b1 in
            let abl = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(abl.unsafeMutablePointer) }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b0.count), mData: b0.baseAddress)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b1.count), mData: b1.baseAddress)
            let mono = RecordMicSource.downmixToMonoFloat32(abl.unsafePointer, asbd: planarASBD)
            T.checkEq("downmix planar: 幀數保留", mono?.count ?? -1, frames)
            T.checkTrue("downmix planar: (1+0)/2≈0.5", (mono?.first).map { abs($0 - 0.5) < 1e-6 } ?? false)
            T.checkTrue("downmix planar: 末幀也對", (mono?.last).map { abs($0 - 0.5) < 1e-6 } ?? false)
        }
    }

    // 單聲道交錯：直通,值不變。
    var monoIn = (0..<frames).map { Float($0) / Float(frames) }
    let monoASBD = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    monoIn.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            let mono = RecordMicSource.downmixToMonoFloat32(ptr, asbd: monoASBD)
            T.checkEq("downmix mono: 幀數保留", mono?.count ?? -1, frames)
            T.checkTrue("downmix mono: 直通值不變", (mono?[10]).map { abs($0 - Float(10) / Float(frames)) < 1e-6 } ?? false)
        }
    }

    // scratch 重用縮容:先塞大 buffer(200 幀)、再塞小 buffer(50 幀)——回傳只讀前 50 幀,
    // 不得把上次留下的尾巴當有效資料(downmixToMono 回實際幀數,wrapper 依此裁切)。
    var scratch: [Float] = []
    let big = [Float](repeating: 0.5, count: 200 * 2)
    let small = [Float](repeating: 0.5, count: 50 * 2)
    let stereoASBD = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    func run(_ src: [Float]) -> Int {
        var s = src
        return s.withUnsafeMutableBytes { raw -> Int in
            var abl = AudioBufferList()
            abl.mNumberBuffers = 1
            abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            return withUnsafePointer(to: &abl) { RecordMicSource.downmixToMono($0, asbd: stereoASBD, into: &scratch) }
        }
    }
    T.checkEq("downmix scratch: 大 buffer 回 200 幀", run(big), 200)
    T.checkTrue("downmix scratch: 大 buffer 後 scratch 已擴到 ≥200", scratch.count >= 200)
    T.checkEq("downmix scratch: 小 buffer 回實際 50 幀（不含殘留尾巴）", run(small), 50)
}

/// makeSampleBuffer 邊界:frames=0 或 channels=0 → nil（不建空 buffer）。
nonisolated func micHALSampleBufferEdgeTests() {
    let one = [Float](repeating: 0, count: 4)
    one.withUnsafeBytes { raw in
        T.checkTrue("micbuf 邊界: frames=0 → nil",
                    RecordMicSource.makeSampleBuffer(fromInterleavedFloat32: raw, frames: 0,
                                                     channels: 1, sampleRate: 48000, hostTime: 1) == nil)
        T.checkTrue("micbuf 邊界: channels=0 → nil",
                    RecordMicSource.makeSampleBuffer(fromInterleavedFloat32: raw, frames: 1,
                                                     channels: 0, sampleRate: 48000, hostTime: 1) == nil)
    }
}

/// MicLevelMonitor.rms(fromInputBufferList:) 直接測（走遍所有 buffer 當一串算整體 RMS）。
nonisolated func micLevelRMSBufferListTests() {
    // 交錯立體聲 L=1、R=0 → 全樣本 {1,0,1,0…} 的 RMS = sqrt(0.5) ≈ 0.7071
    let frames = 512
    var inter = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { inter[i * 2] = 1.0; inter[i * 2 + 1] = 0.0 }
    let interASBD = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    inter.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            let r = MicLevelMonitor.rms(fromInputBufferList: ptr, asbd: interASBD)
            T.checkTrue("micRMS: {1,0} 交錯 → sqrt(0.5)≈0.707", abs(r - Float(0.5).squareRoot()) < 1e-4)
        }
    }
    // planar 兩 buffer（全 1、全 0）→ 全樣本 RMS 同樣 sqrt(0.5)
    var p0 = [Float](repeating: 1.0, count: frames)
    var p1 = [Float](repeating: 0.0, count: frames)
    let planarASBD = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    p0.withUnsafeMutableBytes { b0 in
        p1.withUnsafeMutableBytes { b1 in
            let abl = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(abl.unsafeMutablePointer) }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b0.count), mData: b0.baseAddress)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b1.count), mData: b1.baseAddress)
            let r = MicLevelMonitor.rms(fromInputBufferList: abl.unsafePointer, asbd: planarASBD)
            T.checkTrue("micRMS: planar 全1/全0 → sqrt(0.5)≈0.707", abs(r - Float(0.5).squareRoot()) < 1e-4)
        }
    }
    // 非 Float32 → 0
    var intASBD = interASBD
    intASBD.mFormatFlags = kAudioFormatFlagIsSignedInteger
    inter.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            T.checkEq("micRMS: 非 Float32 → 0", MicLevelMonitor.rms(fromInputBufferList: ptr, asbd: intASBD), 0)
        }
    }
    // 空（0 位元組 buffer）→ 0
    var empty = [Float]()
    empty.withUnsafeMutableBytes { raw in
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: raw.baseAddress)
        withUnsafePointer(to: &abl) { ptr in
            T.checkEq("micRMS: 空輸入 → 0", MicLevelMonitor.rms(fromInputBufferList: ptr, asbd: interASBD), 0)
        }
    }
}

/// MicLevelMonitor.accepts 世代守衛（遲到回呼不蓋新值的純判定）。
nonisolated func micLevelGenerationTests() {
    T.checkTrue("accepts: 同世代接受", MicLevelMonitor.accepts(incoming: 7, current: 7))
    T.checkTrue("accepts: 過期世代拒絕", !MicLevelMonitor.accepts(incoming: 6, current: 7))
    T.checkTrue("accepts: 較新世代也拒絕（只認相等）", !MicLevelMonitor.accepts(incoming: 8, current: 7))
}

/// RecordMath.gridTimes 均勻網格（至少 2 格,step=1/fps,首格 0）。
nonisolated func recordMathGridTests() {
    let g = RecordMath.gridTimes(duration: 1.0, fps: 4)
    T.checkEq("gridTimes: 1s@4fps → 4 格", g.count, 4)
    T.checkEq("gridTimes: 首格 0", g.first, 0)
    T.checkTrue("gridTimes: 步距 1/fps", abs(g[1] - 0.25) < 1e-9)
    // 極短片段仍至少 2 格（GIF 最少兩格才有動畫意義）
    T.checkEq("gridTimes: 極短 → 至少 2 格", RecordMath.gridTimes(duration: 0.001, fps: 12).count, 2)
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
