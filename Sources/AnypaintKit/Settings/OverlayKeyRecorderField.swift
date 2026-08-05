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
        return s + binding.character.uppercased()
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

    deinit { stopRecording() }

    public override func mouseDown(with event: NSEvent) {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
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
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
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
        label.stringValue = Self.displayString(for: binding)
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func clearAction() {
        stopRecording()
        onChange(nil)
    }
}
