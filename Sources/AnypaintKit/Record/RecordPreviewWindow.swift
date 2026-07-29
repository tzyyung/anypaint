import AppKit
import AVKit

/// 動畫截圖預覽：AVPlayerView 循環播放母帶＋〔存 GIF〕〔存 MP4〕〔丟棄〕。
/// 視窗骨架/持有慣例對照 `ScrollPreviewWindow`（該檔 5-45 行的骨架、174-216 行的
/// controller 持有／forget／present 慣例）——這裡不重複解釋，只記差異。
final class RecordPreviewWindow: NSWindow {
    /// 內容區最小尺寸：底部「狀態列＋存 GIF＋存 MP4＋開啟位置＋丟棄」放得下、影片區也留得下
    /// 基本可視面積。實測（一次性量測，同 ScrollPreviewWindow.minContentWidth 的量法——
    /// NSButton.sizeToFit() 量真實寬度，不是憑印象估）：四顆鈕依序寬 61/68/76/50pt，加 stack
    /// spacing 3×8pt 與左右邊距 12×2，button row 本身只需要 ~303pt——遠低於這裡的 380，
    /// 加「開啟位置」這顆鈕不需要調大下限。
    static let minContentWidth: CGFloat = 380
    static let minContentHeight: CGFloat = 240

    private let movieURL: URL
    private let vars: [String: String]
    private let output: RecordOutputService
    private let captureScale: CGFloat      // 擷取螢幕 backingScaleFactor（GIF 降 1x 用；單位：像素/點）
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?    // 循環播放：AVPlayerLooper 官方做法，必須持有否則不循環
    private var isExportingGif = false     // 見 close() 的說明：匯出中擋下關閉
    private var lastSavedURL: URL?         // 最近一次存 GIF/MP4 成功的路徑；「開啟位置」用
    private let statusLabel = NSTextField(labelWithString: "")
    private let openLocationButton = NSButton(title: "開啟位置", target: nil, action: nil)
    private var buttons: [NSButton] = []
    weak var controller: RecordPreviewWindowController?

    init(movieURL: URL, vars: [String: String], output: RecordOutputService,
         captureScale: CGFloat, contentRect: NSRect) {
        self.movieURL = movieURL
        self.vars = vars
        self.output = output
        self.captureScale = captureScale
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "動畫截圖"
        isReleasedWhenClosed = false   // 由 controller 明確持有與釋放（forget，同 ScrollPreviewWindow）
        contentMinSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未實作") }

    // MARK: - UI

    private func buildUI() {
        guard let content = contentView else { return }

        let playerView = AVPlayerView()
        playerView.controlsStyle = .minimal
        playerView.translatesAutoresizingMaskIntoConstraints = false

        // player 建立：AVQueuePlayer + AVPlayerLooper 是 Apple 文件的無縫循環官方做法；
        // looper 若只當區域變數，函式結束就被釋放，循環會靜默停止（已在 looper 屬性宣告處記過）。
        let item = AVPlayerItem(url: movieURL)
        let q = AVQueuePlayer()
        looper = AVPlayerLooper(player: q, templateItem: item)
        playerView.player = q
        q.play()
        player = q

        let saveGifButton = NSButton(title: "存 GIF", target: self, action: #selector(saveGifAction))
        saveGifButton.toolTip = "匯出為 GIF 並存到預設資料夾"
        let saveMp4Button = NSButton(title: "存 MP4", target: self, action: #selector(saveMp4Action))
        saveMp4Button.toolTip = "複製母帶存成 MP4（不影響之後再匯出 GIF）"
        openLocationButton.target = self
        openLocationButton.action = #selector(openLocationAction)
        openLocationButton.toolTip = "在 Finder 開啟並選取剛存的檔案"
        openLocationButton.isEnabled = false   // 還沒存過檔前無路徑可開
        let discardButton = NSButton(title: "丟棄", target: self, action: #selector(discardAction))
        discardButton.toolTip = "丟掉這段動畫截圖並關窗（需確認）"
        buttons = [saveGifButton, saveMp4Button, openLocationButton, discardButton]
        for b in buttons {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        // 「丟棄」刻意不給快捷鍵：破壞性動作（同 ScrollPreviewWindow.discardAction 的理由）。

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: [saveGifButton, saveMp4Button, openLocationButton, discardButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(playerView)
        content.addSubview(statusLabel)
        content.addSubview(buttonRow)

        // 佈局對照 ScrollPreviewWindow.buildUI 的 scroll+buttonRow constraints，把 scroll 換成
        // playerView；statusLabel 是本視窗新增的一列，靠左伸縮、trailing 頂到按鈕排 leading，
        // 讓「GIF 匯出中… NN%」這種變長文字有地方長，同時絕不擠壓／蓋住按鈕。
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
        ])
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        for b in buttons { b.isEnabled = enabled }
    }

    // MARK: - 按鈕語意

    /// 存 GIF：匯出中停用所有按鈕＋statusLabel 顯示進度；完成後存到快速儲存路徑。
    @objc private func saveGifAction() {
        isExportingGif = true
        setButtonsEnabled(false)
        statusLabel.stringValue = "GIF 匯出中… 0%"
        let tmpGif = movieURL.deletingPathExtension().appendingPathExtension("gif")
        GifExporter.export(movieURL: movieURL, to: tmpGif, pointScale: captureScale,
                           progress: { [weak self] p in
                               self?.statusLabel.stringValue = "GIF 匯出中… \(Int(p * 100))%"
                           },
                           completion: { [weak self] result in
                               guard let self else { return }
                               self.isExportingGif = false
                               self.setButtonsEnabled(true)
                               switch result {
                               case .success:
                                   let saved = self.output.saveCopy(from: tmpGif, ext: "gif", vars: self.vars)
                                   try? FileManager.default.removeItem(at: tmpGif)
                                   if let saved { self.lastSavedURL = saved }
                                   self.statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" }
                                       ?? "GIF 存檔失敗"
                               case .failure(let e):
                                   self.statusLabel.stringValue = "GIF 匯出失敗：\(e)"
                               }
                               // 「開啟位置」不是跟著上面 setButtonsEnabled(true) 無條件打開：
                               // 還沒存過檔（lastSavedURL 是 nil）就不該讓使用者按得下去——
                               // 沒有路徑可開，按了也只是 guard 直接 return，但那是「看起來能按
                               // 卻沒反應」，比「本來就是灰的」更讓人困惑。
                               self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
                           })
    }

    /// 存 MP4：copy 母帶（不 move——之後可能還要匯 GIF，母帶得留著）。
    @objc private func saveMp4Action() {
        let saved = output.saveCopy(from: movieURL, ext: "mp4", vars: vars)
        if let saved {
            lastSavedURL = saved
            openLocationButton.isEnabled = true
        }
        statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" } ?? "MP4 存檔失敗"
    }

    /// 開啟位置：在 Finder 開啟並選取最近一次存檔的檔案。accessory app 慣例：呼叫前不需要
    /// 自己 activate——`NSWorkspace.activateFileViewerSelecting` 會讓 Finder 自己浮到前景，
    /// 這是系統 API 對外的行為，不是本專案 overlay/nonactivating panel 那套事件路由問題。
    @objc private func openLocationAction() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 丟棄：確認（無法復原，流程同 ScrollPreviewWindow.discardAction）→ close。
    @objc private func discardAction() {
        let alert = NSAlert()
        alert.messageText = "丟棄這段動畫截圖？此動作無法復原"
        alert.addButton(withTitle: "丟棄")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 對話框不會成 key
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        close()
    }

    // 紅鈕（標準關閉）與「丟棄」共用這個 close()（同 ScrollPreviewWindow 慣例）。
    override func close() {
        // GIF 匯出中關窗：GifExporter 沒有 cancel/timeout，detached Task 可能卡死（例如母帶
        // 損毀導致 reader 卡在某個狀態）——若只「擋下關閉、要求等待」而不給逃生口，使用者除了
        // 強制砍掉整個 app 別無他法。因此提供第二顆「強制關閉」鈕，預設鈕仍是「繼續等待」
        // （NSAlert 第一顆鈕＝預設、Enter 觸發，避免誤觸強制關閉）。
        //
        // 強制關閉的安全性（三點都已個別確認，不是假設）：
        // 1. 被拋下的 GifExporter.export 背景 Task 會繼續跑到完成或失敗——它的 completion
        //    closure 用 [weak self]（見 saveGifAction），視窗這時已 forget/可能已釋放，
        //    self 為 nil 時 guard let self else { return } 直接 no-op，不會 crash。
        // 2. movieURL 在強制關閉時會被下面的 removeItem 刪掉，但 AVAssetReader 對它的檔案
        //    描述符已經開啟——APFS／POSIX 的 unlink 語意是「目錄項目消失，已開啟的 fd 仍可讀到
        //    刪除前的內容」，reader 不會因此中途壞掉；真正會發生的頂多是讀到 EOF 提前結束或
        //    reader.status 轉 .failed → GifExporter 走 completion(.failure(...))，一樣是
        //    no-op（見上一點）。
        // 3. 暫存 GIF（saveGifAction 裡的 tmpGif）殘留不會變成孤兒垃圾：tmpGif 是
        //    movieURL（RecordOutputService.tempMovieURL() 產出，檔名固定為
        //    "anypaint-record-<uuid>.mp4"）換副檔名而來，檔名前綴「anypaint-record-」不變，
        //    落在同一個暫存目錄——app 下次啟動時 RecordOutputService.cleanupStaleTempFiles()
        //    照前綴掃描刪除，會連同這個殘留 tmpGif 一起清掉（已對照該函式的比對邏輯確認）。
        if isExportingGif {
            let alert = NSAlert()
            alert.messageText = "GIF 匯出中，請稍候完成後再關閉"
            alert.informativeText = "強制關閉會捨棄這次匯出，母帶也會一併刪除。"
            alert.addButton(withTitle: "繼續等待")
            alert.addButton(withTitle: "強制關閉")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }   // 繼續等待：不關窗
            isExportingGif = false   // 選了強制關閉：解除擋關閉旗標，走下面的正常收尾
        }
        // 順序：先停 player 再刪暫存母帶——AVFoundation 對已開檔案 delete 雖不 crash，
        // 但釋放順序明確化可免平台差異（同 brief 註記）。
        player?.pause()
        looper = nil
        player = nil
        try? FileManager.default.removeItem(at: movieURL)
        controller?.forget(self)
        super.close()
    }
}

/// 讀母帶影片軌的像素尺寸，用來算預覽視窗的初始大小。
///
/// async load——同 GifExporter 的紀律：`track.naturalSize` 之類的同步屬性已標 deprecated，
/// 零 warning 是硬約束（見 CLAUDE.md 建置章節）。讀失敗（理論上不會發生，母帶剛寫完）就退回
/// 視窗尺寸下限，不讓整個預覽流程因為量不到尺寸而卡住或崩潰。
private func loadNaturalSize(movieURL: URL) async -> CGSize {
    let asset = AVURLAsset(url: movieURL)
    guard let tracks = try? await asset.loadTracks(withMediaType: .video),
          let track = tracks.first,
          let size = try? await track.load(.naturalSize) else {
        // RecordPreviewWindow 是 NSWindow 子類、SDK 對 AppKit 型別隱含 @MainActor，
        // 靜態屬性因此也是 actor-isolated，跨 actor 讀取要 await（不是巧合的 warning）。
        return await CGSize(width: RecordPreviewWindow.minContentWidth,
                            height: RecordPreviewWindow.minContentHeight)
    }
    return size
}

/// 動畫截圖預覽視窗控制者：組裝視窗、持有存活（同 ScrollPreviewWindowController 慣例）。
@MainActor
public final class RecordPreviewWindowController {
    private let output: RecordOutputService
    private var windows: [RecordPreviewWindow] = []

    public init(output: RecordOutputService) {
        self.output = output
    }

    /// 開一個新的預覽視窗。
    ///
    /// **為什麼是 `async`**：視窗尺寸公式需要母帶的實際像素尺寸（`naturalSize`），而讀
    /// naturalSize 只有 async API（見 `loadNaturalSize` 的說明）。這裡在兩個做法之間選了
    /// 「`present` 本身 async、先 await 讀完尺寸再建窗」，而不是「先開一個預設尺寸的窗、
    /// 讀到之後再 resize」：
    /// 1. 呼叫端（錄製收尾流程）本來就是在 `await stopAndFinish()` 之後的 async context 裡
    ///    呼叫這裡，多一次 await 不增加額外負擔；
    /// 2. 「先開窗再 resize」會讓使用者看到視窗尺寸跳動一次，體驗比多等一瞬間更差；
    /// 3. 與 GifExporter 已經確立的「AVFoundation 尺寸一律 async load、不用同步 deprecated
    ///    API」風格一致。
    /// 呼叫端需在 `Task { await controller.present(...) }` 或既有 async context 裡呼叫。
    public func present(movieURL: URL, vars: [String: String], captureScale: CGFloat) async {
        let naturalSize = await loadNaturalSize(movieURL: movieURL)

        // 視窗要顯示在「滑鼠所在的螢幕」，重用 ScrollCaptureSession 的既有邏輯（同一顆
        // 專案內共用，見該檔的說明：NSScreen.main 對 accessory app 不可靠）。
        let screen = ScrollCaptureSession.screenUnderMouse()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = captureScale > 0 ? captureScale : 2.0

        // 寬 = min(母帶像素寬/captureScale + 40, 螢幕可視寬×0.6)，下限 minContentWidth；
        // 高 = 寬×影片長寬比 + 90（播放器上方＋按鈕列），下限 minContentHeight；兩者都 clamp 進螢幕。
        let ideal = min(naturalSize.width / scale + 40, visible.width * 0.6)
        let width = min(max(ideal, RecordPreviewWindow.minContentWidth), visible.width)
        let aspect = naturalSize.height / max(naturalSize.width, 1)
        let idealHeight = width * aspect + 90
        let height = min(max(idealHeight, RecordPreviewWindow.minContentHeight), visible.height)
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)

        let window = RecordPreviewWindow(movieURL: movieURL, vars: vars, output: output,
                                         captureScale: scale, contentRect: contentRect)
        window.controller = self
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func forget(_ window: RecordPreviewWindow) {
        windows.removeAll { $0 === window }
    }
}
