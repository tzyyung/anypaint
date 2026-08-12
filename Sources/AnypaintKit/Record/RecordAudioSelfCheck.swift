import AppKit
import AVFoundation
import CoreMedia

/// 內建自檢：**不需任何使用者互動**。自己用 `AVAudioSourceNode` 播一顆 440Hz 純音 → 用正式的
/// `RecordFrameSource`（`captureSystemAudio: true, excludesOwnAudio: false`）真實錄下自己的
/// 系統聲 → 讀回母帶音軌、用 `RecordMath.goertzelPower` 判定「錄到的就是自己播的 440Hz」。
/// 結構鏡射 `RecordSelfCheck`（開自家測試視窗 → 真管線 → 逐項記錄 → 寫 log → exit）。
///
/// 啟動：`open -n -a <bundle> --args --audio-selfcheck`（`-n`／`--args` 的理由見 CLAUDE.md）。
/// 結果：`/tmp/anypaint-audio-selfcheck.log`，跑完自動結束行程。
@MainActor
public final class RecordAudioSelfCheck {
    private var window: NSWindow?
    private let source = RecordFrameSource()
    private var stopTimer: Timer?
    private var lines: [String] = []
    private var screen: NSScreen?
    private var toneEngine: AVAudioEngine?

    /// 總錄製時長：440Hz 播放貫穿全程。4 秒足夠 Goertzel 在單頻上收斂，也不用等太久。
    private let totalSeconds: Double = 4.0
    private let windowSize = CGSize(width: 300, height: 200)
    private let toneSampleRate = 48000.0
    private let targetHz = 440.0
    /// 判定用的「不該有能量」對照頻率。**不用 880（440 的 2 倍頻）**：純音經 AAC 編碼／
    /// 喇叭/麥克風耦合都可能在諧波上漏一點能量，880 會讓「比值 100 倍」這個判準不穩；987 跟
    /// 440 無整數倍關係，量出來的能量更乾淨反映「這裡真的沒有訊號」（brief 指定）。
    private let offTargetHz = 987.0

    /// 比值門檻：440 的能量必須是 987 的 100 倍以上。純比值不受麥克風/系統音量影響，
    /// 可以先寫死。
    private let ratioThreshold = 100.0
    /// 絕對門檻：**以實測校準**（見 docs/animated-capture.md §7「音訊」）。
    /// 校準理由：Goertzel 對頻率誤差極敏感（439.5Hz 實測掉了六成能量——AVAudioSourceNode
    /// 的 phase 累加在 Float64 上不是嚴格 440.000Hz，加上系統聲卡重取樣），只看比值不夠——
    /// 靜音（比值算不出來，987 能量也趨近 0）時比值可能被除法雜訊撐出一個大數字。
    /// 門檻＝首次實跑（2026-08-12，本機喇叭輸出→SCK 系統聲擷取）量到的 440Hz 能量
    /// （0.17381496309072295）的 1/10，寫死。
    private let absolutePowerThreshold = 0.017_381_496_309_072_295

    public init() {}

    public func run() {
        guard let screen = NSScreen.main else { emit("FAIL 無主螢幕"); finishNow(); return }
        self.screen = screen
        let winRect = CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 120,
                             width: windowSize.width, height: windowSize.height)
        let view = NSView(frame: CGRect(origin: .zero, size: winRect.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        let w = NSWindow(contentRect: winRect, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "anypaint audio self-check"
        w.contentView = view
        w.level = .floating   // 同 RecordSelfCheck：確保自檢期間視窗在最上層
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w

        let selection = winRect.insetBy(dx: 20, dy: 20)
        emit("自檢開始 screen=\(screen.frame) window=\(winRect) selection=\(selection) scale=\(screen.backingScaleFactor)")

        source.onStreamError = { [weak self] e in
            self?.emit("FAIL stream 錯誤 \(e)")
            self?.finishNow()
        }
        source.onFirstAudioBuffer = { [weak self] info in
            self?.emit("首個音訊格 ASBD sampleRate=\(info.sampleRate) channels=\(info.channels) interleaved=\(info.isInterleaved)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-audio-selfcheck-\(UUID().uuidString).mp4")

        let engine = makeToneEngine()
        toneEngine = engine
        do {
            try engine.start()
        } catch {
            emit("FAIL 測試音源啟動失敗 \(error)")
            finishNow()
            return
        }

        // 判準確定性：captureSystemAudio true（要收系統聲）、excludesOwnAudio false（自檢要
        // 聽到自己播的檢測音，正式流程一律 true 不錄自家音效）——與 RecordOptions.selfCheck
        // 不同的固定配方，不吃 AppSettings（見 RecordOptions 頭部註解）。
        let options = RecordOptions(showsCursor: false, useHEVC: false,
                                    captureSystemAudio: true, excludesOwnAudio: false)

        Task { @MainActor in
            do {
                try await source.start(selectionGlobal: selection, screen: screen,
                                       ringWindowNumber: nil,
                                       outputURL: outputURL, excludeSelf: false,
                                       options: options)
                emit("stream 已啟動")
                armStop()
            } catch {
                emit("FAIL stream 啟動失敗 \(error)")
                engine.stop()
                finishNow()
            }
        }
    }

    /// 貫穿全程播 440Hz（0.5 振幅）的音源節點。配方出處：task-16-brief.md。
    private func makeToneEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let sr = toneSampleRate
        let targetHz = self.targetHz
        var phase = 0.0
        let node = AVAudioSourceNode { _, _, frameCount, buffers -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frameCount) {
                let v = Float32(sin(phase)) * 0.5
                phase += 2 * .pi * targetHz / sr
                for buffer in ablPointer {
                    buffer.mData?.assumingMemoryBound(to: Float32.self)[frame] = v
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        return engine
    }

    private func armStop() {
        let t = Timer(timeInterval: totalSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopAndVerify() }
        }
        RunLoop.main.add(t, forMode: .common)
        stopTimer = t
    }

    private func stopAndVerify() {
        window?.orderOut(nil)
        toneEngine?.stop()
        Task { @MainActor in
            var failures = 0
            do {
                let url = try await source.stopAndFinish()
                emit("錄製完成 url=\(url.path)")

                let asset = AVURLAsset(url: url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                // 檢查A：正好 1 條音軌（只開了系統聲，沒開麥克風）
                if audioTracks.count == 1 {
                    emit("✅ 檢查A 音軌數 實得=\(audioTracks.count) 預期=1")
                } else {
                    failures += 1
                    emit("❌ 檢查A 音軌數 實得=\(audioTracks.count) 預期=1")
                }

                if let track = audioTracks.first {
                    let (samples, sampleRate) = try decodeMonoSamples(track: track, asset: asset)
                    emit("解碼樣本數=\(samples.count) sampleRate=\(sampleRate)")

                    let power440 = RecordMath.goertzelPower(samples: samples, sampleRate: sampleRate,
                                                            targetHz: targetHz)
                    let powerOff = RecordMath.goertzelPower(samples: samples, sampleRate: sampleRate,
                                                            targetHz: offTargetHz)
                    emit("goertzel power440=\(power440) power987=\(powerOff) 比值=\(powerOff > 0 ? power440 / powerOff : -1)")

                    // 檢查B：440 的能量遠高於 987（比值門檻），且過絕對門檻（排除「兩者都趨近
                    // 0」讓比值失去意義的退化情況——例如完全靜音時 987 的能量也接近 0）。
                    let ratioOK = power440 > powerOff * ratioThreshold
                    let absoluteOK = power440 > absolutePowerThreshold
                    if ratioOK && absoluteOK {
                        emit("✅ 檢查B Goertzel 判定 power440=\(power440) (>\(absolutePowerThreshold)) power987=\(powerOff) 比值門檻=\(ratioThreshold)x")
                    } else {
                        failures += 1
                        emit("❌ 檢查B Goertzel 判定 power440=\(power440) power987=\(powerOff) ratioOK=\(ratioOK) absoluteOK=\(absoluteOK)")
                    }
                } else {
                    failures += 1
                    emit("❌ 檢查B 無音軌可解碼")
                }

                try? FileManager.default.removeItem(at: url)
            } catch {
                failures += 1
                emit("❌ 錄製收檔或解碼失敗 \(error)")
            }
            emit(failures == 0 ? "---- 全部通過 ----" : "---- 有 \(failures) 項失敗 ----")
            finishNow(exitCode: failures == 0 ? 0 : 1)
        }
    }

    /// `AVAssetReader` + LPCM float 輸出設定解碼音軌（brief 指定：不用 `AVAssetReader` 讀原始
    /// 編碼資料自己解，交給 AVFoundation 內部的 audio converter 轉成 Float32）。
    /// **deinterleave 選擇：混平均**（不是取單一聲道）——`RecordAudioTracks` 寫入時一律是
    /// 2 聲道（`AVNumberOfChannelsKey: 2`），測試音源左右聲道內容相同（`makeToneEngine` 對
    /// `ablPointer` 每個 buffer 都寫一樣的值），混平均與取任一聲道理論上等價，但混平均對
    ///「未來若聲道內容不同」更穩健（不會因為挑錯聲道漏掉訊號），成本可忽略。
    private func decodeMonoSamples(track: AVAssetTrack, asset: AVAsset) throws -> (samples: [Float], sampleRate: Double) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RecordAudioSelfCheckError.readerFailed(reader.error)
        }
        defer { reader.cancelReading() }   // 全程同一顆 Task，非跨執行緒呼叫（同 GifExporter 紀律）

        var mono: [Float] = []
        var sampleRate = toneSampleRate
        var channels = 2
        while let sb = output.copyNextSampleBuffer() {
            if let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                sampleRate = asbd.pointee.mSampleRate
                channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [UInt8](repeating: 0, count: length)
            let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress!)
            }
            guard status == noErr else { continue }
            data.withUnsafeBytes { raw in
                let floatBuf = raw.bindMemory(to: Float32.self)
                var i = 0
                while i + channels <= floatBuf.count {
                    var sum: Float = 0
                    for c in 0..<channels { sum += floatBuf[i + c] }
                    mono.append(sum / Float(channels))
                    i += channels
                }
            }
        }
        if reader.status == .failed {
            throw RecordAudioSelfCheckError.readerFailed(reader.error)
        }
        return (mono, sampleRate)
    }

    private func emit(_ s: String) {
        lines.append(s)
        try? lines.joined(separator: "\n").write(toFile: "/tmp/anypaint-audio-selfcheck.log",
                                                 atomically: true, encoding: .utf8)
    }

    private func finishNow(exitCode: Int32 = 1) {
        window?.orderOut(nil)
        toneEngine?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(exitCode) }
    }
}

enum RecordAudioSelfCheckError: Error {
    case readerFailed(Error?)
}
