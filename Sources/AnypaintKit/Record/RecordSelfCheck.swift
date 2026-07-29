import AppKit
import AVFoundation

/// 內建自檢：**不需任何使用者互動**，自己開一個「內容會程式化變化的視窗」→ 用正式的
/// `RecordFrameSource` 真實錄製 → 讀回母帶驗證時長／可播 → 用正式的 `GifExporter` 匯出 →
/// 驗證格數／尺寸。逐項記錄結果。
///
/// 存在理由：動畫截圖的失效多半發生在「SCStream 真實供格 → WriterBox 補尾格 → GifExporter
/// 讀回」這條接縫上，selftest 的純函式測不到（沒有真實擷取／編碼/解碼），而每次都請使用者
/// 手動操作又太慢。這支自檢把那段接縫變成可重複執行的自動驗證（鏡射
/// `ScrollCaptureSelfCheck` 的結構：開自家測試視窗 → 真管線 → 逐項記錄 → 寫 log → exit）。
///
/// 啟動：`open -n -a <bundle> --args --record-selfcheck`（`-n`／`--args` 的理由見 CLAUDE.md）。
/// 結果：`/tmp/anypaint-record-selfcheck.log`，跑完自動結束行程。
///
/// 與正式流程的唯一差異：`excludeSelf: false`（自檢要拍的正是自家測試視窗）。
/// 其餘（filter/sourceRect 座標鏈/queueDepth/WriterBox 補尾格/GifExporter 取樣）完全相同。
@MainActor
public final class RecordSelfCheck {
    private var window: NSWindow?
    private var content: SelfCheckRecordContentView?
    private let source = RecordFrameSource()
    private var updateTimer: Timer?
    private var stopTimer: Timer?
    private var updates = 0
    private var lines: [String] = []
    // 存成 ivar 而非透過 Timer 閉包傳遞：NSScreen 不是 Sendable，捕進 @Sendable 閉包會警告
    // （零 warning 是硬約束）。這裡改成閉包只捕 self（弱引用），實際值一律讀 self 的 ivar。
    private var screen: NSScreen?

    /// 總錄製時長（wall-clock，秒）。最後 `staticTailSeconds` 秒完全靜止，用來驗證
    /// 「尾格補齊」（WriterBox.finish 的 needsTailFrame 邏輯）真的生效——若沒生效，
    /// 檔案時長會停在最後一次內容變化的時間點，明顯短於 6 秒。
    private let totalSeconds: Double = 6.0
    private let staticTailSeconds: Double = 2.0
    private let updateInterval: Double = 0.1
    private let windowSize = CGSize(width: 400, height: 300)

    public init() {}

    public func run() {
        guard let screen = NSScreen.main else { emit("FAIL 無主螢幕"); finishNow(); return }
        self.screen = screen
        let winRect = CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 120,
                             width: windowSize.width, height: windowSize.height)
        let view = SelfCheckRecordContentView(frame: CGRect(origin: .zero, size: winRect.size))
        let w = NSWindow(contentRect: winRect, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "anypaint record self-check"
        w.contentView = view
        // .floating：確保自檢期間這個視窗在最上層，不然擷取到的是蓋在上面的別的視窗
        // （同 ScrollCaptureSelfCheck 的教訓）。
        w.level = .floating
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w
        content = view

        // 選區＝視窗內容區往內縮 20pt（避開標題列與邊緣），遠大於 RecordSession.minSelectionEdgePt。
        let selection = winRect.insetBy(dx: 20, dy: 20)
        emit("自檢開始 screen=\(screen.frame) window=\(winRect) selection=\(selection) scale=\(screen.backingScaleFactor)")

        source.onStreamError = { [weak self] e in
            self?.emit("FAIL stream 錯誤 \(e)")
            self?.finishNow()
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-record-selfcheck-\(UUID().uuidString).mp4")

        Task { @MainActor in
            do {
                try await source.start(selectionGlobal: selection, screen: screen,
                                       showsCursor: true, ringWindowNumber: nil,
                                       outputURL: outputURL, excludeSelf: false,
                                       useHEVC: false)   // 判準確定性，不吃設定（設計文件 §1.8）
                emit("stream 已啟動")
                startContentUpdates()
                armStop()
            } catch {
                emit("FAIL stream 啟動失敗 \(error)")
                finishNow()
            }
        }
    }

    /// 每 100ms 變一次內容（遞增數字），持續到「總時長 − 靜止尾段」為止，之後不再變動，
    /// 讓錄到的母帶結尾真的是靜止畫面（測試 WriterBox 的補尾格）。
    private func startContentUpdates() {
        let t = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    private func tick() {
        let activeSeconds = totalSeconds - staticTailSeconds
        let elapsed = Double(updates) * updateInterval
        guard elapsed < activeSeconds else {
            updateTimer?.invalidate(); updateTimer = nil
            return
        }
        updates += 1
        content?.number = updates
        content?.needsDisplay = true
    }

    private func armStop() {
        let t = Timer(timeInterval: totalSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopAndVerify() }
        }
        RunLoop.main.add(t, forMode: .common)
        stopTimer = t
    }

    private func stopAndVerify() {
        updateTimer?.invalidate(); updateTimer = nil
        window?.orderOut(nil)
        Task { @MainActor in
            var failures = 0
            do {
                let url = try await source.stopAndFinish()
                emit("錄製完成 url=\(url.path) updates=\(updates)")

                // 預期像素尺寸：與 RecordFrameSource 內部同一條換算鏈（selection pt × scale）。
                let scale = screen?.backingScaleFactor ?? 2
                let selection = CGRect(origin: .zero, size: windowSize).insetBy(dx: 20, dy: 20)
                let expectedPxW = Int((selection.width * scale).rounded())
                let expectedPxH = Int((selection.height * scale).rounded())

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds

                // 檢查A 時長
                if abs(duration - totalSeconds) <= 0.6 {
                    emit("✅ 檢查A 時長 實得=\(String(format: "%.2f", duration))s 預期=\(totalSeconds)±0.6s")
                } else {
                    failures += 1
                    emit("❌ 檢查A 時長 實得=\(String(format: "%.2f", duration))s 預期=\(totalSeconds)±0.6s")
                }

                // 檢查B 可播（video track 存在且 naturalSize == 預期像素尺寸）
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let actualW = Int(naturalSize.width.rounded())
                    let actualH = Int(naturalSize.height.rounded())
                    if actualW == expectedPxW && actualH == expectedPxH {
                        emit("✅ 檢查B 可播 naturalSize=\(actualW)x\(actualH) 預期=\(expectedPxW)x\(expectedPxH)")
                    } else {
                        failures += 1
                        emit("❌ 檢查B 可播 naturalSize=\(actualW)x\(actualH) 與預期=\(expectedPxW)x\(expectedPxH) 不符")
                    }
                } else {
                    failures += 1
                    emit("❌ 檢查B 可播 video track 不存在")
                }

                // 檢查C/D：GifExporter.export（pointScale 用測試螢幕 backingScaleFactor）
                let gifURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("anypaint-record-selfcheck-\(UUID().uuidString).gif")
                let gifFailures = await exportAndVerifyGif(movieURL: url, gifURL: gifURL,
                                                           pointScale: scale, duration: duration,
                                                           expectedPxW: expectedPxW)
                failures += gifFailures

                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: gifURL)
            } catch {
                failures += 1
                emit("❌ 錄製收檔失敗 \(error)")
            }
            emit(failures == 0 ? "---- 全部通過 ----" : "---- 有 \(failures) 項失敗 ----")
            finishNow(exitCode: failures == 0 ? 0 : 1)
        }
    }

    /// 匯出 GIF 並驗證檢查C（格數）／檢查D（寬度）。回傳失敗項數。
    private func exportAndVerifyGif(movieURL: URL, gifURL: URL, pointScale: CGFloat,
                                    duration: Double, expectedPxW: Int) async -> Int {
        let fps = 12.0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            GifExporter.export(movieURL: movieURL, to: gifURL, pointScale: pointScale, fps: fps,
                               format: .gif,   // 判準確定性：自檢不吃設定，顯式走 GIF（設計文件 §1.2）
                               engine: .builtin,   // 判準確定性：不受本機是否裝 gifski 影響（設計文件 §1.7）
                               progress: { _ in }, completion: { _ in cont.resume() })
        }
        guard let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            emit("❌ 檢查C 檢查D GIF 讀取失敗 \(gifURL.path)")
            return 2
        }
        var failures = 0
        let frameCount = CGImageSourceGetCount(src)
        let expectedFrames = RecordMath.gridTimes(duration: duration, fps: fps).count
        // ±2 容差：檢查C 描述用時長×12 直接估，交叉驗證則用 RecordMath 的精確計算。
        let roughExpected = Int((duration * fps).rounded())
        if abs(frameCount - roughExpected) <= 2 && frameCount == expectedFrames {
            emit("✅ 檢查C GIF 格數 實得=\(frameCount) 粗估=\(roughExpected)±2 RecordMath交叉驗證=\(expectedFrames)")
        } else {
            failures += 1
            emit("❌ 檢查C GIF 格數 實得=\(frameCount) 粗估=\(roughExpected)±2 RecordMath交叉驗證=\(expectedFrames)")
        }

        if frameCount > 0, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let pxW = props[kCGImagePropertyPixelWidth] as? Int {
            let expectedW = max(1, Int((CGFloat(expectedPxW) / pointScale).rounded()))
            if pxW == expectedW {
                emit("✅ 檢查D GIF 尺寸 寬=\(pxW) 預期=像素寬(\(expectedPxW))/scale(\(pointScale))=\(expectedW)")
            } else {
                failures += 1
                emit("❌ 檢查D GIF 尺寸 寬=\(pxW) 與預期=\(expectedW) 不符")
            }
        } else {
            failures += 1
            emit("❌ 檢查D GIF 尺寸 無法讀取首格屬性")
        }
        return failures
    }

    private func emit(_ s: String) {
        lines.append(s)
        try? lines.joined(separator: "\n").write(toFile: "/tmp/anypaint-record-selfcheck.log",
                                                 atomically: true, encoding: .utf8)
    }

    private func finishNow(exitCode: Int32 = 1) {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(exitCode) }
    }
}

/// 自檢用的內容視圖：大字顯示遞增數字，整體位置固定（不需要位移／匹配——動畫截圖不像
/// 滾動截圖需要拼接，只需要「畫面確實在變化」讓 SCStream 持續供格，以及「確實會靜止」
/// 讓尾格補齊邏輯有東西可測）。
final class SelfCheckRecordContentView: NSView {
    var number: Int = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        let text = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attrs)
    }
}
