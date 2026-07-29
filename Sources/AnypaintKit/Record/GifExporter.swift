import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 母帶 MP4 → GIF。AVAssetReader 循序解碼（不用 AVAssetImageGenerator——精準 seek 慢，
/// Gifski.app 已遷移）；12fps sample-and-hold；1x 點尺寸；CGImageDestination 累計捨入 delay。
/// 品質上限自覺（設計文件 §6.5）：ImageIO 單一全域調色盤、無時域抖色——UI 內容可接受。
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
    public static func export(movieURL: URL, to gifURL: URL, pointScale: CGFloat,
                              fps: Double = 12,
                              progress: @escaping @MainActor (Double) -> Void,
                              completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                try await exportAsync(movieURL: movieURL, to: gifURL,
                                      pointScale: pointScale, fps: fps, progress: progress)
                await completion(.success(()))
            } catch {
                await completion(.failure(error))
            }
        }
    }

    private static func exportAsync(movieURL: URL, to gifURL: URL, pointScale: CGFloat,
                                    fps: Double,
                                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw RecordError.noFrames }
        // duration 與 naturalSize 互不相依，並行載入省一輪往返。
        async let durationLoad = asset.load(.duration)
        async let naturalSizeLoad = track.load(.naturalSize)
        let duration = try await durationLoad.seconds
        let naturalSize = try await naturalSizeLoad

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }   // 全程同一顆 async 函式、無並發存取（見上方型別註解）

        let grid = RecordMath.gridTimes(duration: duration, fps: fps)
        let delays = RecordMath.gifDelaysCentiseconds(frameStartTimes: grid, duration: duration)
        let pxW = Int(naturalSize.width), pxH = Int(naturalSize.height)
        let outW = max(1, Int((CGFloat(pxW) / pointScale).rounded()))
        let outH = max(1, Int((CGFloat(pxH) / pointScale).rounded()))

        guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         grid.count, nil) else {
            throw RecordError.writerFailed(nil)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],   // 0 = 無限循環
        ] as CFDictionary)

        // 線上 sample-and-hold：與 RecordMath.sampleHoldIndices 同構的「解碼超前一格」寫法——
        // `current` 對應該函式的 sourceTimes[src]，`next` 對應 sourceTimes[src+1]（若存在）。
        // 純函式的內迴圈「while src+1<count && sourceTimes[src+1]<=t { src+=1 }」在這裡就是
        // 下面的「while let n = next, n.pts <= target { current = n; next = decodeNext() }」——
        // 兩者逐字對應；行為若歧異，以純函式（Task 1 已 selftest）為準（設計文件 §6）。
        guard var current = decodeNext(from: output, width: outW, height: outH) else {
            // 首格就拿不到：跟主迴圈結尾同一套判準——reader 已經 .failed 代表母帶讀到一半
            // （這裡是一開始）就壞了，不是「真的沒有格」，兩者要分開回報。
            if reader.status == .failed { throw RecordError.writerFailed(reader.error) }
            throw RecordError.noFrames
        }
        var next = decodeNext(from: output, width: outW, height: outH)

        // 進度節流：格數可能上百，逐格 hop 進 MainActor 太浪費——每 5%（至少每 10 格）才 await 一次；
        // 最後一格永遠補送，確保呼叫端收得到 1.0。
        let progressStep = max(10, grid.count / 20)
        for gridIndex in grid.indices {
            let target = grid[gridIndex]
            while let n = next, n.pts <= target {
                current = n
                next = decodeNext(from: output, width: outW, height: outH)
            }
            CGImageDestinationAddImage(dest, current.image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: Double(delays[gridIndex]) / 100.0,
                    kCGImagePropertyGIFUnclampedDelayTime: Double(delays[gridIndex]) / 100.0,
                ],
            ] as CFDictionary)
            if gridIndex % progressStep == 0 || gridIndex == grid.count - 1 {
                let done = Double(gridIndex + 1) / Double(grid.count)
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
        if reader.status == .failed {
            throw RecordError.writerFailed(reader.error)
        }
        guard CGImageDestinationFinalize(dest) else { throw RecordError.writerFailed(nil) }
    }

    /// 循序讀下一格已解碼影像（BGRA → 縮到 1x 點尺寸的 CGImage）；EOF 或讀取錯誤回 nil。
    /// 解不出影像的壞格直接跳過繼續讀（不中斷整段匯出）。
    ///
    /// 每一格來源（包括之後會被下一格取代、其實用不到的那些靜止期中間格）都在讀出當下立刻
    /// `downscaled(...)`，不能延後到「確定會用到」才轉——`output.alwaysCopiesSampleData = false`
    /// 表示 sample buffer 背後的記憶體是 reader 內部緩衝區的借用，`copyNextSampleBuffer()`
    /// 下一次呼叫就可能回收；留著 `CMSampleBuffer`／`CVPixelBuffer` 等下一輪才讀是 use-after-free。
    private static func decodeNext(from output: AVAssetReaderTrackOutput,
                                   width: Int, height: Int) -> (image: CGImage, pts: Double)? {
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if let pb = CMSampleBufferGetImageBuffer(sb),
               let img = downscaled(pb, width: width, height: height) {
                return (img, pts)
            }
        }
        return nil
    }

    /// BGRA CVPixelBuffer → 縮到目標尺寸的 CGImage（1x 點尺寸；Retina 2x GIF 檔案爆炸——設計文件 §6.3）。
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
