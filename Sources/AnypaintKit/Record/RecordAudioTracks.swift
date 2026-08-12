import AVFoundation
import ScreenCaptureKit

/// 音訊軌模組：系統聲＋麥克風的一切都住這裡（spec §1 組合式掛載）。
/// 執行緒約定同 WriterBox：所有成員只在 RecordFrameSource.sampleQueue 上被觸碰。
final class RecordAudioTracks {
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    init(options: RecordOptions) {
        func makeInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        if options.captureSystemAudio { systemInput = makeInput() }
        if options.captureMicrophone { micInput = makeInput() }
    }

    /// SCK 音訊相關 config 全在這裡設（掛載進 makeStreamConfiguration）。
    static func configure(_ config: SCStreamConfiguration, options: RecordOptions) {
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = options.excludesOwnAudio
        config.captureMicrophone = options.captureMicrophone
    }

    func attach(to writer: AVAssetWriter) {
        if let systemInput { writer.add(systemInput) }
        if let micInput { writer.add(micInput) }
    }

    /// gate：session 未啟動前丟（startSession 前 append 是 ObjC exception）；
    /// not-ready 丟 buffer（同影像 realtime 契約）。
    func append(_ sb: CMSampleBuffer, type: SCStreamOutputType, sessionStarted: Bool) {
        guard sessionStarted else { return }
        let input: AVAssetWriterInput? = (type == .microphone) ? micInput : systemInput
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    func markFinished() {
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
    }
}
