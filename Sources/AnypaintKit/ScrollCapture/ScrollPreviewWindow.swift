import AppKit

/// 滾動截圖完成後的預覽視窗：一整張長圖（可達 30000px 長邊）、可捲動檢視、底部四鈕。
///
/// 標準 `NSWindow`（titled/closable/resizable）——**不是** panel：擷取 session 在呼叫這裡之前已經
/// 結束，這只是一般檢視器，不該像框選/貼圖那樣佔用互斥的「擷取模式」。
final class ScrollPreviewWindow: NSWindow {
    /// 內容區最小寬度：底部按鈕排放得下的下限。
    /// 實測（一次性量測）五顆鈕排寬 321pt，加左右邊距 12×2 = 345，取 360 留字型／語系裕度。
    /// 沒有這個下限，窄長圖（Retina 上圖寬 < 610px）算出的視窗會比按鈕排還窄——按鈕排只釘
    /// trailing、不釘 leading，會直接往左溢出視窗邊界，「複製」鈕看不到。
    static let minContentWidth: CGFloat = 360
    /// 高度下限：按鈕排 + 一點圖，避免縮到只剩標題列。
    static let minContentHeight: CGFloat = 200

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
        // 視窗可 resize：使用者手動拖窄也不能讓按鈕排溢出（與初始寬度同一個下限）。
        contentMinSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
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
        copyButton.toolTip = "複製到剪貼簿（⌘C）"
        let saveButton = NSButton(title: "存檔", target: self, action: #selector(saveAction))
        saveButton.toolTip = "儲存到預設資料夾（⌘S）"
        let saveAsButton = NSButton(title: "另存", target: self, action: #selector(saveAsAction))
        saveAsButton.toolTip = "另存為…自選位置與檔名（⇧⌘S）"
        let openButton = NSButton(title: "存檔並開啟", target: self, action: #selector(openAction))
        openButton.toolTip = "存檔並用外部 App 開啟，在那裡繼續編輯（⌘O）"
        let discardButton = NSButton(title: "丟棄", target: self, action: #selector(discardAction))
        discardButton.toolTip = "丟掉這張長圖並關窗（需確認）"
        for b in [copyButton, saveButton, saveAsButton, openButton, discardButton] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }

        // 快捷鍵：與框選工具列同一套（⌘S／⇧⌘S／⌘O），複製用標準的 ⌘C。
        // 已查 NSButton.h：keyEquivalentModifierMask **只有 Control/Option/Command 有意義**，
        // Shift 無效 → ⇧⌘S 靠大寫 "S" 表達，不是往 mask 裡加 .shift。
        // ⌘ 組合鍵會先走 performKeyEquivalent 遞迴 view 階層（NSButton 有預設實作），
        // 早於 responder chain，所以不會被 NSImageView 搶走（它 editable 預設也是 false）。
        // 「丟棄」刻意不給快捷鍵：破壞性動作，且紅鈕／⌘W 已能關窗。
        for (button, key) in [(copyButton, "c"), (saveButton, "s"), (saveAsButton, "S"), (openButton, "o")] {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
        }

        let buttonRow = NSStackView(views: [copyButton, saveButton, saveAsButton, openButton, discardButton])
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

    /// 存檔並開啟：存到快速儲存路徑後交給系統預設的圖片程式（多數機器＝預覽程式）繼續標註；
    /// 掛自動儲存（與存檔鈕同紀律）。**不關窗**——外部程式接手後使用者仍可能想回來複製或另存
    /// （比照複製/存檔的既有語意，只有丟棄與紅鈕才關）。
    @objc private func openAction() {
        output.saveAndOpen(cgImage: cgImage, vars: vars)
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
    /// - Parameter captureScale: **實際擷取時那個螢幕**的 backingScaleFactor，由 session 傳入。
    ///   原本這裡自己取 `NSScreen.main?.backingScaleFactor`（標記為 Finding #1 的近似），
    ///   在混合 DPI 的多螢幕下會錯：這個 scale 同時用於複製到剪貼簿的 NSImage.size 換算
    ///   （見 `PinboardService.copyLarge`），Retina 筆電＋外接 1080p 的組合會讓圖差一倍。
    public func present(image: CGImage, vars: [String: String], captureScale: CGFloat) {
        // 視窗尺寸用「要顯示這個視窗的螢幕」＝滑鼠所在螢幕；scale 則一律用擷取端傳來的值。
        let screen = ScrollCaptureSession.screenUnderMouse()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = captureScale > 0 ? captureScale : 2.0
        // 下限優先於「貼合圖寬」：窄長圖也要放得下底部按鈕排；再夾回螢幕寬以防超出。
        let ideal = min(CGFloat(image.width) / scale + 40, visible.width * 0.6)
        let width = min(max(ideal, ScrollPreviewWindow.minContentWidth), visible.width)
        let height = max(visible.height * 0.8, ScrollPreviewWindow.minContentHeight)
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
