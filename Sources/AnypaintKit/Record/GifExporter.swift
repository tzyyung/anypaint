import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 匯出格式：GIF（256 色調色盤、cs 累計捨入 delay）與 APNG（全彩、秒級 delay，設計文件 §1.5）。
public enum AnimationFormat {
    case gif
    case apng

    /// 存檔副檔名——APNG 就是 `.png`（沒有獨立的 apng 副檔名慣例，聊天軟體與作業系統都認 .png）。
    public var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .apng: return "png"
        }
    }
}

/// GIF 引擎選擇（設計文件 §1.7）。`.auto`：format 為 `.gif` 且偵測到外部 gifski → 走子程序高品質
/// 路徑，任何失敗回退 `.builtin`；APNG 格式或找不到 gifski 一律等同 `.builtin`。
/// 自檢顯式傳 `.builtin`——判準要確定性，不能被「這台機器裝了沒裝 gifski」影響（RecordSelfCheck）。
public enum GifEngine {
    case auto
    case builtin
}

/// gifski/img2webp 這類外部子程序失敗回退時的一行式診斷（同 ScrollSessionLog 的 append 慣例，
/// 設計文件 §1.7）。內容極精簡（時間戳＋原因），只在失敗路徑觸發，非熱路徑、無效能影響。
enum RecordSessionLog {
    static let path = "/tmp/anypaint-record-session.log"
    static func add(_ line: String) {
        guard let data = "\(Date()) \(line)\n".data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 母帶 MP4 → GIF/APNG。AVAssetReader 循序解碼（不用 AVAssetImageGenerator——精準 seek 慢，
/// Gifski.app 已遷移）；sample-and-hold；1x 點尺寸；CGImageDestination 依格式分別累計捨入
/// （GIF）或秒值直接寫（APNG，設計文件 §1.5）。
/// GIF 品質上限自覺（設計文件 §6.5）：ImageIO 單一全域調色盤、無時域抖色——UI 內容可接受。
/// APNG 全彩無此限制，但非通用貼圖格式（聊天軟體支援度不一），因此與 GIF 並存而非取代。
/// 外部 gifski 引擎（設計文件 §1.7）在 GIF 上不受這個限制——`engine: .auto` 時偵測到就優先走它。
///
/// 全程 async、單一 `Task.detached`：`asset.duration`／`tracks(withMediaType:)`／
/// `track.naturalSize` 這些同步 API 在近期 SDK 已標 deprecated，一律改用 `load(...)` async 版本
/// （零 warning 是硬約束）。reader 的循序讀取（`copyNextSampleBuffer`）與收尾（`cancelReading`）
/// 全部留在同一顆 async 函式裡執行——中途唯一的暫停點是節流過的 `await progress(...)`，
/// 期間沒有第二個 Task 會同時碰這個 reader。Gifski.app 原註解警告的是「跨執行緒呼叫
/// `cancelReading` 觸發 MediaToolbox EXC_BAD_ACCESS」，真正的風險是**並發存取**，不是
/// 「實體 OS 執行緒編號是否相同」——這裡全程序列化（await 只是暫停，不是另開一顆 Task
/// 平行碰 reader），因此仍滿足同一份紀律。
public enum GifExporter {
    /// - Parameters:
    ///   - fps: 目標 fps。**無預設值**——呼叫端必須顯式表態（設計文件 §1.2：GIF fps 設定項
    ///     上線後，所有呼叫端都要讀 `AppSettings.recordGifFps` 或（自檢）顯式常數，不能悄悄
    ///     沿用舊的隱式 12）。
    ///   - format: 輸出格式，預設 `.gif`（舊呼叫端不用改）。
    ///   - timeRange: 非 nil 時只匯出這段範圍（剪裁，T6 消費）；nil＝整段母帶（行為不變）。
    ///   - engine: `.auto`（預設，舊呼叫端不用改）在 GIF 上會嘗試外部 gifski、失敗回退內建；
    ///     `.builtin` 略過偵測，直接走 CGImageDestination（RecordSelfCheck 用，判準確定性）。
    public static func export(movieURL: URL, to outURL: URL, pointScale: CGFloat,
                              fps: Double,
                              format: AnimationFormat = .gif,
                              timeRange: CMTimeRange? = nil,
                              engine: GifEngine = .auto,
                              progress: @escaping @MainActor (Double) -> Void,
                              completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                // 選引擎放在最外層 do/catch 內：gifski 失敗 fallthrough 到內建，兩條路徑共用
                // 同一個 completion——確定只發一次（設計文件 §1.7）。
                if format == .gif, engine == .auto, let gifskiPath = GifskiEngine.detect() {
                    do {
                        try await exportViaGifski(movieURL: movieURL, to: outURL, pointScale: pointScale,
                                                  fps: fps, timeRange: timeRange, gifskiPath: gifskiPath,
                                                  progress: progress)
                        await completion(.success(()))
                        return
                    } catch {
                        RecordSessionLog.add("gifski 失敗（\(error)），回退內建編碼器 movieURL=\(movieURL.lastPathComponent)")
                    }
                }
                try await exportAsync(movieURL: movieURL, to: outURL, pointScale: pointScale,
                                      fps: fps, format: format, timeRange: timeRange, progress: progress)
                await completion(.success(()))
            } catch {
                await completion(.failure(error))
            }
        }
    }

    /// 內建 CGImageDestination 路徑（GIF 與 APNG 共用）；行為與重構前完全一致——這是回歸網
    /// （RecordSelfCheck 顯式走 `.builtin`）。
    private static func exportAsync(movieURL: URL, to outURL: URL, pointScale: CGFloat,
                                    fps: Double, format: AnimationFormat, timeRange: CMTimeRange?,
                                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let plan = try await prepareReader(movieURL: movieURL, pointScale: pointScale,
                                           fps: fps, timeRange: timeRange)

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                         format.utType.identifier as CFString,
                                                         plan.grid.count, nil) else {
            plan.reader.cancelReading()
            throw RecordError.writerFailed(nil)
        }
        CGImageDestinationSetProperties(dest, format.containerProperties as CFDictionary)
        let perFrameProperties = format.perFrameProperties(delaysSeconds:
            format == .gif
                ? RecordMath.gifDelaysCentiseconds(frameStartTimes: plan.grid, duration: plan.duration).map { Double($0) / 100.0 }
                : RecordMath.apngDelaysSeconds(frameStartTimes: plan.grid, duration: plan.duration))

        try await decodeLoop(plan: plan, progress: progress) { gridIndex, image in
            CGImageDestinationAddImage(dest, image, perFrameProperties[gridIndex] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw RecordError.writerFailed(nil) }
    }

    /// gifski 路徑（僅 GIF）：抽格寫 PNG 到暫存目錄 → 呼叫 gifski 子程序組 GIF → 成功即刪
    /// frames 目錄。任何失敗（reader 中途壞掉、gifski spawn/exit≠0/無輸出檔）一律 throw，
    /// 讓 `export` 接手回退內建；frames 目錄一律 `defer` 刪，不論成功或失敗
    /// （殘留另有啟動清掃兜底，`anypaint-record-` 前綴）。
    /// 進度切兩段：抽格 0→0.7，gifski 子程序 0.7→1.0（完成時跳滿，設計文件 §1.7）。
    private static func exportViaGifski(movieURL: URL, to outURL: URL, pointScale: CGFloat,
                                        fps: Double, timeRange: CMTimeRange?, gifskiPath: String,
                                        progress: @escaping @MainActor (Double) -> Void) async throws {
        let framesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-record-frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: framesDir) }
        let (plan, framePaths) = try await extractFramesAsPNG(movieURL: movieURL, pointScale: pointScale,
                                                               fps: fps, timeRange: timeRange,
                                                               framesDir: framesDir,
                                                               progress: { done in progress(done * 0.7) })

        try GifskiEngine.run(gifskiPath: gifskiPath,
                             arguments: GifskiEngine.arguments(fps: Int(fps.rounded()), quality: 90,
                                                               width: plan.outW,
                                                               output: outURL.path, frames: framePaths))
        await progress(1.0)
    }

    /// WebP 匯出（img2webp 子程序，設計文件 §1.7b）。**沒有回退**——呼叫端（`RecordPreviewWindow`）
    /// 只在偵測到 img2webp 時才顯示「存 WebP」鈕、才會呼叫這裡；失敗直接丟給呼叫端顯示錯誤，
    /// 不像 `export(...)` 的 gifski 路徑那樣 catch 起來走內建編碼器——沒有內建 WebP 編碼器可退
    /// （這台機器 `CGImageDestinationCopyTypeIdentifiers()` 不含 webp，實測見任務報告）。
    /// 抽格管線與 gifski 共用（`extractFramesAsPNG`）；進度切兩段，同 gifski 路徑的道理。
    public static func exportWebP(movieURL: URL, to outURL: URL, pointScale: CGFloat, fps: Double,
                                  timeRange: CMTimeRange? = nil,
                                  img2webpPath: String,
                                  progress: @escaping @MainActor (Double) -> Void,
                                  completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                try await exportViaImg2webp(movieURL: movieURL, to: outURL, pointScale: pointScale,
                                            fps: fps, timeRange: timeRange, img2webpPath: img2webpPath,
                                            progress: progress)
                await completion(.success(()))
            } catch {
                RecordSessionLog.add("img2webp 失敗（\(error)）movieURL=\(movieURL.lastPathComponent)")
                await completion(.failure(error))
            }
        }
    }

    /// img2webp 路徑本體：抽格寫 PNG → 呼叫 img2webp 子程序組 WebP → frames 目錄一律 `defer` 刪。
    /// delay 用 grid 的固定 fps 換算成 ms（`RecordMath.gridTimes` 產生的是等間隔格，設計文件
    /// §1.7b：均勻 fps → 等長 delay，不必逐格算——所有格給同一個值，`Img2webpEngine.arguments`
    /// 會自動摺疊成單一 `-d`）。
    private static func exportViaImg2webp(movieURL: URL, to outURL: URL, pointScale: CGFloat,
                                          fps: Double, timeRange: CMTimeRange?, img2webpPath: String,
                                          progress: @escaping @MainActor (Double) -> Void) async throws {
        let framesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-record-frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: framesDir) }
        let (_, framePaths) = try await extractFramesAsPNG(movieURL: movieURL, pointScale: pointScale,
                                                            fps: fps, timeRange: timeRange,
                                                            framesDir: framesDir,
                                                            progress: { done in progress(done * 0.7) })

        let delayMs = Int((1000.0 / fps).rounded())
        try Img2webpEngine.run(img2webpPath: img2webpPath,
                               arguments: Img2webpEngine.arguments(
                                   delaysMs: Array(repeating: delayMs, count: framePaths.count),
                                   frames: framePaths, output: outURL.path))
        await progress(1.0)
    }

    /// 抽格寫 PNG 到暫存目錄（gifski／img2webp 兩條外部子程序路徑共用；「先抽 PNG 再丟外部工具」
    /// 是同一套管線，抽格本體只留一份，兩個引擎各自只補上自己的子程序呼叫與引數）。
    /// 呼叫端負責建立/清理 `framesDir`（`defer` 放在呼叫端，這裡只管抽格寫檔）。
    /// 真正的排序保證是 `framePaths` 陣列本身的順序（呼叫端依這個陣列順序把檔案交給
    /// gifski／img2webp）；零填充（frame-000001.png…）只是防外部工具自己重新掃描目錄、
    /// 依檔名字典序排列時被弄亂的保險。6 位數：不限時長的錄製理論上可超過 9999 格。
    private static func extractFramesAsPNG(movieURL: URL, pointScale: CGFloat, fps: Double,
                                           timeRange: CMTimeRange?, framesDir: URL,
                                           progress: @escaping @MainActor (Double) -> Void)
        async throws -> (plan: FramePlan, framePaths: [String]) {
        let plan = try await prepareReader(movieURL: movieURL, pointScale: pointScale,
                                           fps: fps, timeRange: timeRange)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        var framePaths: [String] = []
        framePaths.reserveCapacity(plan.grid.count)
        try await decodeLoop(plan: plan, progress: progress) { gridIndex, image in
            let path = framesDir.appendingPathComponent(String(format: "frame-%06d.png", gridIndex)).path
            try writePNG(image, to: path)
            framePaths.append(path)
        }
        return (plan, framePaths)
    }

    /// 單張 CGImage → PNG 檔（gifski 路徑逐格寫檔用）。
    private static func writePNG(_ image: CGImage, to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            throw RecordError.writerFailed(nil)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RecordError.writerFailed(nil) }
    }

    /// 兩條下游（內建 CGImageDestinationAddImage／gifski 寫 PNG）共用的素材：載入 asset／track、
    /// 設好 reader（含 timeRange clamp、rangeStartSeconds 歸零）、算好 grid 與輸出點尺寸。
    /// reader 已 `startReading()`，呼叫端負責之後接 `decodeLoop`。
    private struct FramePlan {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let grid: [Double]
        let duration: Double
        let rangeStartSeconds: Double
        let outW: Int
        let outH: Int
    }

    private static func prepareReader(movieURL: URL, pointScale: CGFloat, fps: Double,
                                      timeRange: CMTimeRange?) async throws -> FramePlan {
        let asset = AVURLAsset(url: movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw RecordError.noFrames }
        // duration 與 naturalSize 互不相依，並行載入省一輪往返。
        async let durationLoad = asset.load(.duration)
        async let naturalSizeLoad = track.load(.naturalSize)
        let assetDuration = try await durationLoad.seconds
        let naturalSize = try await naturalSizeLoad

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // AVAssetReader.h（已查）：「This property throws an exception if a value is set
        // after reading has started」——timeRange 必須在 startReading() 之前設。
        // rangeStartSeconds：reader 在 timeRange 限制下吐出的樣本 PTS 仍是**整支母帶**的時間軸
        // （timeRange 只是篩選讀哪一段，不會把 PTS 重新歸零），但下面的 grid／sample-and-hold
        // 全部假設「首格 PTS 對應時間 0」——兩者對不上就會整段跟著剪裁範圍平移，因此在
        // decodeNext 讀出當下立刻減去 rangeStartSeconds 歸零（見下方 decodeNext 呼叫處）。
        let rangeStartSeconds: Double
        let duration: Double
        if let timeRange {
            reader.timeRange = timeRange
            rangeStartSeconds = timeRange.start.seconds
            // clamp：AVAssetReader.h 對 timeRange 的說明是「與 [0, asset 實際時長] 取交集後」才是
            // 真正讀取的範圍——呼叫端傳進超出母帶尾端的請求範圍不會報錯，只會默默少讀，但這裡的
            // duration 若不clamp，grid／delay 計算會以「請求的長度」為準，吐出一支比實際內容
            // 更長（尾端補靜止格）的動畫。故取 min(請求長度, 母帶時長-範圍起點)。
            duration = min(timeRange.duration.seconds, assetDuration - rangeStartSeconds)
        } else {
            rangeStartSeconds = 0
            duration = assetDuration
        }
        reader.startReading()

        let grid = RecordMath.gridTimes(duration: duration, fps: fps)
        let pxW = Int(naturalSize.width), pxH = Int(naturalSize.height)
        let outW = max(1, Int((CGFloat(pxW) / pointScale).rounded()))
        let outH = max(1, Int((CGFloat(pxH) / pointScale).rounded()))
        return FramePlan(reader: reader, output: output, grid: grid, duration: duration,
                         rangeStartSeconds: rangeStartSeconds, outW: outW, outH: outH)
    }

    /// 逐格解碼＋sample-and-hold：對每個 grid index 依序呼叫一次 `onFrame`（同步、可 throw）；
    /// 呼叫端只需決定「格產出後要做什麼」（內建直接 AddImage；gifski 寫 PNG 檔），解碼／縮圖／
    /// reader 收尾的邏輯只有一份。`reader.cancelReading()` 在函式結束時呼叫——全程同一顆 async
    /// 函式、無並發存取（見上方型別註解）。
    private static func decodeLoop(plan: FramePlan,
                                   progress: @escaping @MainActor (Double) -> Void,
                                   onFrame: (Int, CGImage) throws -> Void) async throws {
        defer { plan.reader.cancelReading() }

        // 線上 sample-and-hold：與 RecordMath.sampleHoldIndices 同構的「解碼超前一格」寫法——
        // `current` 對應該函式的 sourceTimes[src]，`next` 對應 sourceTimes[src+1]（若存在）。
        // 純函式的內迴圈「while src+1<count && sourceTimes[src+1]<=t { src+=1 }」在這裡就是
        // 下面的「while let n = next, n.pts <= target { current = n; next = decodeNext() }」——
        // 兩者逐字對應；行為若歧異，以純函式（Task 1 已 selftest）為準（設計文件 §6）。
        guard var current = decodeNext(from: plan.output, width: plan.outW, height: plan.outH,
                                       rangeStartSeconds: plan.rangeStartSeconds) else {
            // 首格就拿不到：跟主迴圈結尾同一套判準——reader 已經 .failed 代表母帶讀到一半
            // （這裡是一開始）就壞了，不是「真的沒有格」，兩者要分開回報。
            if plan.reader.status == .failed { throw RecordError.writerFailed(plan.reader.error) }
            throw RecordError.noFrames
        }
        var next = decodeNext(from: plan.output, width: plan.outW, height: plan.outH,
                              rangeStartSeconds: plan.rangeStartSeconds)

        // 進度節流：格數可能上百，逐格 hop 進 MainActor 太浪費——每 5%（至少每 10 格）才 await 一次；
        // 最後一格永遠補送，確保呼叫端收得到 1.0（gifski 路徑會再疊上自己的 0.7 上限，見呼叫處）。
        let progressStep = max(10, plan.grid.count / 20)
        for gridIndex in plan.grid.indices {
            let target = plan.grid[gridIndex]
            while let n = next, n.pts <= target {
                current = n
                next = decodeNext(from: plan.output, width: plan.outW, height: plan.outH,
                                  rangeStartSeconds: plan.rangeStartSeconds)
            }
            try onFrame(gridIndex, current.image)
            if gridIndex % progressStep == 0 || gridIndex == plan.grid.count - 1 {
                let done = Double(gridIndex + 1) / Double(plan.grid.count)
                // 這個 await 同時是 cooperative thread pool 的讓出點：拿掉節流、改成每格都
                // await，CPU-bound 的解碼／縮圖迴圈會長時間佔住 pool thread 不放手；反過來
                // 若把節流拿掉去「優化」成完全不 await，這條 Task 就再也不會讓出，等於堵住
                // 這顆 pool thread 直到匯出完成——節流是兩者的折衷，不是可有可無的效能微調。
                await progress(done)
            }
        }
        // AVAssetReader.h：copyNextSampleBuffer() 回 nil 之後必須查 status 才能分辨「真的讀完」
        // 還是「讀到一半失敗」——先前這裡完全沒查，母帶中途損毀（例如錄影當掉留下的截斷檔）會讓
        // reader 轉 .failed，上面的迴圈卻只看到 decodeNext 回 nil、當成「這段期間畫面靜止」，
        // 靜默拿 current 補滿剩餘所有 grid 格，最後 CGImageDestinationFinalize 照樣成功、
        // completion(.success(()))——吐出一支大半凍結、看起來正常但其實漏掉損毀點之後內容的 GIF。
        // 損毀與「壞格跳過」（decodeNext 內部續讀）是兩件事，這裡分開處理：壞格不中斷整段匯出，
        // reader 真的死亡則必須讓呼叫端知道。
        if plan.reader.status == .failed {
            throw RecordError.writerFailed(plan.reader.error)
        }
    }

    /// 循序讀下一格已解碼影像（BGRA → 縮到 1x 點尺寸的 CGImage）；EOF 或讀取錯誤回 nil。
    /// 解不出影像的壞格直接跳過繼續讀（不中斷整段匯出）。
    ///
    /// 每一格來源（包括之後會被下一格取代、其實用不到的那些靜止期中間格）都在讀出當下立刻
    /// `downscaled(...)`，不能延後到「確定會用到」才轉——`output.alwaysCopiesSampleData = false`
    /// 表示 sample buffer 背後的記憶體是 reader 內部緩衝區的借用，`copyNextSampleBuffer()`
    /// 下一次呼叫就可能回收；留著 `CMSampleBuffer`／`CVPixelBuffer` 等下一輪才讀是 use-after-free。
    ///
    /// `rangeStartSeconds`：timeRange 剪裁時 reader 吐出的 PTS 仍是整支母帶的絕對時間軸，這裡
    /// 減掉範圍起點歸零，讓回傳的 `pts` 與呼叫端從 0 起算的 `grid` 對得上（見 exportAsync 的說明）。
    private static func decodeNext(from output: AVAssetReaderTrackOutput,
                                   width: Int, height: Int,
                                   rangeStartSeconds: Double) -> (image: CGImage, pts: Double)? {
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds - rangeStartSeconds
            if let pb = CMSampleBufferGetImageBuffer(sb),
               let img = downscaled(pb, width: width, height: height) {
                return (img, pts)
            }
        }
        return nil
    }

    /// BGRA CVPixelBuffer → 縮到目標尺寸的 CGImage（1x 點尺寸；Retina 2x 檔案爆炸——設計文件 §6.3）。
    private static func downscaled(_ pb: CVPixelBuffer, width: Int, height: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let srcCtx = CGContext(data: base,
                               width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let full = srcCtx?.makeImage() else { return nil }
        let dstCtx = CGContext(data: nil, width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue)
        dstCtx?.interpolationQuality = .medium
        dstCtx?.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return dstCtx?.makeImage()
    }
}

/// 格式相依的 UTType／properties 組裝，跟解碼／縮圖／sample-and-hold 等共用邏輯分開放，
/// 讓 `exportAsync` 本體不必為兩種格式各寫一份迴圈。
// public：utType/containerProperties/perFrameProperties 是純格式對應（GIF/APNG 的
// loop-count／delay dictionary），開放給 selftest 直接驗證「格式→正確 ImageIO 屬性」。
public extension AnimationFormat {
    var utType: UTType {
        switch self {
        case .gif: return .gif
        case .apng: return .png
        }
    }

    /// 檔案層級屬性：兩種格式都是「無限循環」，只是 dictionary key 不同
    /// （已查 ImageIO header `CGImageProperties.h`：`kCGImagePropertyAPNGLoopCount`／
    /// `kCGImagePropertyAPNGDelayTime`／`kCGImagePropertyAPNGUnclampedDelayTime` 都在
    /// `kCGImagePropertyPNGDictionary` 底下——註解在該檔案第 276 行「Possible keys for
    /// kCGImagePropertyPNGDictionary」，與設計文件 §1.5 的描述一致）。
    var containerProperties: [CFString: Any] {
        switch self {
        case .gif:
            return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        case .apng:
            return [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        }
    }

    /// 每一格要傳給 `CGImageDestinationAddImage` 的 properties dict，逐格對應 `delaysSeconds`。
    /// GIF 呼叫端傳入的是「cs 累計捨入後換算回秒」的值（沿用既有規則，不改行為）；
    /// APNG 呼叫端傳入 `RecordMath.apngDelaysSeconds` 的秒值（無 cs 捨入，設計文件 §1.5）。
    func perFrameProperties(delaysSeconds: [Double]) -> [[CFString: Any]] {
        switch self {
        case .gif:
            return delaysSeconds.map {
                [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: $0,
                    kCGImagePropertyGIFUnclampedDelayTime: $0,
                ]]
            }
        case .apng:
            return delaysSeconds.map {
                [kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: $0,
                    kCGImagePropertyAPNGUnclampedDelayTime: $0,
                ]]
            }
        }
    }
}
