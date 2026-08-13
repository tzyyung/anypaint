import Foundation
import AnypaintKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

nonisolated func goertzelTests() {
    let sr = 48000.0
    let tone = (0..<48000).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) * 0.5 }
    let silence = [Float](repeating: 0, count: 48000)
    let noiseless440 = RecordMath.goertzelPower(samples: tone, sampleRate: sr, targetHz: 440)
    let off880 = RecordMath.goertzelPower(samples: tone, sampleRate: sr, targetHz: 880)
    T.checkTrue("goertzel: 440Hz 音在 440 檢測點能量高", noiseless440 > 0.01)
    T.checkTrue("goertzel: 440Hz 音在 880 檢測點能量低", off880 < noiseless440 / 100)
    T.checkTrue("goertzel: 靜音能量≈0",
                RecordMath.goertzelPower(samples: silence, sampleRate: sr, targetHz: 440) < 1e-9)
}

/// 合成 LPCM stereo float32 CMSampleBuffer（模擬 SCK 音訊格式）。
func makeAudioSampleBuffer(startSeconds: Double, seconds: Double, channels: Int = 2) -> CMSampleBuffer? {
    let sr = 48000.0
    let bpf = UInt32(channels * 4)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bpf, mFramesPerPacket: 1, mBytesPerFrame: bpf,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr,
        let fmt else { return nil }
    let frames = Int(seconds * sr)
    var samples = [Float32](repeating: 0, count: frames * channels)
    for i in 0..<frames {
        let v = Float32(sin(2 * .pi * 440 * Double(i) / sr)) * 0.5
        for c in 0..<channels { samples[i * channels + c] = v }
    }
    let byteCount = samples.count * MemoryLayout<Float32>.size
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
        blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
    _ = samples.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: byteCount)
    }
    var sb: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames,
        presentationTimeStamp: CMTime(seconds: startSeconds, preferredTimescale: 48000),
        packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
    return sb
}

/// 合成 BGRA 影像 CMSampleBuffer（模擬 SCK 影像格）。
func makeVideoSampleBuffer(ptsSeconds: Double, width: Int = 64, height: Int = 64) -> CMSampleBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let pb else { return nil }
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb,
                                                 formatDescriptionOut: &fmt)
    guard let fmt else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
        decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb,
        formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb
}

/// 同步包裝 async `loadTracks`（selftest 是同步 CLI；semaphore＋Task 是同檔既有慣例，
/// 測試函式為 nonisolated top-level，Task 繼承非隔離環境、跑在全域執行緒，wait 不會自鎖）。
/// 不用已棄用的同步 `tracks(withMediaType:)`——零 warning 是硬約束。
private func loadTracksSync(url: URL, mediaType: AVMediaType) -> [AVAssetTrack] {
    var tracks: [AVAssetTrack] = []
    let sema = DispatchSemaphore(value: 0)
    Task {
        tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: mediaType)) ?? []
        sema.signal()
    }
    sema.wait()
    return tracks
}

func recordAudioTracksEndToEndTests() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anypaint-selftest-audio-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let options = RecordOptions(showsCursor: false, useHEVC: false,
                                captureSystemAudio: true, captureMicrophone: true)
    guard let box = try? WriterBox(outputURL: url, pixelWidth: 64, pixelHeight: 64,
                                   options: options) else {
        T.checkTrue("audio e2e: WriterBox 建立", false); return
    }
    // 音訊早於首格影像 → 應被丟（session 未啟動）
    box.appendAudio(makeAudioSampleBuffer(startSeconds: 0.5, seconds: 0.2)!, type: .audio)
    for i in 0..<10 { box.append(makeVideoSampleBuffer(ptsSeconds: 1.0 + Double(i) / 30)!) }
    box.appendAudio(makeAudioSampleBuffer(startSeconds: 1.0, seconds: 0.3)!, type: .audio)
    box.appendAudio(makeAudioSampleBuffer(startSeconds: 1.0, seconds: 0.3, channels: 1)!, type: .microphone)   // mic 軌現在固定 mono
    let sema = DispatchSemaphore(value: 0)
    var finished = false
    box.finish(nowUptime: 1.4) { result in
        if case .success = result { finished = true }
        sema.signal()
    }
    sema.wait()
    T.checkTrue("audio e2e: finalize 成功", finished)
    T.checkEq("audio e2e: 1 條影像軌", loadTracksSync(url: url, mediaType: .video).count, 1)
    let audioTracks = loadTracksSync(url: url, mediaType: .audio)
    T.checkEq("audio e2e: 2 條音軌", audioTracks.count, 2)
    // 早到的 0.5s 音訊有沒有真的被丟：這裡不能靠 timeRange.start 判斷「有沒有提前」——
    // 實測（async load(.timeRange)，非同步官方 API，避開已棄用同步版本可能的疑慮）證實
    // AVFoundation 把每條軌的呈現起點正規化成「相對 session 起點」，一律回報 0，不是原始
    // 時鐘的絕對秒數；backpressure 也會讓影像軌實際寫入的格數 < 附上的格數（本例 10 格只有
    // 7 格因 isReadyForMoreMediaData 而真正寫入，屬於既有契約「丟格不阻塞」，非本次改動的
    // 缺陷）。這條早到音訊真正的保護不是「檔案裡有沒有被悄悄放進去然後起點前移」——
    // `sessionStarted` 這個 gate 存在的理由（CLAUDE.md 記錄過的教訓）是session 從未啟動時
    // append 是 ObjC exception，Swift 攔不到、直接讓整個 selftest 行程 crash。這個 gate 若被
    // 移除，這條測試會在到達這裡之前就讓整個 process 以非零狀態碼中止，比任何軌道層級的斷言
    // 更難忽視。走到這裡（`finalize 成功` 已經是 ✅）本身就是這個 gate 有效的證據。
    if let firstAudioTrack = audioTracks.first {
        let sema2 = DispatchSemaphore(value: 0)
        var duration = 0.0
        Task {
            let tr = try! await firstAudioTrack.load(.timeRange)
            duration = tr.duration.seconds
            sema2.signal()
        }
        sema2.wait()
        T.checkTrue("audio e2e: 音軌 duration > 0（確實有音訊內容寫入，不是空軌）", duration > 0)
    } else {
        T.checkTrue("audio e2e: 音軌 timeRange 可讀", false)
    }

    // 兩開關全關 → 0 條音軌（零改動回歸保證：不開音訊時行為與加音軌之前完全一致）
    let url2 = FileManager.default.temporaryDirectory
        .appendingPathComponent("anypaint-selftest-audio2-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url2) }
    let o2 = RecordOptions(showsCursor: false, useHEVC: false)
    if let b2 = try? WriterBox(outputURL: url2, pixelWidth: 64, pixelHeight: 64, options: o2) {
        for i in 0..<5 { b2.append(makeVideoSampleBuffer(ptsSeconds: Double(i) / 30)!) }
        let s2 = DispatchSemaphore(value: 0)
        b2.finish(nowUptime: 0.2) { _ in s2.signal() }; s2.wait()
        T.checkEq("audio e2e: 兩開關全關＝0 音軌",
                  loadTracksSync(url: url2, mediaType: .audio).count, 0)
    } else { T.checkTrue("audio e2e: 全關 WriterBox 建立", false) }

    // 只開系統聲 → 1 條音軌
    let url1 = FileManager.default.temporaryDirectory
        .appendingPathComponent("anypaint-selftest-audio1-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url1) }
    let o1 = RecordOptions(showsCursor: false, useHEVC: false, captureSystemAudio: true)
    if let b1 = try? WriterBox(outputURL: url1, pixelWidth: 64, pixelHeight: 64, options: o1) {
        for i in 0..<5 { b1.append(makeVideoSampleBuffer(ptsSeconds: Double(i) / 30)!) }
        b1.appendAudio(makeAudioSampleBuffer(startSeconds: 0, seconds: 0.1)!, type: .audio)
        let s = DispatchSemaphore(value: 0)
        b1.finish(nowUptime: 0.2) { _ in s.signal() }; s.wait()
        T.checkEq("audio e2e: 單開系統聲＝1 音軌",
                  loadTracksSync(url: url1, mediaType: .audio).count, 1)
    } else { T.checkTrue("audio e2e: 單軌 WriterBox 建立", false) }

    // 空音軌結論（docs/animated-capture.md §7）：開了 captureSystemAudio（因此建了
    // systemInput）但整段只 append 影像、一個音訊 buffer 都不送——writer 仍要正常 finalize，
    // 輸出檔對應那條音軌完全不出現（0，不是「開著但空」），這不是失敗路徑。
    let url3 = FileManager.default.temporaryDirectory
        .appendingPathComponent("anypaint-selftest-audio3-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url3) }
    let o3 = RecordOptions(showsCursor: false, useHEVC: false, captureSystemAudio: true)
    if let b3 = try? WriterBox(outputURL: url3, pixelWidth: 64, pixelHeight: 64, options: o3) {
        for i in 0..<5 { b3.append(makeVideoSampleBuffer(ptsSeconds: Double(i) / 30)!) }
        let s3 = DispatchSemaphore(value: 0)
        var finished3 = false
        b3.finish(nowUptime: 0.2) { result in
            if case .success = result { finished3 = true }
            s3.signal()
        }
        s3.wait()
        T.checkTrue("audio e2e: 零音訊 buffer＋開系統聲＝finalize 仍成功", finished3)
        T.checkEq("audio e2e: 零音訊 buffer＋開系統聲＝0 音軌（開了不代表有）",
                  loadTracksSync(url: url3, mediaType: .audio).count, 0)
    } else { T.checkTrue("audio e2e: 零音訊 buffer WriterBox 建立", false) }
}
