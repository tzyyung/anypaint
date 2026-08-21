import AppKit

// MARK: - 美化背景面板（#1 Backdrop）

/// 浮動面板：選背景預設、調邊距/圓角、開關陰影，每次變動即時回報 style（供上層即時預覽）。
/// 與工具列一樣是「吞滑鼠事件」的容器，避免點面板誤觸底下的 SelectionView。
final class BackdropPanel: NSView {
    /// 任一控件變動 → 回報最新 style（上層據此重套預覽）。
    var onStyleChanged: ((BackdropStyle) -> Void)?
    /// 按「完成」＝保留目前美化結果。
    var onCommit: (() -> Void)?
    /// 按「取消」＝還原成美化前。
    var onCancel: (() -> Void)?

    private(set) var style: BackdropStyle
    private var swatches: [BackdropBackground: NSButton] = [:]
    private let paddingSlider = NSSlider()
    private let paddingValue = NSTextField(labelWithString: "")
    private let cornerSlider = NSSlider()
    private let cornerValue = NSTextField(labelWithString: "")
    private let shadowSwitch = NSButton()

    init(initial: BackdropStyle) {
        self.style = initial
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        build()
        syncControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    // 吞事件：點面板不要穿到底下 overlay。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v == nil ? (bounds.contains(convert(point, from: superview)) ? self : nil) : v
    }
    override func mouseDown(with event: NSEvent) { /* 吞掉 */ }

    private func build() {
        let title = NSTextField(labelWithString: "美化背景")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white

        // 背景預設列
        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 6
        for bg in BackdropBackground.allCases {
            let b = NSButton()
            b.title = ""
            b.bezelStyle = .smallSquare
            b.isBordered = false
            b.wantsLayer = true
            b.image = Self.swatchImage(for: bg, size: NSSize(width: 26, height: 26))
            b.imageScaling = .scaleAxesIndependently
            b.setButtonType(.momentaryChange)
            b.target = self
            b.action = #selector(swatchTapped(_:))
            b.identifier = NSUserInterfaceItemIdentifier(bg.rawValue)
            b.toolTip = bg.displayName
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            b.layer?.cornerRadius = 5
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            swatches[bg] = b
            swatchRow.addArrangedSubview(b)
        }

        paddingSlider.minValue = Double(BackdropStyle.paddingRange.lowerBound)
        paddingSlider.maxValue = Double(BackdropStyle.paddingRange.upperBound)
        paddingSlider.target = self
        paddingSlider.action = #selector(paddingChanged)
        cornerSlider.minValue = Double(BackdropStyle.cornerRange.lowerBound)
        cornerSlider.maxValue = Double(BackdropStyle.cornerRange.upperBound)
        cornerSlider.target = self
        cornerSlider.action = #selector(cornerChanged)
        let paddingRow = sliderRow("邊距", paddingSlider, paddingValue)
        let cornerRow = sliderRow("圓角", cornerSlider, cornerValue)

        shadowSwitch.setButtonType(.switch)
        shadowSwitch.title = "陰影"
        shadowSwitch.font = .systemFont(ofSize: 11)
        shadowSwitch.contentTintColor = .white
        (shadowSwitch.cell as? NSButtonCell)?.backgroundColor = .clear
        shadowSwitch.attributedTitle = NSAttributedString(
            string: "陰影", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
        shadowSwitch.target = self
        shadowSwitch.action = #selector(shadowChanged)

        let cancel = actionButton("取消", #selector(cancelTapped))
        let done = actionButton("完成", #selector(commitTapped))
        done.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [cancel, done])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        let stack = NSStackView(views: [title, swatchRow, paddingRow, cornerRow, shadowSwitch, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = NSColor(white: 1, alpha: 0.8)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 12)
        return b
    }

    /// 依目前 style 更新控件外觀（選中框、slider 值、文字）。
    private func syncControls() {
        for (bg, b) in swatches {
            b.layer?.borderWidth = (bg == style.background) ? 2.5 : 0
        }
        paddingSlider.doubleValue = Double(style.paddingPt)
        cornerSlider.doubleValue = Double(style.cornerRadiusPt)
        paddingValue.stringValue = "\(Int(style.paddingPt)) pt"
        cornerValue.stringValue = "\(Int(style.cornerRadiusPt)) pt"
        shadowSwitch.state = style.shadow ? .on : .off
    }

    private func emit() { syncControls(); onStyleChanged?(style) }

    @objc private func swatchTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let bg = BackdropBackground(rawValue: raw) else { return }
        style.background = bg
        emit()
    }
    @objc private func paddingChanged() {
        style.paddingPt = BackdropStyle.clampPadding(CGFloat(paddingSlider.doubleValue))
        emit()
    }
    @objc private func cornerChanged() {
        style.cornerRadiusPt = BackdropStyle.clampCorner(CGFloat(cornerSlider.doubleValue))
        emit()
    }
    @objc private func shadowChanged() {
        style.shadow = (shadowSwitch.state == .on)
        emit()
    }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func commitTapped() { onCommit?() }

    /// 產生預設背景的小縮圖（純色填滿／漸層左上→右下）——面板色票用。
    static func swatchImage(for bg: BackdropBackground, size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        if let solid = bg.solidColor {
            NSColor(cgColor: solid)?.setFill()
            rect.fill()
        } else if let colors = bg.gradientColors, colors.count >= 2,
                  let c0 = NSColor(cgColor: colors[0]), let c1 = NSColor(cgColor: colors[1]),
                  let g = NSGradient(starting: c0, ending: c1) {
            g.draw(in: rect, angle: -45)   // 左上→右下
        } else {
            NSColor.gray.setFill(); rect.fill()
        }
        img.unlockFocus()
        return img
    }
}
