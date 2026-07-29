import AppKit

/// 點擊高亮圈：螢幕上的透明追蹤視窗，由 SCStream 自然拍入（架構出處：QuickRecorder
/// MousePointer；視覺參數出處：Screenity——40pt 圈、3pt 描邊、放開後 350ms 淡出。設計文件 §4）。
/// 不做 live compositing：改像素就不能直接 append sample buffer（四個實戰專案無一採用）。
@MainActor
public final class ClickRingOverlay: NSObject {
    private var window: NSPanel?
    private var monitors: [Any] = []
    private static let size: CGFloat = 56   // 40pt 圈 + 邊距（描邊與陰影不裁切）

    /// 建視窗並以 alpha 0 orderFront（**視窗必須存在且 on-screen，SCShareableContent 才列得到、
    /// filter 的 exceptingWindows 靜態快照才收得進**——設計文件 §3）。回傳 windowNumber。
    ///
    /// - Parameter point: 初始位置（全域座標、點），**必須落在某個實際螢幕內**——舊版固定擺
    ///   `(-100, -100)`（螢幕外）被 review 判定為真缺陷：`RecordFrameSource` 用
    ///   `onScreenWindowsOnly: true` 列舉視窗，完全在畫面外＋alpha 0 的視窗很可能列不到，
    ///   `exceptingWindows` 白名單就會放空，點擊圈視窗隨整個 app 一起被排除、功能靜默失效。
    ///   呼叫端（`RecordSession`）傳選區中心；alpha 0 保證使用者看不到這次借位。
    public func prepare(near point: CGPoint) -> Int {
        let origin = CGPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: Self.size, height: Self.size)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true          // 純顯示，事件全部穿透
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]  // 四件套
        p.contentView = ClickRingView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        p.alphaValue = 0
        p.orderFront(nil)
        window = p
        return p.windowNumber
    }

    /// 掛 mouse global monitor（滑鼠類**不需**輔助使用權限——QuickRecorder production 實證＋
    /// 本專案 scrollWheel 既有經驗）。只在 recording 期間掛。
    /// global monitor 收不到自家 app 的事件（點 HUD 停止鈕不畫圈）——那是控制操作，可接受。
    public func startMonitoring() {
        let down: (NSEvent) -> Void = { [weak self] _ in self?.showRing(at: NSEvent.mouseLocation) }
        let drag: (NSEvent) -> Void = { [weak self] _ in self?.moveRing(to: NSEvent.mouseLocation) }
        let up: (NSEvent) -> Void = { [weak self] _ in self?.fadeOut() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: drag) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: up) { monitors.append(m) }
    }

    public func stopMonitoring() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    public func teardown() {
        stopMonitoring()
        window?.orderOut(nil)
        window = nil
    }

    private func showRing(at p: CGPoint) {   // p：全域座標（點、左下原點）
        guard let w = window else { return }
        w.setFrameOrigin(CGPoint(x: p.x - Self.size / 2, y: p.y - Self.size / 2))
        w.alphaValue = 1
    }

    private func moveRing(to p: CGPoint) {
        guard let w = window, w.alphaValue > 0 else { return }
        w.setFrameOrigin(CGPoint(x: p.x - Self.size / 2, y: p.y - Self.size / 2))
    }

    private func fadeOut() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35              // Screenity：放開後 ~350ms 淡出
            w.animator().alphaValue = 0
        }
    }
}

/// 圈本體：40pt 直徑、3pt 亮橘描邊＋1pt 深色外圈（疊色教訓——單色描邊在同色背景會消失，
/// CLAUDE.md「疊色描邊」段；深淺兩層任一背景仍看得到）。
private final class ClickRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let ring = bounds.insetBy(dx: 8, dy: 8)        // 56pt 窗內 40pt 圈
        let outer = NSBezierPath(ovalIn: ring.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 4
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outer.stroke()
        let inner = NSBezierPath(ovalIn: ring)
        inner.lineWidth = 3
        NSColor.systemOrange.setStroke()
        inner.stroke()
    }
}
