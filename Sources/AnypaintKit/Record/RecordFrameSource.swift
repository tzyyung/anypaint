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
/// 建構發生在呼叫端執行緒（實際上是 `RecordFrameSource.start()` 所在的 MainActor）；建構完成、
/// 賦值給 `RecordFrameSource.box` 之後，這個類別的**所有**成員只能在呼叫端的單一序列佇列
/// （`RecordFrameSource.sampleQueue`）上被觸碰：`append` 在 stream handler 裡（已派進該佇列）
/// 呼叫；`finish`／`cancel` 由 `stopAndFinish`／`abort` 用 `sampleQueue.async` 派工呼叫，不直接
/// 在 MainActor 上碰內部狀態。MainActor 建構、交棒給 sampleQueue 之間的 happens-before 靠
/// `self.box = boxLocal` 這次賦值本身（Swift 的 memory model 保證單一變數賦值與之後任何讀取
/// 之間有序，不需要額外的鎖或 barrier）。內部沒有任何跨佇列直接讀寫的路徑，因此把整個型別
/// 標成 Sendable 是安全的——真正的隔離邊界在呼叫端（誰負責派工進 sampleQueue），不是靠編譯器
/// 逐一檢查每個 stored property。
///
/// 公開（`public`）僅為了讓 selftest（獨立 target，只能走 `AnypaintKit` 的公開介面）做端到端
/// 驗證；**唯一合法呼叫者是 `RecordFrameSource`**，其餘呼叫端若要用這個類別，必須自備跟
/// `sampleQueue` 同等的單一序列佇列，否則上述執行緒約定不成立。
public final class WriterBox: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audio: RecordAudioTracks
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

    /// - Parameter options: `useHEVC` 決定 codec——false＝H.264（預設）、true＝HEVC。檔案仍是
    ///   .mp4（hevc-in-mp4 合法）。位元率因子隨 codec 切換：H.264 沿用 Azayaka 原公式 0.9；
    ///   HEVC 用 0.9×0.5＝0.45（同款 Azayaka 公式的 hevc 因子，設計文件 §1.8）。
    public init(outputURL: URL, pixelWidth: Int, pixelHeight: Int, options: RecordOptions) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Azayaka 位元率公式 + QuickRecorder 20 萬下限；30fps、Rec.709
        let bitrateFactor = options.useHEVC ? 0.45 : 0.9
        let bitrate = max(200_000, Int(Double(pixelWidth * pixelHeight) * (30.0 / 8.0) * bitrateFactor))
        let settings: [String: Any] = [
            AVVideoCodecKey: options.useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
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
        audio = RecordAudioTracks(options: options)
        audio.attach(to: writer)
        writer.startWriting()                     // 立刻 startWriting；session 懶啟動（防黑首格）
    }

    /// sampleQueue 上呼叫。只收 .complete 的 buffer（呼叫端已 gate）。
    public func append(_ sb: CMSampleBuffer) {
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

    /// sampleQueue 上呼叫；gate 同 append（isTerminal／status），session gate 交給 audio.append。
    public func appendAudio(_ sb: CMSampleBuffer, type: SCStreamOutputType) {
        guard !isTerminal, writer.status == .writing else { return }
        audio.append(sb, type: type, sessionStarted: sessionStarted)
    }

    /// sampleQueue 上呼叫（stream 已停）。補尾格 → endSession → finalize。
    /// - Parameter nowUptime: 停止當下的 host clock 秒數（ProcessInfo.systemUptime；
    ///   SCK 的 PTS 在 host clock 上，**不可用 Date**——設計文件 §3）。
    public func finish(nowUptime: TimeInterval, completion: @escaping (Result<Void, RecordError>) -> Void) {
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
        audio.markFinished()
        writer.finishWriting { [writer] in
            // writer 可能在最後一步靜默失敗（QuickRecorder SCContext.swift:352 教訓）
            if writer.status == .completed { completion(.success(())) }
            else { completion(.failure(.writerFailed(writer.error))) }
        }
    }

    /// 取消：丟掉母帶。
    /// `cancelWriting()` 對含 audio inputs 的 writer 一併拆掉（實測 probe 證實）；**不要**在此
    /// 補 `audio.markFinished()`——`markAsFinished` 是 `finishWriting` 的前置動作，不是
    /// `cancelWriting` 的，兩者不對稱。之後若被當成疏漏想「補上」，先重跑 probe 再動。
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
    /// 組裝 SCStreamConfiguration 的純函式。**nonisolated**：selftest 需從非隔離環境呼叫。
    /// 音訊相關欄位（capturesAudio／excludesCurrentProcessAudio／captureMicrophone）交給
    /// `RecordAudioTracks.configure` 統一設，不在這裡逐一列。
    nonisolated
    public static func makeStreamConfiguration(sourceRect: CGRect, pixelWidth: Int,
                                               pixelHeight: Int, options: RecordOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth        // 必設：否則縮進預設 1920×1080（CLAUDE.md）
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6                // 保留 lastSampleBuffer 佔 1 張，3 不夠（設計文件 §3）
        config.showsCursor = options.showsCursor
        RecordAudioTracks.configure(config, options: options)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }
    public var onStreamError: ((Error) -> Void)?

    /// SCK 音訊格式的實機證明（sampleRate／channels／interleaved），供 `RecordAudioSelfCheck`
    /// 記錄——這是「WriterBox 收到的 CMSampleBuffer 到底長什麼樣」的唯一觀察點，不是
    /// `RecordAudioTracks` 編碼設定（那是我們自己指定的輸出格式，不代表 SCK 實際給的輸入格式）。
    public struct AudioBufferInfo: Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let isInterleaved: Bool
    }
    public var onFirstAudioBuffer: ((AudioBufferInfo) -> Void)?

    private var stream: SCStream?
    private var pendingStop = false
    private var outputURL: URL?
    private let sampleQueue = DispatchQueue(label: "anypaint.record.frames")
    /// 只在 sampleQueue 上讀寫（同 `box` 的豁免理由：這個 handler 只在單一序列佇列上跑，
    /// 天然無競爭）。只記錄「第一個音訊格」，之後恆為 true，避免每格都重算 ASBD。
    private nonisolated(unsafe) var loggedFirstAudioBuffer = false
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

    /// 錄影期間的 HAL 麥克風來源（取代 SCK `.microphone`，見 `RecordMicSource`／設計文件 §0）。
    /// 只在 MainActor 上建立與啟停（`start`/`stopAndFinish`/`abort` 及 `start` 的清理分支）；
    /// 它的 IOProc callback 把 CMSampleBuffer 派進 `sampleQueue` → 讀 `self.box`（同 SCK handler
    /// 的既有讀法）→ `appendAudio(_:type:.microphone)`。停 stream 後、finalize 前先 `stop()` 它，
    /// 確保不再有麥克風封包灌進正在收尾的 writer。
    private var micSource: RecordMicSource?

    /// - Parameters:
    ///   - selectionGlobal: 選區（AppKit 全域座標、點、左下原點）。
    ///   - ringWindowNumber: 點擊圈視窗的 windowNumber；非 nil 時把它放進 exceptingWindows
    ///     白名單（app 整體排除、唯獨它被拍——設計文件 §3 filter）。
    ///   - excludeSelf: 是否把自家 app 整個排除在擷取外（正式流程一律 true，才不會把
    ///     選區框／HUD／點擊圈以外的自家視窗拍進母帶）。**僅內建自檢模式**傳 false——
    ///     自檢要拍的正是自家那個會動的測試視窗，其餘管線與正式流程完全相同
    ///     （比照 `ScrollFrameSource.start` 同名參數）。
    ///   - options: `showsCursor`（游標交給 SCK 畫，實戰專案一致做法）與 `useHEVC`（傳給
    ///     `WriterBox` 的 codec 選擇）的單一載體。呼叫端（`RecordSession`）顯式傳
    ///     `RecordOptions.fromSettings()`；`RecordSelfCheck` 顯式傳 `.selfCheck`（判準確定性，
    ///     不吃設定，設計文件 §1.8）。**刻意不在這裡讀 `AppSettings`**：`WriterBox` 與這個類別
    ///     都不該認識全域設定，所有選項由呼叫端決定並顯式傳入。
    ///
    /// 契約：`start()` 拋錯（TCC 拒絕、`CaptureError.noDisplays` 都是實機常見狀況）之後，
    /// 物件已經自己清乾淨（`self.box`／`self.stream`／`self.outputURL` 全部回到 nil）——
    /// 呼叫端可以直接重試，不需要先呼叫 `abort()` 才能再 `start()`。
    public func start(selectionGlobal: CGRect, screen: NSScreen,
                      ringWindowNumber: Int?, outputURL: URL,
                      excludeSelf: Bool = true, options: RecordOptions) async throws {
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
            if box == nil {
                self.outputURL = nil
                // 任何在 box 建成前就退出的路徑（早 throw、WriterBox.init 失敗、pendingStop 分支、
                // startCapture 錯誤分支都會把 self.box 設回 nil）一併收掉已開好的 HAL 麥克風 tap，
                // 不讓它孤兒佔著裝置。成功路徑 box 非 nil，這裡不碰 micSource。
                self.micSource?.stop()
                self.micSource = nil
            }
        }
        // onScreenWindowsOnly: false——點擊圈視窗是 alpha 0（純粹借位給 exceptingWindows 白名單用，
        // 不需要真的被使用者看見），`true` 只列「畫面上看得見」的視窗，alpha 0 的視窗很可能被排除在
        // 外，讓 exceptingWindows 放空、點擊圈隨整個 app 一起被排除（review 判定為真缺陷，見
        // ClickRingOverlay.prepare(near:) 的對應註解）。app 本身排除靠 `excludingApplications`
        // （bundleID 比對），不受這個參數影響，改 false 不會多拍到不該拍的視窗。
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplays
        }
        let selfApps = excludeSelf
            ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            : []
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
        let config = Self.makeStreamConfiguration(sourceRect: geo.sourceRect,
                                                   pixelWidth: geo.pixelWidth,
                                                   pixelHeight: geo.pixelHeight,
                                                   options: options)

        // 麥克風走 HAL，一律降混成 mono、mic AAC 軌固定單聲道（見 RecordMicSource）。裝置不存在／忙
        // → start() 回 false，mic 軌會是空軌、錄影照常（設計文件 §6）。
        if options.captureMicrophone {
            self.micSource = RecordMicSource(deviceID: options.microphoneDeviceID)
        }
        let boxLocal = try WriterBox(outputURL: outputURL,
                                     pixelWidth: geo.pixelWidth, pixelHeight: geo.pixelHeight,
                                     options: options)
        self.box = boxLocal
        // 麥克風 IOProc 與 startCapture **並行**啟動（不是等它之後）：這樣第一個影格錨定 writer session
        // 時麥克風已在供料，開場 A/V 偏移縮到一個 buffer 週期。session 未啟動前到達的 mic 封包由
        // `RecordAudioTracks.append` 的 `sessionStarted` gate 丟棄，安全。啟動失敗／被 pendingStop 取消
        // 的所有路徑都會把 self.box 設回 nil，觸發上面 defer 的 `micSource.stop()`，不會空轉。
        _ = self.micSource?.start(deliveringTo: boxLocal, on: sampleQueue)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
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
        // 停 HAL 麥克風。**注意**：`AudioInputTap.stop()` 是 fire-and-forget（HAL 拆卸派到背景 queue，
        // 見該檔 finding #1），**不保證**回來時 IOProc 已收手——所以仍可能有 mic 封包已排進 sampleQueue、
        // 甚至在 box.finish 之後才跑。真正的防線是 `WriterBox` 一進 finish/cancel 就設 `isTerminal=true`、
        // 每個 appendAudio 都 gate 在 `!isTerminal`（全在 sampleQueue 序列化），遲到封包被丟、不會在
        // markAsFinished 之後 append（那是不可攔的 ObjC 例外）。不要因為這裡有 stop() 就移除 isTerminal gate。
        micSource?.stop(); micSource = nil
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
        micSource?.stop(); micSource = nil   // fire-and-forget（見 stopAndFinish 說明）；遲到封包靠 isTerminal gate 擋
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
        guard type == .screen else {
            box?.appendAudio(sb, type: type)   // 音訊不帶 SCFrameStatus，不做 status gate
            if !loggedFirstAudioBuffer,
               let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                loggedFirstAudioBuffer = true
                let info = AudioBufferInfo(sampleRate: asbd.pointee.mSampleRate,
                                           channels: Int(asbd.pointee.mChannelsPerFrame),
                                           isInterleaved: (asbd.pointee.mFormatFlags
                                                           & kAudioFormatFlagIsNonInterleaved) == 0)
                // 讀 self.onFirstAudioBuffer 必須在跳進 MainActor 之後才做（同 onStreamError 的
                // 既有慣例）：這個 handler 是 nonisolated，直接在這裡讀 MainActor-isolated 的
                // stored property 是不允許的。
                Task { @MainActor [info] in self.onFirstAudioBuffer?(info) }
            }
            return
        }
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
