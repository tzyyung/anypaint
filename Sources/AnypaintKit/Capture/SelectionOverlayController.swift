import AppKit

// MARK: - Overlay 視窗

/// 蓋滿單一螢幕的 borderless overlay 視窗（NSPanel + .nonactivatingPanel）。
final class SelectionOverlayWindow: NSPanel {
    init(snapshot: DisplaySnapshot) {
        super.init(
            contentRect: snapshot.frameGlobal,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true      // 確保 hover 時就收得到 mouseMoved（放大鏡/游標）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = SelectionView(snapshot: snapshot)
        setFrame(snapshot.frameGlobal, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var selectionView: SelectionView? { contentView as? SelectionView }
}

// MARK: - 協調者

/// 協調多螢幕 overlay：單飛、不疊加、多條逃生路徑 + 免按鍵看門狗
/// （所有輸入即重置、觸發前倒數警告、逾時搶救存剪貼簿、0=關閉、秒數可設）。
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var onSelect: ((NSImage) -> Void)?
    private var onPin: ((NSImage, CGRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?
    private var watchdogWarn: DispatchWorkItem?
    private var watchdogFire: DispatchWorkItem?
    private var warningTimer: Timer?
    private var warningRemaining = 0
    /// 觸發前多久開始倒數警告（spec 定 15 秒；最小可設秒數 60 > 15，不會交叉）。
    private let warningLead: TimeInterval = 15
    /// 上次重排看門狗的時間（防抖用）。
    private var lastArmUptimeNs: UInt64 = 0
    /// 最後一個有互動（滑鼠/鍵盤/滾輪）的視窗——看門狗逾時搶救取像時優先用它（Task 4）。
    private weak var lastInteractedWindow: SelectionOverlayWindow?

    private(set) var isActive = false

    func present(snapshots: [DisplaySnapshot],
                 onSelect: @escaping (NSImage) -> Void,
                 onPin: @escaping (NSImage, CGRect) -> Void,
                 onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onSelect = onSelect
        self.onPin = onPin
        self.onCancel = onCancel

        NSApp.activate(ignoringOtherApps: true)
        for snapshot in snapshots {
            let window = SelectionOverlayWindow(snapshot: snapshot)
            window.selectionView?.onConfirm = { [weak self] image in self?.finish(with: image) }
            window.selectionView?.onPin = { [weak self, weak window] image, sel in
                guard let window else { return }
                let globalFrame = CoordinateUtils.globalRect(
                    selection: sel, windowOrigin: window.frame.origin)
                self?.finishPin(with: image, frame: globalFrame)
            }
            window.selectionView?.onCancel = { [weak self] in self?.cancel() }
            window.selectionView?.onInteraction = { [weak self, weak window] in
                self?.armWatchdog()
                self?.lastInteractedWindow = window   // 搶救歸屬：記錄最後互動的視窗（Task 4）
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)   // 逃生路 1：keyDown/Esc 收得到
            windows.append(window)
        }

        // 逃生路 2：本地事件監聽——Esc 分層（組字讓位 → 編輯中先完成編輯 →
        // 有選取先解除選取 → 否則取消；Task 4 新增「解除選取」這一層）。
        // 取色的 Shift 切換與 C 也走這裡：nonactivating panel 被點擊前收不到
        // responder 事件（多螢幕時 key window 還可能在別顆螢幕），監聽器不依賴
        // responder、直接路由到「游標所在（放大鏡顯示中）的那個 overlay」。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged {
                self?.handleFlagsChanged(event)
                return event   // 修飾鍵事件一律放行，別破壞系統/IME 的修飾鍵狀態
            }
            self?.armWatchdog()          // 任何鍵都算互動（含文字編輯中打字）
            // C：取色（放大鏡顯示中）。文字編輯中不攔——讓 c 正常打進編輯器。
            if !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               !event.modifierFlags.contains(.option),
               event.charactersIgnoringModifiers?.lowercased() == "c",
               let views = self?.windows.compactMap({ $0.selectionView }),
               !views.contains(where: { $0.isEditingText }),
               let hovered = views.first(where: { $0.activeLoupePoint() != nil }) {
                hovered.copyLoupeColor()
                return nil
            }
            if event.keyCode == 53 {
                let views = (self?.windows ?? []).compactMap { $0.selectionView }
                // Esc 分層：有 view 在文字編輯中 → 一次完成「全部」視窗的編輯
                //（多螢幕各開一個編輯器也保證最多兩下 Esc 離開）；否則取消 overlay。
                let editing = views.filter { $0.isEditingText }
                // IME 組字中（注音打到一半）：把 Esc 讓給輸入法清組字，
                // 下一下 Esc 才輪到「完成編輯」——否則未組完的符號會被烙進字串。
                if editing.contains(where: { $0.isComposingText }) {
                    return event
                }
                if !editing.isEmpty {
                    editing.forEach { $0.commitTextEditing() }
                    return nil
                }
                // 有任一視窗選取著物件（select 工具）→ 先解除選取，Esc 不直接取消整個 overlay。
                if views.contains(where: { $0.hasSelection }) {
                    views.forEach { $0.deselect() }
                    return nil
                }
                self?.cancel()
                return nil
            }
            return event
        }
        // 逃生路 5：看門狗（免按鍵），互動即重置，秒數可在設定頁調
        armWatchdog()
        NSCursor.crosshair.set()
    }

    /// flagsChanged 用：前次 shift 是否按著（只在「無→有」轉變時切換取色顯示格式）。
    private var shiftWasDown = false

    /// Shift 單按（無 ⌘/⌃/⌥）＝切換取色顯示格式（RGB/HEX），只在有 overlay 的放大鏡
    /// 顯示中時生效；文字編輯中不切。組合鍵（如 ⌘⇧Z）靠「當下已有其他修飾鍵」排除。
    private func handleFlagsChanged(_ event: NSEvent) {
        let shiftDown = event.modifierFlags.contains(.shift)
        let othersDown = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        defer { shiftWasDown = shiftDown }
        guard shiftDown, !shiftWasDown, !othersDown else { return }
        let views = windows.compactMap { $0.selectionView }
        guard !views.contains(where: { $0.isEditingText }),
              let hovered = views.first(where: { $0.activeLoupePoint() != nil }) else { return }
        AppSettings.colorPickerShowsRGB.toggle()
        hovered.onInteraction?()   // 重置看門狗＋更新搶救歸屬（與 C 鍵路徑一致，審查 Minor）
        hovered.needsDisplay = true   // 全量重繪：切換立即反映在面板上
    }

    /// 逃生路 3：外部（再按截圖快鍵）取消目前框選。
    func cancelIfActive() {
        guard isActive else { return }
        cancel()
    }

    /// 重置看門狗：只在「無任何互動」達設定秒數才強制解除。
    /// 觸發前 warningLead 秒顯示倒數橫幅；秒數設 0 = 使用者選擇關閉，不排程。
    private func armWatchdog() {
        // 高頻互動（mouseMoved 等）防抖：0.5 秒內已排程且未在倒數警告中就不重排，
        // 避免堆積大量已取消的 work item（總審查建議）。誤差 ≤0.5 秒對 60 秒級逾時無感；
        // 倒數警告顯示中（warningTimer != nil）一律立即重排，橫幅才會即時消失。
        let now = DispatchTime.now().uptimeNanoseconds
        if warningTimer == nil, watchdogFire != nil, now &- lastArmUptimeNs < 500_000_000 { return }
        lastArmUptimeNs = now
        clearWatchdog()
        let total = AppSettings.overlayWatchdogSeconds
        guard total > 0 else { return }   // 0 = 關閉（使用者明確選擇）
        let warn = DispatchWorkItem { [weak self] in self?.beginWarningCountdown() }
        let fire = DispatchWorkItem { [weak self] in self?.watchdogDidFire() }
        watchdogWarn = warn
        watchdogFire = fire
        DispatchQueue.main.asyncAfter(deadline: .now() + total - warningLead, execute: warn)
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: fire)
    }

    private func clearWatchdog() {
        watchdogWarn?.cancel(); watchdogWarn = nil
        watchdogFire?.cancel(); watchdogFire = nil
        warningTimer?.invalidate(); warningTimer = nil
        setWarning(nil)
    }

    private func beginWarningCountdown() {
        warningRemaining = Int(warningLead)
        setWarning(warningRemaining)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.isActive else { t.invalidate(); return }
            self.warningRemaining -= 1
            if self.warningRemaining > 0 {
                self.setWarning(self.warningRemaining)
            } else {
                t.invalidate()   // 歸零後由 watchdogFire 收尾
            }
        }
        // .common：事件追蹤（拖曳）期間也要跳；預設模式會停擺。
        RunLoop.main.add(timer, forMode: .common)
        warningTimer = timer
    }

    private func setWarning(_ seconds: Int?) {
        for window in windows { window.selectionView?.watchdogWarningSeconds = seconds }
    }

    private func watchdogDidFire() {
        guard isActive else { return }
        // 搶救：有有效框就把目前內容存進剪貼簿再解除（走 finish 同一條路，
        // 效果等同擷取＝複製到剪貼簿），沒有就純取消。免輸入保證不變。
        // 搶救前先把編輯中的文字落定（影像才會與所見一致；使用者已缺席，盡力保留）。
        windows.compactMap { $0.selectionView }.forEach { $0.commitTextEditing() }
        // 取像順序：使用者最後互動的視窗優先（Task 4 搶救歸屬），nil 或已不在 windows 裡
        // 才 fallback 回原本的快照順序第一個。
        var candidates = windows.compactMap { $0.selectionView }
        if let lastView = lastInteractedWindow?.selectionView,
           let idx = candidates.firstIndex(where: { $0 === lastView }) {
            candidates.remove(at: idx)
            candidates.insert(lastView, at: 0)
        }
        if let image = candidates.compactMap({ $0.currentCroppedImage() }).first {
            NSLog("anypaint: 框選看門狗逾時，已把目前框選內容存入剪貼簿（搶救）")
            finish(with: image)
        } else {
            NSLog("anypaint: 框選看門狗逾時（無互動），強制解除")
            cancel()
        }
    }

    private func finish(with image: NSImage) {
        let handler = onSelect
        dismiss()
        handler?(image)
    }

    private func finishPin(with image: NSImage, frame: CGRect) {
        let handler = onPin
        dismiss()
        handler?(image, frame)
    }

    private func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    private func dismiss() {
        clearWatchdog()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.arrow.set()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        lastInteractedWindow = nil
        onSelect = nil
        onPin = nil
        onCancel = nil
        isActive = false
    }
}

// 逃生路 4（保留）：SelectionView 右鍵在空白處＝取消；命中物件則改彈出 z-order/刪除選單
// （Task 4），空白處的取消路徑本身未動。
