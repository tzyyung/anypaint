import AppKit
import AVKit
import UniformTypeIdentifiers

/// 動畫截圖預覽：AVPlayerView 循環播放母帶＋〔存 GIF〕〔存 APNG〕〔存 MP4〕〔存 WebP，僅偵測到
/// img2webp 時〕〔拍快照〕〔開啟位置〕〔丟棄〕。
/// 視窗骨架/持有慣例對照 `ScrollPreviewWindow`（該檔 5-45 行的骨架、174-216 行的
/// controller 持有／forget／present 慣例）——這裡不重複解釋，只記差異。
final class RecordPreviewWindow: NSWindow {
    /// 內容區最小尺寸：鈕數量隨環境變（有沒有偵測到 img2webp）——量**最多鈕**的情況（設計文件
    /// §1.7b）。實測（同 ScrollPreviewWindow.minContentWidth 的量法——NSButton.sizeToFit() 量
    /// 真實寬度，不是憑印象估）：
    /// - 7 顆鈕（無 img2webp）：剪裁/存GIF/存APNG/存MP4/拍快照/開啟位置/丟棄，依序寬
    ///   50/61/77/68/63/76/50pt，button row 本身需要 ~517pt。
    /// - 8 顆鈕（有 img2webp，多一顆「存 WebP」76pt）：依序寬
    ///   50/61/77/68/76/63/76/50pt，加 stack spacing 7×8pt 與左右邊距 12×2，button row 本身
    ///   需要 601pt——這是較大的那個情況，下限跟著它調。
    /// 把下限調到 624，留 ~23pt 安全邊際（同等級於先前 480→540 的 23pt 裕度）；7 顆鈕情境下
    /// 這個下限比它本身需要的還寬，不影響顯示（只是空按鈕列右側多一點留白）。
    static let minContentWidth: CGFloat = 624
    static let minContentHeight: CGFloat = 240

    private let movieURL: URL
    private let vars: [String: String]
    private let output: RecordOutputService
    private let pinboard: PinboardService
    private let captureScale: CGFloat      // 擷取螢幕 backingScaleFactor（GIF 降 1x 用；單位：像素/點）
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?    // 循環播放：AVPlayerLooper 官方做法，必須持有否則不循環
    private var playerView: AVPlayerView?  // 剪裁鈕要問 canBeginTrimming／呼叫 beginTrimming，需持有
    // img2webp 偵測結果：視窗建構時偵測一次（不是每次按鈕都重新掃檔案系統），非 nil 才會在
    // buildUI() 加入「存 WebP」鈕——沒偵測到就不出現任何東西（不出灰鈕不出錯誤，設計文件
    // §1.7b：沒有內建 WebP 編碼器可退，跟 gifski 的「找不到就回退內建」語意不同）。
    private let img2webpPath: String?
    private var isExporting = false        // 見 close() 的說明：匯出（GIF 或 APNG 或 WebP）中擋下關閉
    private var isTrimming = false         // trim overlay 顯示中擋下關閉（見 close()，不給強制關閉逃生口）
    private var lastSavedURL: URL?         // 最近一次存 GIF/APNG/MP4 成功的路徑；「開啟位置」用
    // 剪裁範圍：nil＝未剪裁（匯出整段母帶，行為不變）；非 nil＝三種匯出格式都套用這段範圍
    // （設計文件 §1.6）。母帶絕對時間軸座標（與 player.currentItem 的
    // reversePlaybackEndTime/forwardPlaybackEndTime 同一單位），不是相對剪裁前次結果的偏移。
    private var trimRange: CMTimeRange?
    private let statusLabel = NSTextField(labelWithString: "")
    private let openLocationButton = NSButton(title: "開啟位置", target: nil, action: nil)
    private var buttons: [NSButton] = []
    weak var controller: RecordPreviewWindowController?

    init(movieURL: URL, vars: [String: String], output: RecordOutputService, pinboard: PinboardService,
         captureScale: CGFloat, contentRect: NSRect) {
        self.movieURL = movieURL
        self.vars = vars
        self.output = output
        self.pinboard = pinboard
        self.captureScale = captureScale
        self.img2webpPath = Img2webpEngine.detect()
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
        // .inline（非 .minimal）：原生控制列含可拖曳的進度條（scrubber），讓使用者能拖到任意
        // 時刻——「拍快照」要對著使用者選定的那一格出手，沒有可拖進度條就只能拍到目前播放位置。
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false

        // player 建立：AVQueuePlayer + AVPlayerLooper 是 Apple 文件的無縫循環官方做法；
        // looper 若只當區域變數，函式結束就被釋放，循環會靜默停止（已在 looper 屬性宣告處記過）。
        let item = AVPlayerItem(url: movieURL)
        let q = AVQueuePlayer()
        looper = AVPlayerLooper(player: q, templateItem: item)
        playerView.player = q
        q.play()
        player = q
        self.playerView = playerView

        // 拖曳出 MP4（設計文件 §1.4）：掛在 contentOverlayView，不是自己疊一層蓋住整個
        // playerView 再算控制列高度來避開。已查 header（AVKit.framework `AVPlayerView.h`
        // 84-88 行）：contentOverlayView 官方定義就是「video content 與 controls 之間」
        // 的掛載點——用它天生只蓋影像區、不蓋 .inline 控制列／scrubber，不需要寫死避開
        // 高度（brief 點名的三案之一，這裡是查完 header 後最乾淨的選擇；理由與否決的另兩案
        // 見 task-7-report.md）。若拿不到（理論上 player 已設定就會有，防禦性處理）就整個
        // 放棄拖曳功能，不影響其他既有按鈕。
        if let overlay = playerView.contentOverlayView {
            let dragView = DragOriginView()
            dragView.owner = self
            dragView.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(dragView)
            NSLayoutConstraint.activate([
                dragView.topAnchor.constraint(equalTo: overlay.topAnchor),
                dragView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                dragView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                dragView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }

        let trimButton = NSButton(title: "剪裁", target: self, action: #selector(trimAction))
        trimButton.toolTip = "拖動原生剪裁列選取時間段，之後三種匯出格式都套用這段範圍"
        let saveGifButton = NSButton(title: "存 GIF", target: self, action: #selector(saveGifAction))
        saveGifButton.toolTip = "匯出為 GIF 並存到預設資料夾"
        let saveApngButton = NSButton(title: "存 APNG", target: self, action: #selector(saveApngAction))
        saveApngButton.toolTip = "匯出為全彩 APNG 並存到預設資料夾（檔案較大，通用貼圖支援度不一）"
        let saveMp4Button = NSButton(title: "存 MP4", target: self, action: #selector(saveMp4Action))
        saveMp4Button.toolTip = "複製母帶存成 MP4（不影響之後再匯出 GIF/APNG）"
        // 「存 WebP」只在偵測到 img2webp 時才建立、才加進 buttons/buttonRow（設計文件 §1.7b：
        // 沒有內建 WebP 編碼器可退，沒裝就不出現，不是灰鈕）。
        let saveWebpButton: NSButton? = img2webpPath.map { _ in
            let b = NSButton(title: "存 WebP", target: self, action: #selector(saveWebpAction))
            b.toolTip = "匯出為 WebP 並存到預設資料夾（需要外部 img2webp，已偵測到）"
            return b
        }
        let snapshotButton = NSButton(title: "拍快照", target: self, action: #selector(snapshotAction))
        snapshotButton.toolTip = "把目前播放位置的畫面複製到剪貼簿（⌘⇧V 可貼成浮動貼圖）"
        openLocationButton.target = self
        openLocationButton.action = #selector(openLocationAction)
        openLocationButton.toolTip = "在 Finder 開啟並選取剛存的檔案"
        openLocationButton.isEnabled = false   // 還沒存過檔前無路徑可開
        let discardButton = NSButton(title: "丟棄", target: self, action: #selector(discardAction))
        discardButton.toolTip = "丟掉這段動畫截圖並關窗（需確認）"
        buttons = [trimButton, saveGifButton, saveApngButton, saveMp4Button] + [saveWebpButton].compactMap { $0 }
            + [snapshotButton, openLocationButton, discardButton]
        for b in buttons {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        // 「丟棄」刻意不給快捷鍵：破壞性動作（同 ScrollPreviewWindow.discardAction 的理由）。

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: buttons)
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

    /// 剪裁：原生 trim UI（設計文件 §1.6）。已查 AVKit header（`AVPlayerView.h`）：
    /// `canBeginTrimming` 唯讀屬性、`beginTrimmingWithCompletionHandler:` 只回傳
    /// `.okButton`/`.cancelButton`，**不直接給範圍**——選取結果要另外讀。已查 AVFoundation
    /// header（`AVPlayerItem.h`）：`forwardPlaybackEndTime`/`reversePlaybackEndTime` 是唯一
    /// 暴露在 `AVPlayerItem` 上的可編輯範圍屬性；header 本身沒有寫「這就是 trim UI 寫回的地方」
    /// （header 沒把兩者關聯起來講），但這是 AVKit 官方 trim UI 對外溝通選取結果的既定慣例
    /// （長年公開範例／文件如此），也是 `AVPlayerItem` 上唯一能表達「子範圍」的 API——
    /// 沒有第二條路可查。**這段標記為待實機驗證**：OK 之後兩個屬性的值是否確實反映使用者
    /// 選取範圍，需要在真機拖過 trim UI 才能確認。
    ///
    /// Looper 相容性風險（設計文件 §1.6）：`AVQueuePlayer`＋`AVPlayerLooper` 在無縫循環時會
    /// 準備／輪替 currentItem 的複本，`canBeginTrimming`／trim 結果讀取是否受影響無法在無 UI
    /// 環境確認。這裡先實作「直接對現有 looper 播放呼叫 beginTrimming」的路徑（brief 核可的
    /// 第一案）；若實機測出 `canBeginTrimming` 為 false 或選取範圍讀不對，fallback 方案＝
    /// trim 前把 `looper` 設 nil、改單一 `AVPlayerItem` 播放（`actionAtItemEnd = .none` ＋監聽
    /// `AVPlayerItemDidPlayToEndTimeNotification` 手動 seek 到 0 恢復單曲循環），trim 完成後
    /// 视情况重建 looper。两案都记录在报告，尚未走 fallback。
    @objc private func trimAction() {
        guard let playerView, let player, playerView.canBeginTrimming else {
            statusLabel.stringValue = "此播放器不支援剪裁"
            return
        }
        // trim overlay 蓋在播放器上時鎖住其他按鈕（review minor finding）：原生剪裁 UI 顯示中
        // 使用者不該還按得下丟棄／存檔等鈕。completion（OK 或 Cancel 都會呼叫一次）用 defer
        // 解鎖，兩條結果路徑共用同一份收尾，不必在每個分支各複製一次。
        setButtonsEnabled(false)
        isTrimming = true   // 見 close() 的守衛：trim overlay 顯示中不給關窗，不論強制與否
        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            defer {
                self.isTrimming = false
                self.setButtonsEnabled(true)
                self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
            }
            guard result == .okButton, let item = player.currentItem else { return }
            // reversePlaybackEndTime 無效＝使用者沒動起點（維持 0）；forwardPlaybackEndTime
            // 無效＝沒動終點（維持母帶全長）——兩者預設值都是 kCMTimeInvalid（見 header）。
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            self.trimRange = CMTimeRange(start: start, end: end)
            self.statusLabel.stringValue = String(format: "已剪裁 %.1fs–%.1fs，匯出將套用",
                                                  start.seconds, end.seconds)
        }
        // 取消：AVKit trim UI 的既定行為是取消時不套用變更，這裡不用額外處理——不更新
        // `trimRange` 就等於維持剪裁前的狀態（第一次剪裁前＝nil／已剪裁過＝上次的範圍）。
        // 再按「剪裁」可重剪：beginTrimming 用 currentItem 目前的
        // forwardPlaybackEndTime/reversePlaybackEndTime 當 trim UI 初始選取範圍，第二次呼叫
        // 因此會從上次的結果繼續調整，覆蓋 `trimRange` 屬性即可，不需要額外的「清除剪裁」入口。
    }

    /// 存 GIF：匯出中停用所有按鈕＋statusLabel 顯示進度；完成後存到快速儲存路徑。
    @objc private func saveGifAction() { exportAndSave(format: .gif, label: "GIF") }

    /// 存 APNG：與存 GIF 共用同一套匯出／存檔骨架，差別只在 format／副檔名／文案
    /// （設計文件 §1.5：APNG 全彩、無 256 色調色盤損失，檔案通常較小但通用貼圖支援度不一）。
    @objc private func saveApngAction() { exportAndSave(format: .apng, label: "APNG") }

    /// 存 WebP：只有偵測到 img2webp 才會建到按鈕列上，因此這裡呼叫得到代表 `img2webpPath`
    /// 一定非 nil；guard 仍防禦性寫（同檔案其他 action 的一貫風格），理論上不會走到 else。
    /// 不共用 `exportAndSave`（那個骨架綁死 `AnimationFormat`／`GifExporter.export`，WebP
    /// 走的是完全獨立的 `GifExporter.exportWebP` 且**沒有回退**，語意分岔點夠多，另外一份
    /// 更直白，不必為了共用硬塞一層抽象）。
    @objc private func saveWebpAction() {
        guard let img2webpPath else { return }
        isExporting = true
        setButtonsEnabled(false)
        statusLabel.stringValue = "WebP 匯出中… 0%"
        let tmpURL = movieURL.deletingPathExtension().appendingPathExtension("webp")
        let fps = Double(AppSettings.recordGifFps)
        GifExporter.exportWebP(movieURL: movieURL, to: tmpURL, pointScale: captureScale,
                               fps: fps, timeRange: trimRange, img2webpPath: img2webpPath,
                               progress: { [weak self] p in
                                   self?.statusLabel.stringValue = "WebP 匯出中… \(Int(p * 100))%"
                               },
                               completion: { [weak self] result in
                                   guard let self else { return }
                                   self.isExporting = false
                                   self.setButtonsEnabled(true)
                                   switch result {
                                   case .success:
                                       let saved = self.output.saveCopy(from: tmpURL, ext: "webp", vars: self.vars)
                                       try? FileManager.default.removeItem(at: tmpURL)
                                       if let saved { self.lastSavedURL = saved }
                                       self.statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" }
                                           ?? "WebP 存檔失敗"
                                   case .failure(let e):
                                       // 不回退（設計文件 §1.7b：沒有內建 WebP 編碼器）——直接顯示錯誤，
                                       // GifExporter.exportWebP 內部已經把同款診斷寫進 RecordSessionLog。
                                       self.statusLabel.stringValue = "WebP 匯出失敗：\(e)"
                                   }
                                   self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
                               })
    }

    /// GIF／APNG 共用的匯出＋存檔流程：fps 讀 `AppSettings.recordGifFps`（設計文件 §1.2——
    /// 兩種格式共用同一個 fps 設定項，不需要分開的 APNG fps）。`label` 只用於狀態列文案，
    /// 副檔名／UTType 由 `format.fileExtension` 與 `GifExporter` 內部決定。
    private func exportAndSave(format: AnimationFormat, label: String) {
        isExporting = true
        setButtonsEnabled(false)
        statusLabel.stringValue = "\(label) 匯出中… 0%"
        let ext = format.fileExtension
        let tmpURL = movieURL.deletingPathExtension().appendingPathExtension(ext)
        let fps = Double(AppSettings.recordGifFps)
        GifExporter.export(movieURL: movieURL, to: tmpURL, pointScale: captureScale,
                           fps: fps, format: format, timeRange: trimRange,
                           progress: { [weak self] p in
                               self?.statusLabel.stringValue = "\(label) 匯出中… \(Int(p * 100))%"
                           },
                           completion: { [weak self] result in
                               guard let self else { return }
                               self.isExporting = false
                               self.setButtonsEnabled(true)
                               switch result {
                               case .success:
                                   let saved = self.output.saveCopy(from: tmpURL, ext: ext, vars: self.vars)
                                   try? FileManager.default.removeItem(at: tmpURL)
                                   if let saved { self.lastSavedURL = saved }
                                   self.statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" }
                                       ?? "\(label) 存檔失敗"
                               case .failure(let e):
                                   self.statusLabel.stringValue = "\(label) 匯出失敗：\(e)"
                               }
                               // 「開啟位置」不是跟著上面 setButtonsEnabled(true) 無條件打開：
                               // 還沒存過檔（lastSavedURL 是 nil）就不該讓使用者按得下去——
                               // 沒有路徑可開，按了也只是 guard 直接 return，但那是「看起來能按
                               // 卻沒反應」，比「本來就是灰的」更讓人困惑。
                               self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
                           })
    }

    /// 存 MP4：無剪裁沿用原本的零轉檔 copy（不 move——之後可能還要匯 GIF，母帶得留著）；
    /// 有剪裁則走 `AVAssetExportSession` + `AVAssetExportPresetPassthrough` 切 `timeRange`
    /// 匯到暫存再 saveCopy（設計文件 §1.6）。已查 header（`AVAssetExportSession.h`）：
    /// - `timeRange` 屬性（`AVAssetExportSessionDurationAndLength` category）：預設
    ///   `kCMTimeZero..kCMTimePositiveInfinity`（全長），沒有任何一段文件說 passthrough 不支援
    ///   設定它——與其他 preset 一致對待。
    /// - `AVAssetExportPresetPassthrough`：「media of all tracks passed through exactly as
    ///   stored」，不重編碼；`timeRange` 只是篩選要輸出哪一段樣本，兩者互不衝突。
    /// - 匯出 API：`export(to:as:) async throws`（macOS 15+ 才有，Package.swift 目前
    ///   deployment target 是 macOS 14——用了會過不了可用性檢查）vs. 舊式
    ///   `exportAsynchronously(completionHandler:)`（`API_DEPRECATED_WITH_REPLACEMENT` 起始
    ///   版本正是 macOS 15）。已用最小重現專案在 `.macOS(.v14)` target 下實測：呼叫
    ///   `exportAsynchronously(completionHandler:)` **零 warning**（Swift 的 deprecated
    ///   availability 只在 deployment target ≥ 該版本時才生效，14 < 15 不觸發）——因此這裡
    ///   選舊式 API，不是偷懶，是查完＋量完的結論；deployment target 升到 15 之後這裡要換
    ///   `export(to:as:)`。
    @objc private func saveMp4Action() {
        guard let trimRange else {
            let saved = output.saveCopy(from: movieURL, ext: "mp4", vars: vars)
            if let saved {
                lastSavedURL = saved
                openLocationButton.isEnabled = true
            }
            statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" } ?? "MP4 存檔失敗"
            return
        }
        isExporting = true
        setButtonsEnabled(false)
        statusLabel.stringValue = "MP4 剪裁匯出中…"
        // 暫存檔沿用 RecordOutputService.tempMovieURL()：檔名固定「anypaint-record-<uuid>.mp4」，
        // 與母帶同前綴，app 下次啟動的 cleanupStaleTempFiles() 掃得到（若這次強制關閉/當掉沒清到）。
        let tmpURL = output.tempMovieURL()
        Task { [weak self] in
            guard let self else { return }
            // defer：不管走哪個出口（建 session 失敗的 early return、匯出失敗、匯出成功），
            // 「解除匯出中鎖定＋校正開啟位置鈕」都要做到——review 抓到的 bug 正是 early return
            // 那個出口漏了這行，讓「還沒存過檔卻能按開啟位置」（R1 已修過一次的同型問題）重演。
            // defer 保證所有出口一致，不必在每個 return 前手動複製這兩行。
            defer {
                self.isExporting = false
                self.setButtonsEnabled(true)
                self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
            }
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: self.movieURL),
                                                     presetName: AVAssetExportPresetPassthrough) else {
                self.statusLabel.stringValue = "MP4 剪裁匯出失敗：無法建立匯出工作階段"
                return
            }
            session.outputURL = tmpURL
            session.outputFileType = .mp4
            session.timeRange = trimRange
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            if session.status == .completed {
                let saved = self.output.saveCopy(from: tmpURL, ext: "mp4", vars: self.vars)
                try? FileManager.default.removeItem(at: tmpURL)
                if let saved { self.lastSavedURL = saved }
                self.statusLabel.stringValue = saved.map { "已存 \($0.lastPathComponent)" }
                    ?? "MP4 存檔失敗"
            } else {
                try? FileManager.default.removeItem(at: tmpURL)
                self.statusLabel.stringValue = "MP4 剪裁匯出失敗：\(session.error?.localizedDescription ?? "未知錯誤")"
            }
        }
    }

    /// 拍快照：把播放器目前所在時刻的畫面複製到剪貼簿。不受 `lastSavedURL` 影響（跟存不存過檔
    /// 無關，任何時刻都能拍），GIF 匯出中則跟其他鈕一起被 `setButtonsEnabled(false)` 停用
    /// （它就在 `buttons` 陣列裡，沒有特殊路徑）。**也不受 `trimRange` 影響**（設計文件
    /// §1.4/§1.6：拍快照本來就是對「播放器目前所在時刻」出手，取的是 `player.currentTime()`，
    /// 跟有沒有剪裁、剪裁範圍是什麼完全無關；日後的預覽拖曳出檔案（§1.4）同理給整段母帶，
    /// 也不吃 `trimRange`）。
    ///
    /// 用 `AVAssetImageGenerator.image(at:)`（macOS 13+ 的 async API，`generateCGImageAsynchronously
    /// ForTime:completionHandler:` 的 Swift 覆寫；已對照 SDK header 的 `NS_REFINED_FOR_SWIFT_ASYNC`
    /// 確認簽章，不是憑印象）——不用已 deprecated 的同步 `copyCGImage(at:actualTime:)`，零 warning
    /// 是硬約束。容忍度設 `.zero`：拍快照要對到使用者在 scrubber 上選的那一格，不要讓 generator
    /// 為了效能就近抓鄰近格。輸出走 `PinboardService.copyLarge`（與 ScrollPreviewWindow.copyAction
    /// 同款），scale 用 `captureScale`——與整個檔案的「像素↔點」換算基準一致（同 GIF 降 1x 的道理）。
    @objc private func snapshotAction() {
        guard let player else { return }
        let time = player.currentTime()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await generator.image(at: time)
                self.pinboard.copyLarge(cgImage: result.image, scale: self.captureScale)
                self.statusLabel.stringValue = "快照已複製（⌘⇧V 可貼出）"
            } catch {
                self.statusLabel.stringValue = "拍快照失敗：\(error)"
            }
        }
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
        // 剪裁中關窗：不給強制關閉逃生口，跟下面 isExporting 的處理不同——trim 隨時可以讓
        // 使用者自己按原生剪裁列的「完成」或「取消」結束，不像匯出可能因為母帶損毀等原因讓
        // 背景 Task 卡死、除了強制關閉別無他法，因此這裡不需要（也不該給）逃生口。
        if isTrimming {
            let alert = NSAlert()
            alert.messageText = "剪裁進行中——請先按剪裁列的完成或取消"
            alert.addButton(withTitle: "好")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        // 匯出中（GIF 或 APNG）關窗：GifExporter 沒有 cancel/timeout，detached Task 可能卡死
        // （例如母帶損毀導致 reader 卡在某個狀態）——若只「擋下關閉、要求等待」而不給逃生口，
        // 使用者除了強制砍掉整個 app 別無他法。因此提供第二顆「強制關閉」鈕，預設鈕仍是
        // 「繼續等待」（NSAlert 第一顆鈕＝預設、Enter 觸發，避免誤觸強制關閉）。
        //
        // 強制關閉的安全性（三點都已個別確認，不是假設）：
        // 1. 被拋下的 GifExporter.export 背景 Task 會繼續跑到完成或失敗——它的 completion
        //    closure 用 [weak self]（見 exportAndSave），視窗這時已 forget/可能已釋放，
        //    self 為 nil 時 guard let self else { return } 直接 no-op，不會 crash。
        // 2. movieURL 在強制關閉時會被下面的 removeItem 刪掉，但 AVAssetReader 對它的檔案
        //    描述符已經開啟——APFS／POSIX 的 unlink 語意是「目錄項目消失，已開啟的 fd 仍可讀到
        //    刪除前的內容」，reader 不會因此中途壞掉；真正會發生的頂多是讀到 EOF 提前結束或
        //    reader.status 轉 .failed → GifExporter 走 completion(.failure(...))，一樣是
        //    no-op（見上一點）。
        // 3. 暫存檔（exportAndSave 裡的 tmpURL，GIF 或 APNG）殘留不會變成孤兒垃圾：tmpURL 是
        //    movieURL（RecordOutputService.tempMovieURL() 產出，檔名固定為
        //    "anypaint-record-<uuid>.mp4"）換副檔名而來，檔名前綴「anypaint-record-」不變，
        //    落在同一個暫存目錄——app 下次啟動時 RecordOutputService.cleanupStaleTempFiles()
        //    照前綴掃描刪除，會連同這個殘留 tmpURL 一起清掉（已對照該函式的比對邏輯確認）。
        if isExporting {
            let alert = NSAlert()
            alert.messageText = "匯出中，請稍候完成後再關閉"
            alert.informativeText = "強制關閉會捨棄這次匯出，母帶也會一併刪除。"
            alert.addButton(withTitle: "繼續等待")
            alert.addButton(withTitle: "強制關閉")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }   // 繼續等待：不關窗
            isExporting = false   // 選了強制關閉：解除擋關閉旗標，走下面的正常收尾
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

    // MARK: - 拖曳出 MP4

    /// 疊在 contentOverlayView 整個範圍的拖曳起點：只轉發拖曳手勢，不吃其他事件——沒
    /// override 的滑鼠事件（例如右鍵選單）依 NSResponder 預設行為往下一個 responder 傳，
    /// 不會被這層擋住（**待實機驗證**：右鍵選單/視訊分析選取等 AVPlayerView 原生手勢
    /// 是否真的穿透，command line 環境驗不了）。
    ///
    /// mouseDragged 累積位移超過閾值（4pt）才真的呼叫 `beginDraggingSession`：單純點擊
    /// 影像區（例如以後若加點擊手勢）不會被誤判成拖曳意圖。
    ///
    /// 嵌在 RecordPreviewWindow 內部：Swift 的 `private` 存取範圍涵蓋外層型別本身，這裡才
    /// 讀得到 `owner.movieURL`（同檔案作用域，不必額外開放存取層級）。
    private final class DragOriginView: NSView, NSDraggingSource {
        weak var owner: RecordPreviewWindow?
        private var mouseDownLocation: NSPoint?

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation, let owner else { return }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard dx * dx + dy * dy >= 16 else { return }   // 4pt 位移閾值
            mouseDownLocation = nil

            // 拖曳提供整段母帶：不受 trimRange／isExporting 影響（設計文件 §1.4/§1.6，
            // 同 snapshotAction 的說明——讀母帶跟匯出不衝突，母帶在關閉視窗前都在）。
            let provider = NSFilePromiseProvider(fileType: UTType.mpeg4Movie.identifier,
                                                 delegate: owner)
            // writePromiseTo 是 NS_SWIFT_NONISOLATED（見 AppKit header），執行時不在
            // MainActor 上、不能碰 owner 的任何 MainActor 隔離狀態——來源路徑改走 userInfo
            // 傳遞，讀寫都不必跨 actor。
            provider.userInfo = owner.movieURL
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: .mpeg4Movie)
            let iconSize: CGFloat = 64
            item.setDraggingFrame(
                NSRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2,
                       width: iconSize, height: iconSize),
                contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownLocation = nil
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}

/// writePromiseTo 的背景複製佇列：母帶可能不小（螢幕錄製），若卡在 delegate 預設的
/// mainOperationQueue（等於主執行緒）會頂到 UI（CLAUDE.md 記過的教訓：I/O 不可卡主執行緒）。
/// 宣告在檔案作用域（不是 RecordPreviewWindow 的成員）：已查 AppKit header——
/// `operationQueueForFilePromiseProvider:` 標的其實是 `NS_SWIFT_UI_ACTOR`（等於 MainActor），
/// 只有 `writePromiseTo` 才是 `NS_SWIFT_NONISOLATED`。掛在檔案作用域的理由是
/// `writePromiseTo` 實際執行時就在這顆 queue 上、不在 MainActor——要能跨隔離讀到它，
/// 就不能宣告成 RecordPreviewWindow 的成員（那會被 MainActor 隔離，`writePromiseTo` 讀不到）。
private let dragPromiseCopyQueue = OperationQueue()

/// 拖曳出 MP4：`NSFilePromiseProviderDelegate` conformance（設計文件 §1.4）。
extension RecordPreviewWindow: NSFilePromiseProviderDelegate {
    /// 檔名：manualNameTemplate 展開（同「另存為」共用的樣板，見
    /// `CaptureOutputService.saveWithPanel`）→ 剝 .png → 補 .mp4。這個 delegate 方法標了
    /// `NS_SWIFT_UI_ACTOR`（見 header），在 Swift 端等於 @MainActor，可以安心讀
    /// self.vars／AppSettings。
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        let now = Date()
        var name = FilenameTemplate.expand(AppSettings.manualNameTemplate, date: now, vars: vars)
        if FilenameTemplate.hasPNGExtension(name) { name = String(name.dropLast(4)) }
        name = FilenameTemplate.ensuringExtension(name, ext: "mp4")
        // degenerate 樣板（清洗後全空，例如樣板本身只由非法字元組成）會讓上面剝完副檔名的
        // 檔名段變空，補完 .mp4 就成了純粹的「.mp4」——在 Finder 顯示成隱藏檔。fallback 仿
        // RecordOutputService.saveCopy 的模式：展開 defaultName、剝 .png、補正確副檔名，交給
        // ensuringMeaningfulFilename 判斷原檔名是否有意義、需不需要代打。
        let fallback = FilenameTemplate.ensuringExtension(
            String(FilenameTemplate.expand(FilenameTemplate.defaultName, date: now, vars: vars).dropLast(4)),
            ext: "mp4")
        name = FilenameTemplate.ensuringMeaningfulFilename(name, fallbackName: fallback, ext: "mp4")
        // 只能回傳純檔名（NSFilePromiseProvider 的契約）；manualNameTemplate 本來就是純檔名
        // （AppSettings 的文件註記），這裡仍防禦性取 lastPathComponent，避免萬一樣板含 /
        // 被誤判成目錄。
        return (name as NSString).lastPathComponent
    }

    /// 母帶複製到拖曳目的地：這個 delegate 方法標了 `NS_SWIFT_NONISOLATED`（見 header），
    /// 執行時不在 MainActor 上——來源路徑從 `userInfo` 讀（見 DragOriginView.mouseDragged
    /// 的說明），不碰 self 的任何 MainActor 隔離狀態。
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let source = filePromiseProvider.userInfo as? URL else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// 指到背景佇列（見 dragPromiseCopyQueue 的說明），不落在預設的 mainOperationQueue。
    /// Swift 端方法名是 `operationQueue(for:)`（ObjC `operationQueueForFilePromiseProvider:`
    /// 舊名在 Swift 3 就被 rename 掉了——編譯器直接報錯點名新名字，不是憑印象猜的）。
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        dragPromiseCopyQueue
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
    private let pinboard: PinboardService
    private var windows: [RecordPreviewWindow] = []

    public init(output: RecordOutputService, pinboard: PinboardService) {
        self.output = output
        self.pinboard = pinboard
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

        let window = RecordPreviewWindow(movieURL: movieURL, vars: vars, output: output, pinboard: pinboard,
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
