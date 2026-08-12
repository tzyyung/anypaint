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
func makeAudioSampleBuffer(startSeconds: Double, seconds: Double) -> CMSampleBuffer? {
    let sr = 48000.0
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr,
        let fmt else { return nil }
    let frames = Int(seconds * sr)
    var samples = [Float32](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float32(sin(2 * .pi * 440 * Double(i) / sr)) * 0.5
        samples[i * 2] = v; samples[i * 2 + 1] = v
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
    box.appendAudio(makeAudioSampleBuffer(startSeconds: 1.0, seconds: 0.3)!, type: .microphone)
    let sema = DispatchSemaphore(value: 0)
    var finished = false
    box.finish(nowUptime: 1.4) { result in
        if case .success = result { finished = true }
        sema.signal()
    }
    sema.wait()
    T.checkTrue("audio e2e: finalize 成功", finished)
    let asset = AVURLAsset(url: url)
    T.checkEq("audio e2e: 1 條影像軌", asset.tracks(withMediaType: .video).count, 1)
    T.checkEq("audio e2e: 2 條音軌", asset.tracks(withMediaType: .audio).count, 2)

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
                  AVURLAsset(url: url1).tracks(withMediaType: .audio).count, 1)
    } else { T.checkTrue("audio e2e: 單軌 WriterBox 建立", false) }
}
