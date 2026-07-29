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
    /// 說明，但這裡是可變的 var，多一條額外保證要記清楚）。**豁免理由（fix round 3 再次校正——
    /// round 2 只讓 `abort()` 遵守，`stopAndFinish()` 當時仍是漏網之魚，這裡把敘述改成兩者
    /// 都遵守之後才成立的樣子）**：真正成立的不變式是「`self.box` 只在『這次呼叫自己手上有一個
    /// 已經 `await stream.stopCapture()` 過的 stream』時才會被清 nil」——寫入者必須先親自
    /// 確認過 SCK 不再派發 handler，才能碰 box。`start()` 的 pendingStop 分支、`abort()`、
    /// `stopAndFinish()` 三者都遵守這條；`abort()`／`stopAndFinish()` 若被呼叫時 `self.stream`
    /// 還是 nil（代表 `start()` 還在飛，尚未走到賦值 `self.stream` 那步——這正是 `self.box`
    /// 可能已經存在、handler 也可能已經在 sampleQueue 上跑的窗口），兩者手上都沒有可以自己
    /// `stopCapture()` 的 stream，這時都完全不碰 `self.box`（見各自內部的早退分支），把清理
    /// 完全交給 `start()` 自己的 pendingStop 分支收尾。沒有這條規則以前，`abort()`（後來
    /// `stopAndFinish()` 也被抓到同一個洞）會在這個窗口對 `self.box` 做無同步的跨執行緒寫，
    /// 跟 sampleQueue 上的讀是真的資料競爭。
    private nonisolated(unsafe) var box: WriterBox?

    /// - Parameters:
    ///   - selectionGlobal: 選區（AppKit 全域座標、點、左下原點）。
    ///   - showsCursor: 游標交給 SCK 畫（實戰專案一致做法）。
    ///   - ringWindowNumber: 點擊圈視窗的 windowNumber；非 nil 時把它放進 exceptingWindows
    ///     白名單（app 整體排除、唯獨它被拍——設計文件 §3 filter）。
    ///
    /// 契約：`start()` 拋錯（TCC 拒絕、`CaptureError.noDisplays` 都是實機常見狀況）之後，
    /// 物件已經自己清乾淨（`self.box`／`self.stream`／`self.outputURL` 全部回到 nil）——
    /// 呼叫端可以直接重試，不需要先呼叫 `abort()` 才能再 `start()`。
    public func start(selectionGlobal: CGRect, screen: NSScreen,
                      showsCursor: Bool, ringWindowNumber: Int?, outputURL: URL) async throws {
        // 防重入：呼叫端若在前一段 session 收尾（stopAndFinish/abort）完成前又呼叫 start()，
        // 絕不能無條件覆寫 stream/box——舊 stream 會變孤兒、舊 WriterBox 永久扣住一張
        // IOSurface（queueDepth 張裡的一張）不放。stopAndFinish/abort 都會在真正收尾前把
        // self.stream 與 self.box 清成 nil，所以這個檢查等同「上一段真的結束了嗎」。
        guard stream == nil, box == nil else { throw RecordError.alreadyRecording }
        pendingStop = false
        self.outputURL = outputURL
        defer {
            // 這個函式有三段更早的 throw（SCShareableContent 抓取失敗、noDisplays、
            // WriterBox.init 失敗）發生在 self.box 被指派之前——那些路徑上面沒有任何程式碼
            // 會清 self.outputURL，若不補這個 defer，物件雖然沒有 box/stream 洩漏，卻會留著
            // 一個指向「什麼都還沒建」的 outputURL，跟上面「拋錯後全部回到 nil」的契約不符。
            // 判準用 `box == nil`：一旦 self.box 被指派過，之後任何一條退出路徑（下面的
            // 內層 do/catch、pendingStop 分支、或成功完成）都已經各自處理過 outputURL 的去留，
            // 這裡就不重複插手（用 box 而非額外的旗標，因為它已經是「有沒有建出東西」的
            // 事實依據，不需要平行維護第二個布林值）。
            if box == nil { self.outputURL = nil }
        }
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
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            // 這兩步任一步失敗（TCC 拒絕、noDisplays 類錯誤實機都常見）都要在丟出去之前自己
            // 清乾淨：不然 self.box 留著非 nil，之後每次 start() 都會被上面的防重入 guard
            // 擋成 alreadyRecording，永久卡死；孤兒 WriterBox 也扣著一張 IOSurface 與一個
            // 暫存檔不放。先 `stopCapture()` 才清 box，理由同 pendingStop 分支與
            // `box` 的豁免註解——即使 startCapture() 本身失敗，也用同一套「先確認 SCK
            // 收手、才碰 box」紀律，不因為是錯誤路徑就破例。
            try? await stream.stopCapture()
            self.box = nil
            self.outputURL = nil
            sampleQueue.async {
                boxLocal.cancel()
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }
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
                self.outputURL = nil   // 所有權轉交同一套心智模型：box 清了，outputURL 也一併清
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
    ///
    /// 若 `start()` 還在飛（例如 `SCShareableContent` 抓取慢了幾百毫秒、使用者這時就按了
    /// 停止，或限時錄影剛好在這個窗口到期），這裡沒有自己的 stream 可以先確認 SCK 收手，
    /// 會直接丟 `RecordError.noFrames`——即使 `WriterBox` 當下可能已經建好、甚至已經收到
    /// 第一格：對呼叫端來說「根本還沒真正開始錄影」跟「錄了但一格都沒收到」結果一樣，都是
    /// 沒有可用的母帶。真正的收尾（cancel＋刪暫存檔）交給 `start()` 自己的 pendingStop
    /// 分支，這裡不搶（見 `box` 屬性上的豁免理由）。
    public func stopAndFinish() async throws -> URL {
        pendingStop = true
        guard let stream else {
            // 同 abort() 的早退分支，理由一致：self.stream 還是 nil 時，手上沒有可以先
            // await stopCapture() 的 stream，不碰 self.box／self.outputURL，全部交給
            // start() 自己的 pendingStop 分支收尾。
            throw RecordError.noFrames
        }
        self.stream = nil
        try? await stream.stopCapture()
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

    /// 取消：已經在錄影時，停 stream、丟母帶、刪暫存檔（回傳前保證這三件事都做完）。
    ///
    /// 若 `start()` 還在飛（`self.stream` 尚未賦值——例如 `SCShareableContent` 抓取還沒
    /// 回來，或還在等 `startCapture()`），這裡沒有自己的 stream 可以先確認 SCK 收手，
    /// 只會設 `pendingStop = true` 就立刻回傳；實際的停 stream／丟母帶／刪暫存檔會延後到
    /// `start()` 自己的 pendingStop 分支才發生（`start()` 那次呼叫尚未 resume，呼叫端看
    /// 不到、也等不到那個時間點）。也就是說：`abort()` 回傳時，暫存檔不保證已經被刪掉——
    /// 只有在呼叫 `abort()` 當下已經確定在錄影（`self.stream` 非 nil）才有這個保證。
    public func abort() async {
        pendingStop = true
        guard let stream else {
            // self.stream 還是 nil：要嘛從來沒有 session 在跑（什麼都不用做），要嘛
            // start() 還在飛、尚未走到賦值 self.stream 那步——這種情況下 self.box 可能已經
            // 存在、handler 也可能已經在 sampleQueue 上讀它，但這裡手上沒有自己的 stream
            // 可以先 `await stopCapture()` 確認 SCK 收手，所以完全不碰 self.box／
            // self.outputURL（見 box 的豁免註解）。上面已經設好 pendingStop = true，
            // 收尾交給 start() 自己的 pendingStop 分支：它手上有真正的 stream，能先
            // stopCapture() 才清 box。這裡直接回傳，是刻意的「盡力而為、延後生效」，
            // 不是漏掉——比照 ScrollFrameSource.stop() 對同一種情境的處理方式。
            return
        }
        self.stream = nil
        try? await stream.stopCapture()
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
