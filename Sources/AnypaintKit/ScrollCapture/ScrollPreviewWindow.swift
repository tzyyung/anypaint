import AppKit

/// 滾動截圖完成後的預覽視窗：一整張長圖（可達 30000px 長邊）、可捲動檢視、底部四鈕。
///
/// 標準 `NSWindow`（titled/closable/resizable）——**不是** panel：擷取 session 在呼叫這裡之前已經
/// 結束，這只是一般檢視器，不該像框選/貼圖那樣佔用互斥的「擷取模式」。
final class ScrollPreviewWindow: NSWindow {
    private let cgImage: CGImage
    private let vars: [String: String]
    private let output: CaptureOutputService
    private let pinboard: PinboardService
    /// 擷取當下的 backingScaleFactor（session 未回傳實際擷取 scale，近似用主螢幕；見
    /// ScrollPreviewWindowController.present 的說明）。用來把像素換算成點數（Finding #1）。
    private let scale: CGFloat
    weak var controller: ScrollPreviewWindowController?

    init(cgImage: CGImage, vars: [String: String],
         output: CaptureOutputService, pinboard: PinboardService, scale: CGFloat, contentRect: NSRect) {
        self.cgImage = cgImage
        self.vars = vars
        self.output = output
        self.pinboard = pinboard
        self.scale = scale
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "滾動截圖 \(cgImage.width)×\(cgImage.height)"
        isReleasedWhenClosed = false   // 由 controller 明確持有與釋放（forget，同 PinWindow 慣例）
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    // MARK: - UI

    private func buildUI() {
        guard let content = contentView else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        // size 除 scale（Finding #1 對齊 SelectionView 正解）：顯示比例本身不受影響
        // （imageView 之後靠 Auto Layout 依 aspect 重算 frame），但為一致性一併改，避免
        // NSImage.size 與實際擷取像素的點數換算不一致造成日後誤用。
        imageView.image = NSImage(cgImage: cgImage,
                                   size: NSSize(width: CGFloat(cgImage.width) / scale,
                                                height: CGFloat(cgImage.height) / scale))
        // 只縮小不放大（已查證 NSImageScaling 官方文件）：小圖不強行拉大失真。
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = imageView

        let copyButton = NSButton(title: "複製", target: self, action: #selector(copyAction))
        let saveButton = NSButton(title: "存檔", target: self, action: #selector(saveAction))
        let saveAsButton = NSButton(title: "另存", target: self, action: #selector(saveAsAction))
        let discardButton = NSButton(title: "丟棄", target: self, action: #selector(discardAction))
        for b in [copyButton, saveButton, saveAsButton, discardButton] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }

        let buttonRow = NSStackView(views: [copyButton, saveButton, saveAsButton, discardButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttonRow)

        let clip = scroll.contentView
        // 高：依圖片長寬比例，隨 clip 寬度連動（heightAnchor = widthAnchor * aspect）。
        let aspect = CGFloat(cgImage.height) / CGFloat(max(cgImage.width, 1))

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            // 文件視圖寬適配 clip view（已查證：只釘 top/leading/trailing、不釘 bottom，
            // 讓文件視圖能超出 clip 高度以觸發垂直捲動；scaleProportionallyDown 在此計算後的
            // frame 內只縮小顯示，不放大）。
            imageView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: clip.topAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: aspect),
        ])
    }

    // MARK: - 按鈕語意（spec §3，逐字落實）

    /// 複製：影像＋暫存 PNG 檔案 URL 雙型別（大圖降級，spec §8）；不關窗。
    @objc private func copyAction() {
        pinboard.copyLarge(cgImage: cgImage, scale: scale)
    }

    /// 存檔：快速儲存樣板路徑直寫＋掛自動儲存；不關窗。
    @objc private func saveAction() {
        output.saveExpanding(template: AppSettings.quickSavePathTemplate,
                              cgImage: cgImage, vars: vars, quiet: false)
        output.autoSaveIfEnabled(cgImage: cgImage, vars: vars)
    }

    /// 另存：彈 NSSavePanel 自選位置＋掛自動儲存；不關窗。
    @objc private func saveAsAction() {
        output.saveWithPanel(cgImage: cgImage, vars: vars)
        output.autoSaveIfEnabled(cgImage: cgImage, vars: vars)
    }

    /// 丟棄：確認（無法復原）→ 關窗。文案逐字照 spec。
    @objc private func discardAction() {
        let alert = NSAlert()
        alert.messageText = "丟棄這張長圖？此動作無法復原"
        alert.addButton(withTitle: "丟棄")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 對話框不會成 key
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        close()
    }

    // 紅鈕（標準關閉）＝結束，不再確認：複製/存檔過與否使用者自知，spec 只要求丟棄鈕確認。
    override func close() {
        controller?.forget(self)
        super.close()
    }
}

/// 滾動截圖完成後的預覽視窗控制者：組裝視窗、持有存活（同 PinWindowController 慣例）。
@MainActor
public final class ScrollPreviewWindowController {
    private let output: CaptureOutputService
    private let pinboard: PinboardService
    private var windows: [ScrollPreviewWindow] = []

    public init(output: CaptureOutputService, pinboard: PinboardService) {
        self.output = output
        self.pinboard = pinboard
    }

    /// 開一個新的預覽視窗（不重用舊視窗——使用者可能同時留著多張長圖檢視）。
    /// 尺寸：寬 = min(圖寬/scale + 40, 螢幕可視寬×0.6)；高 = 螢幕可視高×0.8。
    public func present(image: CGImage, vars: [String: String]) {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // session 未回傳實際擷取時的 backingScaleFactor，用主螢幕近似（Finding #1：
        // 這個 scale 同時用於複製到剪貼簿的 NSImage.size 換算，見 PinboardService.copyLarge）。
        let scale = screen?.backingScaleFactor ?? 2.0
        let width = min(CGFloat(image.width) / scale + 40, visible.width * 0.6)
        let height = visible.height * 0.8
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)

        let window = ScrollPreviewWindow(cgImage: image, vars: vars,
                                          output: output, pinboard: pinboard,
                                          scale: scale, contentRect: contentRect)
        window.controller = self
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func forget(_ window: ScrollPreviewWindow) {
        windows.removeAll { $0 === window }
    }
}
