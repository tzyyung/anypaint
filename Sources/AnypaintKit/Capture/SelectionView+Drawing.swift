import AppKit

// MARK: - 繪製與控制點幾何

extension SelectionView {
    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        // 只畫 dirty 範圍而不是整個 bounds：十字線的重繪帶是「幾點寬 × 全高」的細長條，
        // 每次滑鼠移動若都重畫整張 2880×1864 的背景圖，會跟不上快速移動（實機回報：
        // overlay 剛出現、背景變暗那一刻快速移動會看到殘影）。
        // .copy 而非預設的 .sourceOver——這是最底層，不需要混合。
        backgroundImage.draw(in: dirtyRect, from: dirtyRect, operation: .copy, fraction: 1.0)
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()

        // 視窗偵測候選框（未框選＋無工具）：提亮候選區＋accent 邊框（spec）。
        // 按下滑鼠（selection 已設為零尺寸框）到放開之間不畫——單擊瞬間的短暫消失可接受。
        if selection == nil, activeTool == nil, let cand = windowCandidate, !cand.isEmpty {
            backgroundImage.draw(in: cand, from: cand, operation: .copy, fraction: 1.0)
            NSColor.black.withAlphaComponent(0.12).setFill()
            cand.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: cand.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }

        if let rect = selection, rect.width > 0, rect.height > 0 {
            if surfaceHasAlpha {
                // 去背底圖：先鋪棋盤格,再把（含透明的）底圖 sourceOver 疊上 → 透明處看得見格子。
                drawTransparencyCheckerboard(in: rect)
                backgroundImage.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1.0)
            } else {
                backgroundImage.draw(in: rect, from: rect, operation: .copy, fraction: 1.0)
            }
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()

            // 即時尺寸標籤（拖曳/調整時每次重繪就更新）
            drawSizeBadge(for: rect)

            // 標註（含拖曳中的暫定形狀）疊在亮區上、裁到框內——畫面上看得到的
            // 才會被擷取（所見即所存；框外部分匯出時被裁掉，乾脆不畫）。
            if !annotations.isEmpty || provisionalShape != nil || !polygonDraft.isEmpty {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                if let cg = NSGraphicsContext.current?.cgContext {
                    AnnotationRenderer.render(
                        annotations.objects.filter { $0.id != editingTextID },
                        in: cg, counterNumbers: counterNumbersMap(), sourceProvider: frozenImageProvider())
                    if let shape = provisionalShape {
                        AnnotationRenderer.render(
                            [Annotation(shape: shape, style: currentStyle)], in: cg, sourceProvider: frozenImageProvider())
                    }
                }
                if !polygonDraft.isEmpty { drawPolygonDraft() }
                NSGraphicsContext.current?.restoreGraphicsState()
            }

            // 文字工具 hover 既有文字 → 白色虛線框提示（拖曳中不畫，避免視覺干擾；
            // 驗收回饋 Fix 2）。
            if let hoveredID = hoveredTextID, textDragCandidate == nil,
               let obj = annotations.objects.first(where: { $0.id == hoveredID }) {
                let box = obj.bounds.insetBy(dx: -4, dy: -4)
                let hoverPath = NSBezierPath(rect: box)
                hoverPath.setLineDash([4, 3], count: 2, phase: 0)
                hoverPath.lineWidth = 1
                NSColor.white.setStroke()
                hoverPath.stroke()
            }

            // select 工具：選取物件的 chrome——白色虛線框＋（可縮放時）四角 handle，
            // 拖曳中隱藏 handle（畫面乾淨，比照框選 handle 的既有慣例）。
            if activeTool == .select, let selID = annotations.selectedID,
               let selected = annotations.objects.first(where: { $0.id == selID }) {
                let chrome = selected.bounds.insetBy(dx: -4, dy: -4)
                let chromePath = NSBezierPath(rect: chrome)
                chromePath.setLineDash([4, 3], count: 2, phase: 0)
                chromePath.lineWidth = 1
                NSColor.white.setStroke()
                chromePath.stroke()
                if let poly = editablePolygon(of: selected) {
                    // 多邊形：畫每個角點節點 handle（角點各自拖），選中的節點以橘色標示。
                    if selectDrag == nil || selectDragBegan == false {
                        for (i, hp) in poly.points.enumerated() {
                            let h = handleRect(at: hp)
                            (i == selectedPolygonNode ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
                            NSColor.white.setStroke()
                            let path = NSBezierPath(rect: h)
                            path.fill()
                            path.lineWidth = 1
                            path.stroke()
                        }
                    }
                } else if selected.isCornerResizable, selectDrag == nil {
                    NSColor.controlAccentColor.setFill()
                    NSColor.white.setStroke()
                    for (_, hp) in annotationHandlePoints(chrome) {
                        let h = handleRect(at: hp)
                        let path = NSBezierPath(rect: h)
                        path.fill()
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
            }

            // 鎖/解鎖鈕（懸停或選中的標註；select 工具下）
            drawLockIcons()

            // 拖曳中不畫控制點（畫面乾淨）；靜止時畫 8 個控制點
            if drag == nil, !frameLocked {
                NSColor.controlAccentColor.setFill()
                NSColor.white.setStroke()
                for p in handlePoints(rect) {
                    let h = handleRect(at: p)
                    let hp = NSBezierPath(rect: h)
                    hp.fill()
                    hp.lineWidth = 1
                    hp.stroke()
                }
            }
        }

        // 對齊輔助：十字參考線在下、放大鏡在上（否則線會穿過放大鏡）。
        // 兩者共用 activeLoupePoint 的時機判斷——都是「正在決定位置」的時候。
        if let lp = activeLoupePoint() {
            drawCrosshairGuides(at: lp)
            drawLoupe(at: lp)
        } else {
            // 這一幀不畫十字線（進入標註階段等）：清掉記錄，否則之後的 invalidate 會一直
            // 多標一條早已不存在的線。
            lastDrawnCrosshair = nil
        }

        if let secs = watchdogWarningSeconds { drawWatchdogBanner(seconds: secs) }
    }

    /// 貫穿全螢幕的十字參考線：跟著游標，方便把選區邊緣對齊到畫面上的其他元素。
    ///
    /// **黑白交錯的單一條線**（同 Photoshop 選取框／Figma 參考線的做法）：先畫 1 點寬的
    /// 白色實線，再用同寬的黑色 dash 疊在同一位置蓋掉一半 → 白段與黑段輪流。
    /// 白背景上黑段可見、暗背景上白段可見，而且**永遠只在一個位置、只有一條線**。
    ///
    /// 走到這個做法前錯了兩次，都記在這裡免得再繞回去：
    /// 1. 黑實線＋白虛線疊同位置，指望 dash 間隙露出黑線提供對比 → 亮背景下不明顯：
    ///    黑線只有 0.55 alpha 又只露一半，視覺上只剩白線在跟白底競爭。
    /// 2. 改描邊（3 點黑框 ＋ 1 點白線疊正中央）→ **白背景上看起來是兩條平行線**：
    ///    白線融進白底消失，黑框的中心被它掏空，剩兩側各 1 點的黑邊。
    ///    描邊在這裡本質上行不通——主線一旦與背景同色就會掏空外框中心。
    ///
    /// 座標對齊到像素格再畫——1 點的細線落在半像素上會被反鋸齒糊成兩條淡線，
    /// 那就失去「精確對齊」的意義了（同 ScreenCaptureKit sourceRect 的像素格對齊考量）。
    private func drawCrosshairGuides(at p: CGPoint) {
        let scale = snapshot.scale
        let x = (p.x * scale).rounded() / scale
        let y = (p.y * scale).rounded() / scale

        func makeLines() -> [NSBezierPath] {
            let vertical = NSBezierPath()
            vertical.move(to: CGPoint(x: x, y: 0))
            vertical.line(to: CGPoint(x: x, y: bounds.height))
            let horizontal = NSBezierPath()
            horizontal.move(to: CGPoint(x: 0, y: y))
            horizontal.line(to: CGPoint(x: bounds.width, y: y))
            return [vertical, horizontal]
        }

        // 白色實線鋪底（暗背景靠它）
        for path in makeLines() {
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
        }
        // 黑色 dash 蓋掉一半（亮背景靠它）。兩層**同寬**才會是一條線而不是描邊。
        // 已查 NSBezierPath.h:110：setLineDash 收 const CGFloat* + count + phase。
        let dash: [CGFloat] = [4, 4]
        for path in makeLines() {
            path.lineWidth = 1
            path.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.black.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
        lastDrawnCrosshair = CGPoint(x: x, y: y)   // 記已對齊的座標——清除時要標的正是這個位置
    }

    private func loupeRect(at p: CGPoint) -> CGRect {
        SelectionGeometry.loupeRect(at: p, in: bounds.size, side: loupeSide)
    }

    /// 放大鏡顯示點：任何拖曳中（調框或畫標註）→拖曳點；尚未框選→hover 點；其餘不顯示。
    func activeLoupePoint() -> CGPoint? {
        if drag != nil || shapeAnchor != nil { return dragPoint }
        if selection == nil { return hoverPoint }
        return nil
    }

    /// 游標點 → 快照像素座標（左上原點，clamp 進影像範圍）；drawLoupe 與取色共用，
    /// 保證「準星指哪就取哪」。
    func samplePixelCoord(at p: CGPoint) -> (x: Int, y: Int) {
        SelectionGeometry.samplePixelCoord(at: p, scale: snapshot.scale,
                                           imageWidth: snapshot.cgImage.width,
                                           imageHeight: snapshot.cgImage.height,
                                           viewHeight: bounds.height)
    }

    func invalidateLoupe(around a: CGPoint?, and b: CGPoint?) {
        var dirty = CGRect.null
        for p in [a, b].compactMap({ $0 }) {
            dirty = dirty.union(loupeRect(at: p).insetBy(dx: -60, dy: -70))
        }
        if !dirty.isNull { setNeedsDisplay(dirty) }

        // 十字線**貫穿全螢幕**，只重繪放大鏡附近會讓舊線留在畫面上（實機回報的殘影）。
        // 各點的細帶**各自標記、不 union**——兩條交叉線的外接矩形就是整個畫面，
        // union 起來等於放棄這裡的局部重繪優化（它存在的理由是避免每次滑鼠移動都重畫
        // 整張全螢幕背景圖）。
        // AppKit 若保留多矩形 dirty region 就只重繪這幾條細帶；若合併成外接矩形則退化成
        // 全重繪——**兩種情況都正確**，差別只在成本。
        //
        // 一定要含 lastDrawnCrosshair：a/b 來自 hover 事件，而畫面上那條線可能是別的路徑
        // （primeHoverState 的全重繪）畫的、或事件被合併而錯過——漏標它就是殘影。
        for p in [a, b, lastDrawnCrosshair].compactMap({ $0 }) {
            setNeedsDisplay(crosshairBandVertical(atX: p.x))
            setNeedsDisplay(crosshairBandHorizontal(atY: p.y))
        }
    }

    /// 十字線的重繪帶：兩層都是 1 點寬，±2 點涵蓋反鋸齒與像素格對齊的位移。
    /// 這個數字必須跟 drawCrosshairGuides 的最大 lineWidth 連動——標得不夠寬就會留殘影。
    private func crosshairBandVertical(atX x: CGFloat) -> CGRect {
        SelectionGeometry.crosshairBandVertical(atX: x, height: bounds.height)
    }

    private func crosshairBandHorizontal(atY y: CGFloat) -> CGRect {
        SelectionGeometry.crosshairBandHorizontal(atY: y, width: bounds.width)
    }

    /// 放大鏡：裁游標周圍一小塊原始像素、最近鄰放大畫在游標旁，中央十字準星 + 座標。
    private func drawLoupe(at p: CGPoint) {
        let side = loupeSide
        let srcPixels = loupeSrcPixels
        let scale = snapshot.scale
        let imgW = CGFloat(snapshot.cgImage.width)
        let imgH = CGFloat(snapshot.cgImage.height)

        // 游標對應的原圖像素座標（左上原點）
        let cx = p.x * scale
        let cyTop = (bounds.height - p.y) * scale
        let src = CGRect(x: cx - srcPixels / 2, y: cyTop - srcPixels / 2,
                         width: srcPixels, height: srcPixels)

        let loupe = loupeRect(at: p)

        guard let ctx = NSGraphicsContext.current else { return }

        // 底色
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(rect: loupe).fill()

        // 放大內容（裁與影像交集，最近鄰）
        let clamped = src.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH)).integral
        if clamped.width >= 1, clamped.height >= 1,
           let crop = snapshot.cgImage.cropping(to: clamped) {
            ctx.saveGraphicsState()
            NSBezierPath(rect: loupe).addClip()
            ctx.imageInterpolation = .none
            // clamped(左上像素) 映射到 loupe(左下點) 的目標矩形
            let tx = loupe.minX + (clamped.minX - src.minX) / srcPixels * side
            let th = clamped.height / srcPixels * side
            let ty = loupe.maxY - (clamped.maxY - src.minY) / srcPixels * side
            let tw = clamped.width / srcPixels * side
            NSImage(cgImage: crop, size: NSSize(width: clamped.width, height: clamped.height))
                .draw(in: CGRect(x: tx, y: ty, width: tw, height: th))
            ctx.restoreGraphicsState()
        }

        // 中央「單一像素」方塊 + 十字準星（游標永遠在 loupe 正中央）
        let px = side / srcPixels
        let center = CGPoint(x: loupe.midX, y: loupe.midY)
        NSColor.controlAccentColor.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: loupe.minX, y: center.y)); cross.line(to: CGPoint(x: loupe.maxX, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: loupe.minY)); cross.line(to: CGPoint(x: center.x, y: loupe.maxY))
        cross.lineWidth = 1
        cross.stroke()
        let pixelBox = CGRect(x: center.x - px / 2, y: center.y - px / 2, width: px, height: px)
        NSBezierPath(rect: pixelBox).stroke()

        // 邊框
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: loupe.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // 取色資訊面板（Snipaste 式，驗收回饋 2026-07-22）：四行置中——
        // (x , y)／■ 色值（RGB 或 HEX，Shift 切換）／按 C 複製（toast 暫代）／按 Shift 切換。
        let sp = samplePixelCoord(at: p)
        let rgb = ColorSampler.sampleRGB(image: snapshot.cgImage, x: sp.x, y: sp.y)
        let showsRGB = AppSettings.colorPickerShowsRGB
        let colorText: String
        if let rgb {
            colorText = showsRGB
                ? "\(rgb.r), \(rgb.g), \(rgb.b)"
                : ColorSampler.hexString(r: rgb.r, g: rgb.g, b: rgb.b)
        } else {
            colorText = "—"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white]
        let lines: [NSAttributedString] = [
            NSAttributedString(string: "(\(sp.x) , \(sp.y))", attributes: attrs),
            NSAttributedString(string: colorText, attributes: attrs),
            NSAttributedString(string: copiedColorText ?? "按 C 複製色彩值", attributes: attrs),
            NSAttributedString(string: "按 Shift 切換 RGB/HEX", attributes: attrs),
        ]
        let lineH: CGFloat = 14
        let padV: CGFloat = 4
        let swatchSide: CGFloat = 10
        let swatchGap: CGFloat = 5
        var maxW = lines.map { $0.size().width }.max() ?? 0
        maxW = max(maxW, lines[1].size().width + swatchSide + swatchGap)
        let panelW = max(side, maxW + 12)
        let panelH = lineH * CGFloat(lines.count) + padV * 2
        var panel = CGRect(x: loupe.minX, y: loupe.minY - panelH - 2,
                           width: panelW, height: panelH)
        // 下方放不下（游標近螢幕底）→ 翻到放大鏡上方；水平 clamp 進畫面。
        if panel.minY < 0 { panel.origin.y = loupe.maxY + 2 }
        panel.origin.x = min(max(0, panel.origin.x), bounds.width - panel.width)
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(rect: panel).fill()
        for (i, line) in lines.enumerated() {
            // 由上往下排；文字 baseline 靠行底
            let rowY = panel.maxY - padV - lineH * CGFloat(i + 1) + 2
            var startX = panel.midX - line.size().width / 2
            if i == 1, let rgb {
                startX = panel.midX - (line.size().width + swatchSide + swatchGap) / 2
                let swatch = CGRect(x: startX, y: rowY + 1, width: swatchSide, height: swatchSide)
                NSColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                        blue: CGFloat(rgb.b) / 255, alpha: 1).setFill()
                NSBezierPath(rect: swatch).fill()
                NSColor.white.setStroke()
                let sb = NSBezierPath(rect: swatch.insetBy(dx: 0.5, dy: 0.5))
                sb.lineWidth = 1
                sb.stroke()
                startX += swatchSide + swatchGap
            }
            line.draw(at: CGPoint(x: startX, y: rowY))
        }
    }

    /// 多邊形成形中的預覽：已點的點連成折線（當前色），首點畫較大圈提示「點回這裡收尾」，
    /// 其餘點畫小方塊。呼叫端已 clip 進選取框。
    private func drawPolygonDraft() {
        guard let first = polygonDraft.first else { return }
        let color = NSColor(cgColor: currentStyle.color.cgColor) ?? .systemRed
        if polygonDraft.count >= 2 {
            let line = NSBezierPath()
            line.move(to: first)
            for p in polygonDraft.dropFirst() { line.line(to: p) }
            line.lineWidth = currentStyle.lineWidth
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
        // 節點方塊
        for p in polygonDraft {
            let h = handleRect(at: p)
            color.setFill(); NSColor.white.setStroke()
            let path = NSBezierPath(rect: h); path.fill(); path.lineWidth = 1; path.stroke()
        }
        // 首點高亮圈（可收尾時＝已 ≥3 點）
        if PolygonBuilder.canFinish(points: polygonDraft) {
            let r: CGFloat = 7
            let ring = NSBezierPath(ovalIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 2
            NSColor.white.setStroke(); ring.stroke()
        }
    }

    /// 畫鎖/解鎖鈕（懸停或選中的標註右上角）：鎖定橘底 🔒、解鎖深底 🔓。
    private func drawLockIcons() {
        guard activeTool == .select else { return }
        for id in lockIconTargets() {
            guard let ann = annotations.objects.first(where: { $0.id == id }) else { continue }
            let r = annotationLockIconRect(for: ann)
            let locked = isLocked(id)
            (locked ? NSColor.systemOrange.withAlphaComponent(0.95)
                    : NSColor(white: 0.1, alpha: 0.85)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            let emoji = locked ? "🔒" : "🔓"
            let s = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let sz = s.size()
            s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }

    /// 透明棋盤格（去背底圖的透明處背景，只用於畫面顯示，不進輸出）。
    private func drawTransparencyCheckerboard(in rect: CGRect) {
        NSColor(white: 0.28, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.42, alpha: 1).setFill()
        let s: CGFloat = 8
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: min(s, rect.maxX - x), height: min(s, rect.maxY - y)).fill()
                x += 2 * s
            }
            y += s; row += 1
        }
    }

    /// 在選取框上方畫「寬 × 高（像素）」小標籤；上方空間不足就畫在框內頂端。
    private func drawSizeBadge(for rect: CGRect) {
        let w = Int((rect.width * snapshot.scale).rounded())
        let h = Int((rect.height * snapshot.scale).rounded())
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "\(w) × \(h)", attributes: attrs)
        let pad: CGFloat = 4
        let textSize = str.size()
        let bw = textSize.width + pad * 2
        let bh = textSize.height + pad * 2

        var x = rect.minX
        var y = rect.maxY + 4                       // 框上方（非翻轉座標：maxY 是上緣）
        if y + bh > bounds.height { y = rect.maxY - bh - 4 }  // 貼近螢幕頂 → 移進框內
        x = min(max(0, x), bounds.width - bw)
        y = min(max(0, y), bounds.height - bh)

        let badge = CGRect(x: x, y: y, width: bw, height: bh)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        str.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad))
    }

    /// 看門狗倒數橫幅：置頂中央、醒目紅底。任何輸入會讓 controller 清掉它。
    private func drawWatchdogBanner(seconds: Int) {
        let text = "無操作，\(seconds) 秒後自動取消——動一下滑鼠即繼續" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 14
        let rect = CGRect(x: (bounds.width - size.width) / 2 - pad,
                          y: bounds.height - 80,
                          width: size.width + pad * 2,
                          height: size.height + 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.1, alpha: 0.9).setFill()
        path.fill()
        text.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 8), withAttributes: attrs)
    }

    // MARK: 控制點幾何

    // 幾何純函式已抽到 SelectionGeometry（可單元測試）；這裡只補上 view 狀態（handleSize）委派。
    private func handlePoints(_ r: CGRect) -> [CGPoint] { SelectionGeometry.handlePoints(r) }
    private func handleRect(at p: CGPoint) -> CGRect {
        SelectionGeometry.handleRect(at: p, size: handleSize)
    }
    func hitHandle(_ point: CGPoint, in r: CGRect) -> Handle? {
        SelectionGeometry.hitHandleIndex(point, in: r, size: handleSize).map { Handle.allCases[$0] }
    }

    // MARK: select 工具：選取物件的 8 向 handle（僅 isCornerResizable 物件；比照框選 handle 樣式）
    // 用 8 向 ResizeEdge（四角＋四邊中點）——與框選框同一套，矩形類可拖角改寬高、拖邊改單軸。
    typealias AnnotationHandle = SelectionGeometry.ResizeEdge
    private func annotationHandlePoints(_ r: CGRect) -> [(AnnotationHandle, CGPoint)] {
        Array(zip(SelectionGeometry.ResizeEdge.allCases, SelectionGeometry.handlePoints(r)))
    }
    /// 命中選取物件的縮放 handle（chrome＝bounds 外擴 4pt，與 draw() 畫的虛線框同一矩形）。
    func hitAnnotationHandle(_ point: CGPoint, for annotation: Annotation) -> AnnotationHandle? {
        guard annotation.isCornerResizable else { return nil }
        return SelectionGeometry.hitHandleIndex(point, in: annotation.bounds.insetBy(dx: -4, dy: -4),
                                                size: handleSize)
            .map { SelectionGeometry.ResizeEdge.allCases[$0] }
    }
    /// 由拖出的 handle 算新 bounds；允許拖過頭翻轉，用 min/max 正規化（比照既有 resize 慣例）。
    func resizeAnnotationBounds(_ start: CGRect, handle: AnnotationHandle, to p: CGPoint) -> CGRect {
        SelectionGeometry.resized(start, edge: handle, to: p)
    }

    // MARK: 多邊形節點（角點各自拖、邊上插點）

    /// 若 annotation 是多邊形，回傳其可編輯核心（供節點 handle 命中/繪製）；否則 nil。
    func editablePolygon(of annotation: Annotation) -> EditablePolygon? {
        guard case .polygon(let pts, let closed) = annotation.shape else { return nil }
        return EditablePolygon(points: pts, closed: closed)
    }

    /// 命中多邊形的某個角點節點（回索引）；非多邊形或沒命中 → nil。
    func hitPolygonNode(_ point: CGPoint, for annotation: Annotation) -> Int? {
        guard let poly = editablePolygon(of: annotation) else { return nil }
        // handle 命中框比繪製略大，好點（比照 handleSize）。
        for (i, r) in poly.handleRects(size: handleSize + 4).enumerated() where r.contains(point) {
            return i
        }
        return nil
    }

}
