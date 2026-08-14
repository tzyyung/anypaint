import AppKit

/// 統一 morph 工具列的「錄後完成態」視圖（spec §四，對抗式審查 #10：從 `RecordHUDController` 抽出，
/// 避免那個為 durationField 覆寫 `canBecomeKey` 的面板再混進 drag source 概念）。
///
/// 成功：左＝可拖曳縮圖、中＝✓標題／檔名／中繼、右＝播放/Finder/複製/重錄；右上＝✕。
/// 失敗：⚠︎ 標題＋原因＋重試/開啟資料夾；右上＝✕。
///
/// 播放／Finder／複製／拖曳只需 `fileURL`，本視圖自理（不回 session）；重錄／關閉／重試經 `onAction` 上拋。
@MainActor
final class RecordDoneView: NSView {
    /// 動作上拋（session 只關心 reRecord/close/retry；play/reveal/copy/drag 本視圖處理後仍上拋供收面板判斷）。
    var onAction: ((RecordDonePolicy.Action) -> Void)?
    /// 「開啟存檔資料夾」用（失敗態沒有 fileURL 可 reveal）。
    var saveDirectoryURL: URL?

    private let thumb = DraggableFileThumb()
    private let titleLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let actionRow = NSStackView()
    private let closeButton = NSButton()
    private var fileURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 60).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 42).isActive = true
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 7
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.onDrag = { [weak self] in self?.onAction?(.drag) }

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 11.5)
        nameLabel.textColor = NSColor(white: 1, alpha: 0.92)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.textColor = NSColor(white: 1, alpha: 0.6)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setViews([titleLabel, nameLabel, metaLabel], in: .leading)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionRow.orientation = .horizontal
        actionRow.spacing = 7
        actionRow.alignment = .centerY

        closeButton.title = "✕"
        closeButton.bezelStyle = .rounded
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.contentTintColor = NSColor(white: 1, alpha: 0.8)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let main = NSStackView(views: [thumb, textStack, spacerView(), actionRow])
        main.orientation = .horizontal
        main.alignment = .centerY
        main.spacing = 12
        main.translatesAutoresizingMaskIntoConstraints = false
        main.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 34)   // 右留位給 ✕

        addSubview(main)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.trailingAnchor.constraint(equalTo: trailingAnchor),
            main.topAnchor.constraint(equalTo: topAnchor),
            main.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func spacerView() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: 內容

    /// 成功態。`thumbnail` 可為 nil（縮圖生成失敗）→ 顯示佔位 ▶。
    func configureSuccess(url: URL, name: String, meta: String, saveDirectory: URL?) {
        fileURL = url
        thumb.fileURL = url
        thumb.isHidden = false
        thumb.placeholderGlyph = "▶"
        thumb.image = nil
        saveDirectoryURL = saveDirectory
        titleLabel.stringValue = RecordHUDInfo.doneTitle(success: true)
        nameLabel.stringValue = name
        nameLabel.isHidden = false
        metaLabel.stringValue = meta
        metaLabel.isHidden = false
        rebuildActions(success: true)
    }

    /// 失敗態。`detail`＝人類可讀原因；`saveDirectory`＝「開啟存檔資料夾」目標。
    func configureFailed(detail: String, saveDirectory: URL?) {
        fileURL = nil
        thumb.fileURL = nil
        thumb.image = nil
        thumb.placeholderGlyph = "⚠︎"
        thumb.isHidden = false
        saveDirectoryURL = saveDirectory
        titleLabel.stringValue = RecordHUDInfo.doneTitle(success: false)
        nameLabel.stringValue = detail
        nameLabel.isHidden = detail.isEmpty
        metaLabel.isHidden = true
        rebuildActions(success: false)
    }

    /// 設縮圖（generation token 由呼叫端 RecordHUDController 守；這裡單純顯示）。
    func setThumbnail(_ image: NSImage) { thumb.image = image }

    private func rebuildActions(success: Bool) {
        actionRow.arrangedSubviews.forEach { actionRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        if success {
            actionRow.addArrangedSubview(primaryButton("▶ 播放", #selector(playTapped)))
            actionRow.addArrangedSubview(chip("在 Finder 顯示", #selector(revealTapped)))
            actionRow.addArrangedSubview(chip("⧉", #selector(copyTapped)))
            actionRow.addArrangedSubview(chip("↺", #selector(reRecordTapped)))   // 沿用同選區再錄
        } else {
            actionRow.addArrangedSubview(primaryButton("重試", #selector(reRecordTapped)))
            actionRow.addArrangedSubview(chip("開啟存檔資料夾", #selector(openDirTapped)))
        }
    }

    private func primaryButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        (b.cell as? NSButtonCell)?.font = .systemFont(ofSize: 12, weight: .semibold)
        return b
    }
    private func chip(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        (b.cell as? NSButtonCell)?.font = .systemFont(ofSize: 11.5)
        return b
    }

    // MARK: 動作（play/reveal/copy 本視圖自理，仍上拋供收面板；reRecord/close/retry 靠 session）

    @objc private func playTapped() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }
        onAction?(.play)
    }
    @objc private func revealTapped() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        onAction?(.reveal)
    }
    @objc private func copyTapped() {
        if let fileURL {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([fileURL as NSURL])   // 只放 .fileURL（絕不 NSImage——CLAUDE.md 剪貼簿條）
        }
        onAction?(.copy)
    }
    @objc private func openDirTapped() {
        if let saveDirectoryURL { NSWorkspace.shared.open(saveDirectoryURL) }
        onAction?(.reveal)
    }
    @objc private func reRecordTapped() { onAction?(.reRecord) }
    @objc private func closeTapped() { onAction?(.close) }
}

/// 可拖曳的檔案縮圖：拖曳 payload＝`fileURL`（`.fileURL`，非 NSImage）；縮圖影像僅作拖曳視覺。
@MainActor
final class DraggableFileThumb: NSImageView, NSDraggingSource {
    var fileURL: URL?
    var onDrag: (() -> Void)?
    /// 無縮圖時畫的字符（▶ 或 ⚠︎）。
    var placeholderGlyph: String = "▶" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if image == nil {
            NSColor(white: 0.18, alpha: 1).setFill()
            bounds.fill()
            let g = placeholderGlyph as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor(white: 1, alpha: 0.85)]
            let size = g.size(withAttributes: attrs)
            g.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attrs)
        } else {
            super.draw(dirtyRect)
        }
    }

    override func mouseDown(with event: NSEvent) { /* 攔住,等 drag */ }

    override func mouseDragged(with event: NSEvent) {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let visual = image ?? NSImage(size: bounds.size)
        item.setDraggingFrame(bounds, contents: visual)
        beginDraggingSession(with: [item], event: event, source: self)
        onDrag?()
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
