import AppKit

// MARK: - 游標與 hover 追蹤

extension SelectionView {
    // 依滑鼠位置顯示對應游標。角落用 SF Symbol 當對角游標（公開 API，無私有游標；
    // 參考 capso 的 cursorForHandle）；邊用系統 resize 游標；框內移動手；工具列箭頭。
    // 四個 handle 游標全用系統原生資源（同源、風格一致）；載入失敗才 fallback。
    private static func symbolCursor(_ name: String) -> NSCursor {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
        }
        return .crosshair
    }
    private static let cursorNWSE = NativeCursors.load("resizenorthwestsoutheast")
        ?? symbolCursor("arrow.up.left.and.arrow.down.right")   // ↖↘
    private static let cursorNESW = NativeCursors.load("resizenortheastsouthwest")
        ?? symbolCursor("arrow.up.right.and.arrow.down.left")   // ↗↙
    private static let cursorEW = NativeCursors.load("resizeeastwest") ?? .resizeLeftRight
    private static let cursorNS = NativeCursors.load("resizenorthsouth") ?? .resizeUpDown

    func cursor(at point: CGPoint) -> NSCursor {
        if !toolbar.isHidden, toolbar.frame.contains(point) { return .arrow }
        // 文字工具懸浮在既有文字上＝可拖曳移動，用開手游標提示（驗收回饋 Fix 2）。
        if activeTool == .text, hitTextObject(at: point) != nil { return .openHand }
        if activeTool == .select { return selectCursor(at: point) }
        if activeTool != nil { return .crosshair }   // 繪製工具＝十字線（spec）
        if let sel = selection, !frameLocked {       // 鎖框時無控制點、不可移動
            if let h = hitHandle(point, in: sel) {
                switch h {
                case .topLeft, .bottomRight: return Self.cursorNWSE
                case .topRight, .bottomLeft: return Self.cursorNESW
                case .left, .right:          return Self.cursorEW
                case .top, .bottom:          return Self.cursorNS
                }
            }
            if sel.contains(point) { return .openHand }
        }
        return .crosshair
    }

    /// select 工具游標：選取物件的四角 handle＝對角 resize；物件本體＝開手；其餘＝箭頭（spec）。
    private func selectCursor(at point: CGPoint) -> NSCursor {
        if let selID = annotations.selectedID,
           let selected = annotations.objects.first(where: { $0.id == selID }),
           let handle = hitAnnotationHandle(point, for: selected) {
            switch handle {
            case .topLeft, .bottomRight: return Self.cursorNWSE
            case .topRight, .bottomLeft: return Self.cursorNESW
            }
        }
        if annotations.hitTest(at: point) != nil { return .openHand }
        return .arrow
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: nil, and: p) }
    }
    override func mouseMoved(with event: NSEvent) {
        onInteraction?()
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        // 文字工具 hover 既有文字 → 記錄以畫虛線框（驗收回饋 Fix 2）；變化才重繪。
        let newHover = (activeTool == .text) ? hitTextObject(at: p)?.id : nil
        if newHover != hoveredTextID {
            hoveredTextID = newHover
            needsDisplay = true
        }
        // 視窗偵測（spec）：未框選＋無工具＝游標下的視窗為候選框（無則整螢幕）
        if activeTool == nil, selection == nil {
            let origin = snapshot.frameGlobal.origin
            let globalP = CGPoint(x: p.x + origin.x, y: p.y + origin.y)
            let newCandidate: CGRect
            if let hit = WindowDetector.hitTest(point: globalP, windows: snapshot.windows) {
                newCandidate = CGRect(x: hit.origin.x - origin.x, y: hit.origin.y - origin.y,
                                      width: hit.width, height: hit.height)
                    .intersection(bounds)   // 跨螢幕視窗 clamp 進本螢幕（spec）
            } else {
                newCandidate = bounds       // 桌面＝整顆螢幕（使用者決策）
            }
            if newCandidate != windowCandidate {
                windowCandidate = newCandidate
                needsDisplay = true
            }
        } else if windowCandidate != nil {
            windowCandidate = nil
            needsDisplay = true
        }
        let prev = hoverPoint
        hoverPoint = p
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: p) }
    }
    override func mouseExited(with event: NSEvent) {
        if hoveredTextID != nil {
            hoveredTextID = nil
            needsDisplay = true
        }
        if windowCandidate != nil {
            windowCandidate = nil
            needsDisplay = true
        }
        let prev = hoverPoint
        hoverPoint = nil
        if drag == nil, selection == nil { invalidateLoupe(around: prev, and: nil) }
    }
}
