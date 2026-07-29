import AppKit
import AVFoundation
import ScreenCaptureKit

public enum RecordError: Error {
    case noFrames               // 一格都沒收到就停止
    case writerFailed(Error?)   // finishWriting 後 status != .completed（QuickRecorder 教訓）
    case alreadyRecording       // start() 在既有 session 收尾前又被呼叫——絕不重入覆寫 stream/box
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
    /// `finish`／`cancel` 第一次被呼叫就鎖住，之後兩者皆變 no-op；`append` 也一併擋掉。
    /// 補的是一個實機會撞到的競態：`RecordFrameSource.start()` 的 await 期間被 `abort()`
    /// 打斷時，`abort()` 與 `start()` 自己的收尾分支可能對同一個 box 各呼叫一次 cancel()——
    /// `markAsFinished`／`cancelWriting` 對已終結的 writer 再呼叫一次是 AVFoundation 的
    /// ObjC exception（Swift 攔不到，直接 crash）。這面旗子讓兩次呼叫中只有先到的那次生效。
    private var isTerminal = false

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
        // isTerminal：finish()/cancel() 呼叫過就不能再 append——`markAsFinished()` 之後
        // `writer.status` 在 finishWriting 完成前仍會回報 .writing（非同步收尾的空窗期），
        // 只靠 status 擋不住這段時間遲到的格子（曾經是真的 crash 路徑）。
        guard !isTerminal, writer.status == .writing else { return }   // startWriting 失敗時讓格子靜默落空
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
        guard !isTerminal else {
            // 已經 finish 或 cancel 過一次——冪等：不重做，也不再碰 writer。
            completion(.failure(.writerFailed(nil)))
            return
        }
        isTerminal = true
        guard writer.status == .writing else {
            // 中途已經離開 .writing（磁碟滿→.failed 等 QuickRecorder 教訓；或已被取消／完成）：
            // 不能再呼叫 endSession／markAsFinished／finishWriting／cancelWriting，這些對非
            // .writing 狀態的 writer 呼叫是 AVFoundation 的 ObjC exception，Swift 攔不到。
            completion(.failure(.writerFailed(writer.error)))
            return
        }
        guard sessionStarted, let last = lastSampleBuffer else {
            writer.cancelWriting()   // 此處已知 status == .writing，cancelWriting() 安全
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
        guard !isTerminal else { return }   // 已經 finish 或 cancel 過一次——冪等
        isTerminal = true
        guard writer.status == .writing else { return }   // 已經 .failed/.completed：什麼都不用做
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
        // 防重入：呼叫端若在前一段 session 收尾（stopAndFinish/abort）完成前又呼叫 start()，
        // 絕不能無條件覆寫 stream/box——舊 stream 會變孤兒、舊 WriterBox 永久扣住一張
        // IOSurface（queueDepth 張裡的一張）不放。stopAndFinish/abort 都會在真正收尾前把
        // self.stream 與 self.box 清成 nil，所以這個檢查等同「上一段真的結束了嗎」。
        guard stream == nil, box == nil else { throw RecordError.alreadyRecording }
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
            // 只有在 self.box 仍然是「我剛剛建的那個」時才由這裡清理：await 這段期間
            // abort() 可能已經搶先把 self.box 讀走、nil 掉、自己派工 cancel 過一次了——
            // 若不檢查就無條件再 cancel 一次 boxLocal，會是對同一個 WriterBox 呼叫兩次
            // cancel（WriterBox 自己的 isTerminal 雖然會擋下第二次的實際動作，這裡的
            // === 檢查是第二層：避免多送一次不必要的 sampleQueue 派工，且讓「誰負責清理」
            // 這件事在 MainActor 上就講清楚，不只靠 WriterBox 內部冪等兜底）。
            if self.box === boxLocal {
                self.box = nil
                sampleQueue.async {
                    boxLocal.cancel()
                    try? FileManager.default.removeItem(at: outputURL)
                }
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
        // 母帶的所有權在這裡整個轉交出去（box 與 outputURL 都清成 nil）：
        // 之後不管是 abort() 被誤呼叫、還是呼叫端等 continuation 期間又呼叫別的方法，
        // 看到的都是「這裡已經沒東西了」，不會有 abort() 誤刪已經（或即將）成功的檔案
        // ——刪檔的責任只留給下面 .failure 分支自己收拾暫存檔。
        self.box = nil
        self.outputURL = nil
        let now = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { cont in
            sampleQueue.async {
                box.finish(nowUptime: now) { result in
                    switch result {
                    case .success:
                        cont.resume(returning: url)
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: url)   // 寫失敗的半成品不留在磁碟上
                        cont.resume(throwing: e)
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
        outputURL = nil
        // 理由同 start() 的 pendingStop 分支：cancel 與刪檔擠進同一個 sampleQueue block，
        // 讓「先取消、寫入器真的收手，才刪檔」成立。這裡額外用 continuation 等它真的做完
        // 才讓 abort() 回傳——否則是 fire-and-forget，呼叫端 await 完 abort() 就以為收尾
        // 完成、緊接著用同一個路徑 start() 新錄影，會跟這裡還沒真的跑到的 removeItem 賽跑
        // （新檔案剛落地就被舊的刪檔刪掉）。
        await withCheckedContinuation { cont in
            sampleQueue.async {
                box?.cancel()
                if let url { try? FileManager.default.removeItem(at: url) }
                cont.resume()
            }
        }
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
