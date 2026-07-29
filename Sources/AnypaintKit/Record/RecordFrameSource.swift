import AppKit
import AVFoundation
import ScreenCaptureKit

public enum RecordError: Error {
    case noFrames               // 一格都沒收到就停止
    case writerFailed(Error?)   // finishWriting 後 status != .completed（QuickRecorder 教訓）
}

/// AVAssetWriter 封裝＋最後一格保留。**只在 sampleQueue 上觸碰**（append 與 finalize 都派進
/// 同一條序列佇列，天然序列化，無鎖）。
/// 配方出處（設計文件 §3/§10）：直接 append、懶啟動 startSession（QuickRecorder/Azayaka/
/// Aperture 一致）；補尾格＋endSession（nonstrict stop() 原碼）；status 檢查（QuickRecorder）。
///
/// ### 執行緒約定（`@unchecked Sendable` 的成立條件，比照 `ScrollStitchEngine`）
/// 這個類別的**所有**成員只能在呼叫端的單一序列佇列（`RecordFrameSource.sampleQueue`）上被
/// 觸碰：`append` 在 stream handler 裡（已派進該佇列）呼叫；`finish`／`cancel` 由
/// `stopAndFinish`／`abort` 用 `sampleQueue.async` 派工呼叫，不直接在 MainActor 上碰內部狀態。
/// 內部沒有任何跨佇列直接讀寫的路徑，因此把整個型別標成 Sendable 是安全的——真正的隔離
/// 邊界在呼叫端（誰負責派工進 sampleQueue），不是靠編譯器逐一檢查每個 stored property。
final class WriterBox: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    /// 保留最後一格供停止時補尾。**永久佔掉 SCK IOSurface 池一張**——queueDepth 必須 ≥ 5
    /// （nonstrict 原註解；本 stream 設 6）。
    private var lastSampleBuffer: CMSampleBuffer?

    init(outputURL: URL, pixelWidth: Int, pixelHeight: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Azayaka 位元率公式 + QuickRecorder 20 萬下限；30fps、H.264、Rec.709
        let bitrate = max(200_000, Int(Double(pixelWidth * pixelHeight) * (30.0 / 8.0) * 0.9))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true   // 全部實戰專案一致；ready=false 時丟格不排隊
        writer.add(input)
        writer.startWriting()                     // 立刻 startWriting；session 懶啟動（防黑首格）
    }

    /// sampleQueue 上呼叫。只收 .complete 的 buffer（呼叫端已 gate）。
    func append(_ sb: CMSampleBuffer) {
        guard writer.status == .writing else { return }   // startWriting 失敗時讓格子靜默落空
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
        }
        guard input.isReadyForMoreMediaData else { return }  // 契約：丟格，不阻塞
        input.append(sb)
        lastSampleBuffer = sb
    }

    /// sampleQueue 上呼叫（stream 已停）。補尾格 → endSession → finalize。
    /// - Parameter nowUptime: 停止當下的 host clock 秒數（ProcessInfo.systemUptime；
    ///   SCK 的 PTS 在 host clock 上，**不可用 Date**——設計文件 §3）。
    func finish(nowUptime: TimeInterval, completion: @escaping (Result<Void, RecordError>) -> Void) {
        guard sessionStarted, let last = lastSampleBuffer else {
            writer.cancelWriting()
            completion(.failure(.noFrames))
            return
        }
        var endPTS = CMSampleBufferGetPresentationTimeStamp(last)
        if RecordMath.needsTailFrame(lastPTSSeconds: endPTS.seconds, nowSeconds: nowUptime) {
            // 結尾靜止 → 把最後一格重蓋時間戳到「現在」補進去，檔案時長才等於實際錄製時長
            let now = CMTime(seconds: nowUptime, preferredTimescale: 600)
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(last),
                                            presentationTimeStamp: now,
                                            decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                     sampleBuffer: last,
                                                     sampleTimingEntryCount: 1,
                                                     sampleTimingArray: &timing,
                                                     sampleBufferOut: &copy) == noErr,
               let copy, input.isReadyForMoreMediaData {
                input.append(copy)
                endPTS = now
            }
        }
        writer.endSession(atSourceTime: endPTS)
        input.markAsFinished()
        writer.finishWriting { [writer] in
            // writer 可能在最後一步靜默失敗（QuickRecorder SCContext.swift:352 教訓）
            if writer.status == .completed { completion(.success(())) }
            else { completion(.failure(.writerFailed(writer.error))) }
        }
    }

    /// 取消：丟掉母帶。
    func cancel() {
        input.markAsFinished()
        writer.cancelWriting()
        lastSampleBuffer = nil
    }
}

/// SCStream 封裝：吐出的 CMSampleBuffer 直接進 WriterBox（不轉像素、不合成——設計文件 §3）。
@MainActor
public final class RecordFrameSource: NSObject {
    public var onStreamError: ((Error) -> Void)?

    private var stream: SCStream?
    private var pendingStop = false
    private var outputURL: URL?
    private let sampleQueue = DispatchQueue(label: "anypaint.record.frames")
    /// nonisolated：handler 在 sampleQueue 上直接讀（同 ScrollFrameSource.ciContext 的編譯器限制
    /// 說明，但這裡是可變的 var，多一條額外保證要記清楚）。**豁免理由**：寫入只發生在 MainActor 的
    /// start/stopAndFinish/abort（彼此天然序列化，MainActor 一次只跑一段）；讀取只發生在
    /// sampleQueue 上的 stream(_:didOutputSampleBuffer:)。停止路徑一律先 `await stream.stopCapture()`
    /// 拿到「SCK 保證不再派發 handler」之後才把 box 設 nil——因此不存在「MainActor 正在改 box、
    /// sampleQueue 同時在讀」的窗口；GCD `async` 派工與 `await` 的掛起點本身即是記憶體同步點。
    private nonisolated(unsafe) var box: WriterBox?

    /// - Parameters:
    ///   - selectionGlobal: 選區（AppKit 全域座標、點、左下原點）。
    ///   - showsCursor: 游標交給 SCK 畫（實戰專案一致做法）。
    ///   - ringWindowNumber: 點擊圈視窗的 windowNumber；非 nil 時把它放進 exceptingWindows
    ///     白名單（app 整體排除、唯獨它被拍——設計文件 §3 filter）。
    public func start(selectionGlobal: CGRect, screen: NSScreen,
                      showsCursor: Bool, ringWindowNumber: Int?, outputURL: URL) async throws {
        pendingStop = false
        self.outputURL = outputURL
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplays
        }
        let selfApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        // exceptingWindows 是建 filter 當下的靜態快照 → 點擊圈視窗必須已存在（session 先建它再
        // 呼叫這裡）。用 windowID 比對，不用標題（設計文件 §3；QuickRecorder 用標題比對較脆弱）。
        var excepting: [SCWindow] = []
        if let num = ringWindowNumber,
           let w = content.windows.first(where: { $0.windowID == CGWindowID(num) }) {
            excepting = [w]
        }
        let filter = SCContentFilter(display: display, excludingApplications: selfApps,
                                     exceptingWindows: excepting)
        let scale = CGFloat(filter.pointPixelScale)
        let geo = ScrollCoords.streamGeometry(selectionGlobal: selectionGlobal,
                                              screenFrameGlobal: screen.frame, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = geo.sourceRect
        config.width = geo.pixelWidth        // 必設：否則縮進預設 1920×1080（CLAUDE.md）
        config.height = geo.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6                // 保留 lastSampleBuffer 佔 1 張，3 不夠（設計文件 §3）
        config.showsCursor = showsCursor
        config.capturesAudio = false         // v1 不錄音訊：也不加 .audio output
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        let boxLocal = try WriterBox(outputURL: outputURL,
                                     pixelWidth: geo.pixelWidth, pixelHeight: geo.pixelHeight)
        self.box = boxLocal
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        if pendingStop {                     // start 的 await 期間被取消（同 ScrollFrameSource 慣例）
            try? await stream.stopCapture()
            // cancel 與刪檔必須在同一個 sampleQueue block 裡依序做：cancelWriting() 對 AVAssetWriter
            // 是同步的，但 sampleQueue.async 本身是 fire-and-forget，若刪檔改放在這裡外面、
            // 在 MainActor 上緊接著呼叫，就會跟佇列上還沒真的跑到的 cancel() 賽跑（檔案可能還被
            // writer 占著）。放進同一個 block 保證「先取消、寫入器真的收手，才刪檔」。
            sampleQueue.async {
                boxLocal.cancel()
                try? FileManager.default.removeItem(at: outputURL)
            }
            return
        }
        self.stream = stream
    }

    /// 正常停止：停 stream → 在 sampleQueue 上 finalize（補尾格＋endSession＋status 檢查）。
    public func stopAndFinish() async throws -> URL {
        pendingStop = true
        if let stream { self.stream = nil; try? await stream.stopCapture() }
        guard let box, let url = outputURL else { throw RecordError.noFrames }
        self.box = nil
        let now = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { cont in
            sampleQueue.async {
                box.finish(nowUptime: now) { result in
                    switch result {
                    case .success: cont.resume(returning: url)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
        }
    }

    /// 取消：停 stream、丟母帶、刪暫存檔。
    public func abort() async {
        pendingStop = true
        if let stream { self.stream = nil; try? await stream.stopCapture() }
        let box = self.box
        self.box = nil
        let url = outputURL
        // 理由同 start() 的 pendingStop 分支：cancel 與刪檔擠進同一個 sampleQueue block，
        // 讓「先取消、寫入器真的收手，才刪檔」成立，不與 fire-and-forget 的 async 賽跑。
        sampleQueue.async {
            box?.cancel()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        outputURL = nil
    }
}

extension RecordFrameSource: SCStreamOutput, SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                                   of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // 只收 .complete；.idle/.blank 不可進 writer（否則黑首格＋時長錯——設計文件 §3）
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        box?.append(sb)   // sampleQueue 上；主執行緒零工作
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onStreamError?(error) }
    }
}
