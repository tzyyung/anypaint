import AppKit

// MARK: - 繪製與控制點幾何

extension SelectionView {
    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

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
            backgroundImage.draw(in: rect, from: rect, operation: .copy, fraction: 1.0)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()

            // 即時尺寸標籤（拖曳/調整時每次重繪就更新）
            drawSizeBadge(for: rect)

            // 標註（含拖曳中的暫定形狀）疊在亮區上、裁到框內——畫面上看得到的
            // 才會被擷取（所見即所存；框外部分匯出時被裁掉，乾脆不畫）。
            if !annotations.isEmpty || provisionalShape != nil {
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
                if selected.isCornerResizable, selectDrag == nil {
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

        // 放大鏡準星：hover（未框選）或拖曳時顯示，方便像素級對齊
        if let lp = activeLoupePoint() {
            drawLoupe(at: lp)
        }

        if let secs = watchdogWarningSeconds { drawWatchdogBanner(seconds: secs) }
    }

    private func loupeRect(at p: CGPoint) -> CGRect {
        let side = loupeSide
        var lx = p.x + 16
        var ly = p.y - 16 - side
        if lx + side > bounds.width { lx = p.x - 16 - side }
        if ly < 0 { ly = p.y + 16 }
        lx = min(max(0, lx), bounds.width - side)
        ly = min(max(0, ly), bounds.height - side)
        return CGRect(x: lx, y: ly, width: side, height: side)
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
        let scale = snapshot.scale
        let x = min(max(0, Int(p.x * scale)), snapshot.cgImage.width - 1)
        let y = min(max(0, Int((bounds.height - p.y) * scale)), snapshot.cgImage.height - 1)
        return (x, y)
    }

    func invalidateLoupe(around a: CGPoint?, and b: CGPoint?) {
        var dirty = CGRect.null
        for p in [a, b].compactMap({ $0 }) {
            dirty = dirty.union(loupeRect(at: p).insetBy(dx: -60, dy: -70))
        }
        if !dirty.isNull { setNeedsDisplay(dirty) }
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

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }
    private func handleRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
    }
    func hitHandle(_ point: CGPoint, in r: CGRect) -> Handle? {
        let pts = handlePoints(r)
        for (i, p) in pts.enumerated() {
            if handleRect(at: p).insetBy(dx: -4, dy: -4).contains(point) {
                return Handle.allCases[i]
            }
        }
        return nil
    }

    // MARK: select 工具：選取物件的四角 handle（僅 isCornerResizable 物件；比照框選 handle 樣式）

    enum AnnotationHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    private func annotationHandlePoints(_ r: CGRect) -> [(AnnotationHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottomRight, CGPoint(x: r.maxX, y: r.minY))]
    }
    /// 命中選取物件的縮放 handle（chrome＝bounds 外擴 4pt，與 draw() 畫的虛線框同一矩形）。
    func hitAnnotationHandle(_ point: CGPoint, for annotation: Annotation) -> AnnotationHandle? {
        guard annotation.isCornerResizable else { return nil }
        let chrome = annotation.bounds.insetBy(dx: -4, dy: -4)
        for (handle, p) in annotationHandlePoints(chrome) {
            if handleRect(at: p).insetBy(dx: -4, dy: -4).contains(point) { return handle }
        }
        return nil
    }
    /// 由拖出的四角 handle 算新 bounds；允許拖過頭翻轉，用 min/max 正規化（比照既有 resize 慣例）。
    func resizeAnnotationBounds(_ start: CGRect, handle: AnnotationHandle, to p: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .topLeft:     minX = p.x; maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .bottomRight: maxX = p.x; minY = p.y
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

}
