import AppKit

/// 框選功能鍵的錄製欄位。刻意不用 vendored KeyboardShortcuts 的 RecorderCocoa：
/// 那個元件拒絕裸鍵（見 RecorderCocoa.swift 的修飾鍵守門），而框選的重拍／取色就是裸鍵。
/// 本地鍵不需要 Carbon 註冊，所以也不必動用整套 library。
public final class OverlayKeyRecorderField: NSView {
    /// 修飾鍵顯示順序固定為 ⌃⌥⇧⌘（同 macOS 慣例）。
    public static func displayString(for binding: OverlayKeyBinding) -> String {
        var s = ""
        if binding.modifiers.contains(.control) { s += "⌃" }
        if binding.modifiers.contains(.option) { s += "⌥" }
        if binding.modifiers.contains(.shift) { s += "⇧" }
        if binding.modifiers.contains(.command) { s += "⌘" }
        return s + (specialKeyName(for: binding.character) ?? binding.character.uppercased())
    }

    /// `charactersIgnoringModifiers` 對方向鍵／功能鍵／刪除鍵等回傳私用區（Private Use Area，
    /// 0xF700 起）標量，對 Tab／Return／空白鍵回傳控制字元或空白——這些原樣 `uppercased()`
    /// 會印出無意義符號。這裡把常見鍵換成看得懂的名字；F-key 用算式而非 24 個字面量。
    private static func specialKeyName(for character: String) -> String? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return nil
        }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71B: return "F\(scalar.value - 0xF704 + 1)"   // 0xF704=F1 … 0xF71B=F24
        case 0xF728: return "⌦"
        case 0x09: return "⇥"
        case 0x0D: return "↩"
        case 0x20: return "空白"
        default: return nil
        }
    }

    /// 私用區裡叫不出名字的字元（如小鍵盤上少見的功能鍵）一律視為不可錄製——
    /// 顯示不出來的綁定比沒有綁定更糟，寧可讓使用者的按鍵被忽略、需要再按一次。
    private static func isUnrepresentablePrivateUse(_ character: String) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              (0xF700...0xF8FF).contains(scalar.value) else { return false }
        return specialKeyName(for: character) == nil
    }

    public var binding: OverlayKeyBinding {
        didSet { label.stringValue = Self.displayString(for: binding) }
    }

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let onChange: (OverlayKeyBinding?) -> Void
    private var monitor: Any?          // 強持有——弱持有會在 autorelease pool 清空時被釋放
                                        // （vendored 副本正是這個缺陷，issue #241 defect 1）
    private var recording = false
    // 設定視窗在 macOS 13.5+ 點關閉鈕是「隱藏」不是「關閉」，view 不會被釋放、deinit 不會跑，
    // 所以錄製狀態要靠「視窗不再是 key」主動收尾，不能只靠 deinit。token 存起來、
    // 每次重新掛上／deinit 都要移除，避免視窗開關幾次後 observer 疊加。
    private var windowDidResignKeyObserver: NSObjectProtocol?
    // 同一頁會放六顆這種欄位（Task 7）。跨 instance 只能有一顆在錄——否則第二顆按下去，
    // 第一顆的 monitor 還活著繼續吞鍵，使用者按的鍵可能錄到錯的欄位、或兩顆都卡住。
    private static weak var recordingField: OverlayKeyRecorderField?

    public init(binding: OverlayKeyBinding, onChange: @escaping (OverlayKeyBinding?) -> Void) {
        self.binding = binding
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.stringValue = Self.displayString(for: binding)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "回到預設組合")
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearAction)
        clearButton.setAccessibilityLabel("回到預設組合")

        let row = NSStackView(views: [label, clearButton])
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        widthAnchor.constraint(equalToConstant: 130).isActive = true   // flex row 內用固定寬要靠約束
    }

    required init?(coder: NSCoder) { fatalError("不支援 storyboard") }

    deinit {
        stopRecording()
        if let windowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
        }
    }

    // 視窗隱藏／換頁時 AppKit 會把 view 從 window 移走再放回不同 window——不能假設
    // 只會呼叫一次。每次進來都先清掉舊 observer 再視情況重掛，避免疊加。
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
            self.windowDidResignKeyObserver = nil
        }
        guard let window else {
            stopRecording()
            return
        }
        // object: window 把觀察範圍鎖在這顆視窗——不是全域收所有視窗的 resign 通知。
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            self?.stopRecording()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        // 跨 instance 互斥：先把還在錄的另一顆停掉，再佔位，保證全域只有一個活的 monitor。
        if let other = Self.recordingField, other !== self {
            other.stopRecording()
        }
        Self.recordingField = self
        recording = true
        label.stringValue = "按下想要的組合"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {           // Esc：取消錄製，不改值
                self.stopRecording()
                return nil
            }
            if event.specialKey == .delete || event.specialKey == .backspace {
                self.stopRecording()
                self.onChange(nil)             // 清除＝回預設，由呼叫端決定
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  !Self.isUnrepresentablePrivateUse(chars) else {
                return nil
            }
            let new = OverlayKeyBinding(character: chars,
                                        modifiers: OverlayModifiers(event: event.modifierFlags))
            self.stopRecording()
            self.binding = new
            self.onChange(new)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.recordingField === self { Self.recordingField = nil }
        label.stringValue = Self.displayString(for: binding)
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func clearAction() {
        stopRecording()
        onChange(nil)
    }
}
