import AVFoundation
import ScreenCaptureKit

/// 音訊軌模組：系統聲＋麥克風的一切都住這裡（spec §1 組合式掛載）。
/// 執行緒約定同 WriterBox：所有成員只在 RecordFrameSource.sampleQueue 上被觸碰。
final class RecordAudioTracks {
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    /// - Parameter micChannels: 麥克風軌 AAC 聲道數＝實際裝置聲道數（`RecordMicSource` 開 HAL tap
    ///   後查到，內建麥克風＝1）。不再硬寫 2——mic 走 HAL、聲道數由裝置決定。
    init(options: RecordOptions, micChannels: Int) {
        func makeInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        if options.captureSystemAudio { systemInput = makeInput(channels: 2) }
        if options.captureMicrophone { micInput = makeInput(channels: max(1, micChannels)) }
    }

    /// SCK 音訊相關 config：**只設系統聲**。麥克風不再走 SCK `.microphone`（那條在本 app 收不到
    /// 封包，見 `AudioInputTap`／設計文件 §0）——改由 `RecordMicSource` 走 CoreAudio HAL，
    /// 所以這裡刻意不設 `config.captureMicrophone`／`config.microphoneCaptureDeviceID`。
    static func configure(_ config: SCStreamConfiguration, options: RecordOptions) {
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = options.excludesOwnAudio
    }

    func attach(to writer: AVAssetWriter) {
        if let systemInput { writer.add(systemInput) }
        if let micInput { writer.add(micInput) }
    }

    /// gate：session 未啟動前丟（startSession 前 append 是 ObjC exception）；
    /// not-ready 丟 buffer（同影像 realtime 契約）。
    /// 路由用顯式 switch、不用 fallback——非 .audio/.microphone 的 type（例如呼叫端傳錯把
    /// 影像 buffer 誤送進這裡）直接丟棄，不能落到 systemInput：塞進 AAC input 的非音訊 buffer
    /// 是 AVFoundation 的 ObjC exception，Swift 攔不到。
    func append(_ sb: CMSampleBuffer, type: SCStreamOutputType, sessionStarted: Bool) {
        guard sessionStarted else { return }
        let input: AVAssetWriterInput?
        switch type {
        case .audio: input = systemInput
        case .microphone: input = micInput
        default: return
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    func markFinished() {
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
    }
}
