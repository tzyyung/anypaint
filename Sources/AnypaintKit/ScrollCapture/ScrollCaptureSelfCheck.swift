import AppKit

/// 內建自檢：**不需任何使用者互動**，自己開一個「內容會程式化位移的視窗」→ 用正式的
/// `ScrollFrameSource` 真實擷取螢幕 → 餵進正式的 `ScrollStitchEngine` → 逐格記錄結果。
///
/// 存在理由：滾動截圖的失效多半發生在「SCStream 真實供格 → 匹配鏈」這段接縫上，
/// selftest 的合成影格測不到（沒有真實擷取），而每次都請使用者手動操作又太慢。
/// 這支自檢把那段接縫變成可重複執行的自動驗證。
///
/// 啟動：`ANYPAINT_SCROLL_SELFCHECK=1 <bundle>/Contents/MacOS/anypaint`
/// 結果：`/tmp/anypaint-selfcheck.log`，跑完自動結束行程。
///
/// 與正式流程的唯一差異：`excludeSelf: false`（自檢要拍的正是自家測試視窗）。
/// 其餘（filter/sourceRect 座標鏈/queueDepth/影格轉換/engine 三層匹配鏈）完全相同。
@MainActor
public final class ScrollCaptureSelfCheck {
    private var window: NSWindow?
    private var content: SelfCheckContentView?
    private let source = ScrollFrameSource()
    private var engine: ScrollStitchEngine?
    private var timer: Timer?
    private var step = 0
    private var frames = 0
    private var wheelAccum: CGFloat = 0
    /// 與 Session 相同的架構：engine 跑背景序列佇列＋只保留最新格的背壓。
    private let engineQueue = DispatchQueue(label: "anypaint.selfcheck.engine", qos: .userInitiated)
    private var engineBusy = false
    private var pendingFrame: PixelBuffer?
    private var dropped = 0
    private var firstFrameHeight = 0
    /// finalize 會把底帶補回最底端，補的高度不算「拼接進度」，比對時要加回來。
    private var bottomBandCompensation = 0
    private var lines: [String] = []
    /// 每步位移（點）。24pt＝Retina 48px，遠大於 minDelta，模擬正常速度捲動。
    private let stepPoints: CGFloat = 24
    private let totalSteps = 40

    public init() {}

    public func run() {
        guard let screen = NSScreen.main else { emit("FAIL 無主螢幕"); finishNow(); return }
        let winRect = CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 120, width: 720, height: 520)
        let view = SelfCheckContentView(frame: CGRect(origin: .zero, size: winRect.size))
        let w = NSWindow(contentRect: winRect, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "anypaint self-check"
        w.contentView = view
        // .floating：自檢期間必須確保這個視窗在最上層，否則擷取到的是蓋在上面的別的視窗
        // （實測被終端機蓋住時拼出 118% 的垃圾內容，判定會誤導）。
        w.level = .floating
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w
        content = view

        // 選區＝視窗內容區往內縮 40pt（避開標題列與邊緣）
        let selection = winRect.insetBy(dx: 40, dy: 40)
        emit("自檢開始 screen=\(screen.frame) window=\(winRect) selection=\(selection) scale=\(screen.backingScaleFactor)")
        engine = ScrollStitchEngine(maxHeightPx: 30000)

        source.onFrame = { [weak self] pb in self?.onFrame(pb) }
        source.onStreamError = { [weak self] e in
            self?.emit("FAIL stream 錯誤 \(e)")
            self?.finishNow()
        }
        Task { @MainActor in
            do {
                try await source.start(selectionGlobal: selection, screen: screen, excludeSelf: false)
                emit("stream 已啟動")
                startStepping()
            } catch {
                emit("FAIL stream 啟動失敗 \(error)")
                finishNow()
            }
        }
    }

    private func startStepping() {
        // 120ms 一步，模擬使用者連續捲動；.common mode 確保不受 tracking loop 影響。
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard step < totalSteps else { wrapUp(); return }
        step += 1
        content?.scrollOffset += stepPoints          // 內容往上移＝模擬頁面下捲
        content?.needsDisplay = true
        wheelAccum += stepPoints
    }

    /// 平均亮度（0-255）：用來抓「SCStream 供出黑格／半渲染格」的情況。
    private static func meanLuma(_ p: PixelBuffer) -> Int {
        guard !p.bytes.isEmpty else { return -1 }
        var sum = 0
        var i = 0
        let stride = 997 * 4          // 質數跳點抽樣，夠代表整張
        while i < p.bytes.count - 4 { sum += Int(p.bytes[i]); i += stride }
        return sum / max(1, (p.bytes.count / stride))
    }

    private func onFrame(_ pb: PixelBuffer) {
        frames += 1
        if firstFrameHeight == 0 { firstFrameHeight = pb.height }
        if frames <= 6 { emit("  frame#\(frames) 平均亮度=\(Self.meanLuma(pb))") }
        if pendingFrame != nil { dropped += 1 }
        pendingFrame = pb            // 背壓：只留最新
        pump()
    }

    private func pump() {
        guard !engineBusy, let frame = pendingFrame, let engine else { return }
        pendingFrame = nil
        engineBusy = true
        let accum = wheelAccum
        let n = frames
        engineQueue.async { [weak self] in
            let t0 = ProcessInfo.processInfo.systemUptime
            let out = engine.consume(frame: frame, wheelAccumulatedPoints: accum, wheelDirection: 1)
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            let h = engine.height
            Task { @MainActor in
                guard let self else { return }
                self.engineBusy = false
                switch out {
                case .appended, .trimmed, .bandsLocked: self.wheelAccum = 0
                default: break
                }
                // 記錄所有「非等待」結果，才看得到從成功轉為永久失敗的斷點
                if case .waitingForMotion = out {} else {
                    self.emit("frame#\(n) step=\(self.step) \(ms)ms → \(out) 高=\(h) matcher=\(engine.lastMatchNote)")
                }
                self.pump()
            }
        }
    }

    private func wrapUp() {
        timer?.invalidate(); timer = nil
        Task { @MainActor in
            await source.stop()
            let e = engine
            let finalCG = e?.finalize()
            let finalH = finalCG.map { "\($0.width)x\($0.height)" } ?? "nil"
            if let cg = finalCG {
                try? CaptureSaver.writePNG(cgImage: cg, to: URL(fileURLWithPath: "/tmp/anypaint-selfcheck.png"))
                if let pb = PixelBuffer(cgImage: cg) {
                    var blackRows = 0
                    var firstBlack = -1, lastBlack = -1
                    for r in 0..<pb.height {
                        let base = r * pb.width * 4
                        var s = 0
                        var c = 0
                        while c < pb.width { s += Int(pb.bytes[base + c * 4]); c += 37 }
                        if s == 0 {
                            blackRows += 1
                            if firstBlack < 0 { firstBlack = r }
                            lastBlack = r
                        }
                    }
                    emit("全黑列數=\(blackRows)/\(pb.height) 範圍=[\(firstBlack)...\(lastBlack)] PNG=/tmp/anypaint-selfcheck.png")
                }
            }
            emit("---- 結果 ----")
            emit("收到影格數=\(frames) 背壓丟格=\(dropped) 步數=\(step)")
            emit("engine 長圖高=\(e?.height ?? -1) appended格數=\(e?.appendedFrameCount ?? -1) 連續失敗=\(e?.consecutiveFailures ?? -1) 已鎖帶=\(e?.isLocked ?? false)")
            emit("finalize=\(finalH)")
            // 正確性判準（不只「有增長」）：內容每步位移 stepPoints×scale 像素，總共 totalSteps 步，
            // 所以長圖高應該 ≈ 基準格高 + 總位移。只檢查「有增長」會漏掉「拼了但缺內容」
            // （實測有一版只拼到 45% 就 PASS，之後才發現救援層被過嚴的驗證擋掉）。
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let baseH = Double(firstFrameHeight)
            let expected = baseH + Double(totalSteps) * Double(stepPoints) * Double(scale)
            let actual = Double((e?.height ?? 0) + bottomBandCompensation)
            let ratio = expected > 0 ? actual / expected : 0
            emit("預期高≈\(Int(expected)) 實得=\(Int(actual)) 達成率=\(Int(ratio * 100))%")
            // 上下都要卡：只設下限的話「拼太多」（重複內容）也會 PASS——實測曾出現 203% 卻報 PASS。
            let ok = (e?.appendedFrameCount ?? 0) > 1 && ratio >= 0.9 && ratio <= 1.1
            emit(ok ? "PASS 長圖拼接量正確" : "FAIL 拼接量不足（預期 \(Int(expected))、實得 \(Int(actual))）")
            finishNow()
        }
    }

    private func emit(_ s: String) {
        lines.append(s)
        try? lines.joined(separator: "\n").write(toFile: "/tmp/anypaint-selfcheck.log",
                                                 atomically: true, encoding: .utf8)
    }

    private func finishNow() {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}

/// 自檢用的「長內容」視圖：畫水平色塊條（近似文字行），整體依 scrollOffset 位移。
/// 位移會讓螢幕內容真的改變，SCStream 才會持續供格（靜止時不供格）。
final class SelfCheckContentView: NSView {
    var scrollOffset: CGFloat = 0

    override var isFlipped: Bool { true }

    /// 模仿深色終端機：近黑底＋亮色等寬字塊，且**大片區域是空白**——這是實機失效的場景
    /// （使用者在深色終端機上滾動截圖，長圖等於單張影格）。
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        // 決定性內容：以 y 絕對座標算出每行的縮排與長度，位移時同一行內容不變（可被匹配追蹤）。
        let lineH: CGFloat = 18
        let startLine = Int(scrollOffset / lineH) - 1
        let visibleLines = Int(bounds.height / lineH) + 3
        for i in startLine..<(startLine + visibleLines) {
            guard i >= 0 else { continue }
            let absY = CGFloat(i) * lineH
            let y = absY - scrollOffset
            var seed = UInt64(bitPattern: Int64(i)) &* 6364136223846793005 &+ 1442695040888963407
            func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
            // 每 3 行只有 1 行有字，模擬終端機輸出的空白間隔
            guard i % 3 == 0 else { continue }
            var x: CGFloat = CGFloat(8 + rnd(40))
            while x < bounds.width - 30 {
                let w = CGFloat(30 + rnd(110))
                let g = CGFloat(150 + rnd(105)) / 255.0     // 亮字（深底上）
                NSColor(white: g, alpha: 1).setFill()
                CGRect(x: x, y: y + 3, width: min(w, bounds.width - 10 - x), height: lineH - 7).fill()
                x += w + CGFloat(10 + rnd(24))
            }
        }
    }
}
