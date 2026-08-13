import AppKit
import AVKit
import UniformTypeIdentifiers

/// 動畫截圖預覽：AVPlayerView 循環播放母帶。按鈕列改成 icon＋下方說明行，視覺語言完整沿用
/// `SelectionToolbar`（框選標註工具列，該檔 197-216 行的 icon 鈕建構、294-307 行的 hover 說明
/// 機制、209-216 行的分隔線做法——這裡不重複解釋，只記差異，見 `HoverHintRow` 與 `buildUI`
/// 的註解）。分兩群：編輯〔剪裁 `scissors`〕〔還原剪裁 `arrow.uturn.backward`〕
/// 〔拍快照 `camera`〕｜分隔線｜輸出〔存檔▾ `square.and.arrow.down`：選單收納存 GIF／存 APNG／
/// 存 MP4／存 WebP（僅偵測到 img2webp 時在選單多這項）〕〔開啟位置 `folder`〕〔丟棄 `trash`〕。
/// 視窗骨架/持有慣例對照 `ScrollPreviewWindow`（該檔 5-45 行的骨架、174-216 行的
/// controller 持有／forget／present 慣例）——這裡不重複解釋，只記差異。
final class RecordPreviewWindow: NSWindow {
    /// 內容區最小尺寸：icon 鈕比先前的文字按鈕窄很多，大幅下降（500→260）。實測（同慣例，
    /// icon 鈕固定 26×22pt——照抄 `SelectionToolbar.configureSymbolButton` 的固定尺寸，不是
    /// sizeToFit() 量出來的，那份參照本身就是「不管符號長怎樣，尺寸一律固定」的設計）：
    /// 喇叭/剪裁/還原剪裁/拍快照/開啟位置/丟棄各 26pt，分隔線 1pt；存檔▾（icon＋系統原生下拉箭頭）
    /// 量到 30pt——這是本檔唯一新增的組合控件，不是抄來的，用一次性渲染腳本量出「icon 與箭頭
    /// 不擠在一起」的寬度（過程見 fix round 報告）。排版元件共 8 個（6 顆按鈕＋1 分隔線＋1
    /// 存檔▾——喇叭鈕算進這顆常數：即使沒有音軌時它是 `isHidden`，`minContentWidth` 是視窗
    /// 尺寸下限，要用「所有按鈕都顯示」的最寬情況去算，不能假設它不在），`SelectionToolbar.toolsRow`
    /// 用的 spacing 是 4pt（不是舊版文字按鈕列的 8pt），這裡跟著改：26×6+1+30=187，
    /// 7 個間隔×4pt=28，hoverRow 本身需要 187+28=215pt。加 content 左右邊距 12×2=24 → 239pt。
    /// 安全邊際抓 11pt（喇叭鈕加入後從前一輪的 41pt 被吃掉大半——這輪沒有新增「這是本檔第一次用
    /// 某種新佈局」那種不確定性，250pt 這個常數維持不動，邊際數字純粹是新增一顆按鈕後重算出來的
    /// 結果，不是刻意留寬）→ 250pt。
    static let minContentWidth: CGFloat = 250
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
    // buildUI() 的「存檔」下拉選單裡加「存 WebP」這一項——沒偵測到就不出現任何東西（不出
    // 灰選項不出錯誤，設計文件 §1.7b：沒有內建 WebP 編碼器可退，跟 gifski 的「找不到就回退
    // 內建」語意不同）。
    private let img2webpPath: String?
    private var isExporting = false        // 見 close() 的說明：匯出（GIF 或 APNG 或 WebP）中擋下關閉
    private var isTrimming = false         // trim overlay 顯示中擋下關閉（見 close()，不給強制關閉逃生口）
    private var lastSavedURL: URL?         // 最近一次存 GIF/APNG/MP4 成功的路徑；「開啟位置」用
    // 剪裁範圍：nil＝未剪裁（匯出整段母帶，行為不變）；非 nil＝三種匯出格式都套用這段範圍
    // （設計文件 §1.6）。母帶絕對時間軸座標（與 player.currentItem 的
    // reversePlaybackEndTime/forwardPlaybackEndTime 同一單位），不是相對剪裁前次結果的偏移。
    private var trimRange: CMTimeRange?
    // 說明/狀態行（`statusLabel`）現在身兼兩職（設計文件外、team-lead 這輪核可的自行實作，
    // `SelectionToolbar.hintLabel` 沒有這個需求——它的說明列只有「hover 說明」一種角色，
    // 離開時回復固定預設文字即可；這裡的同一行還要顯示匯出進度／已存檔名／已剪裁範圍這些
    // *有狀態* 的訊息，離開 hover 不能把這些訊息蓋掉）：`lastStatusMessage` 記最後一次真正的
    // 狀態訊息，hover 進某顆鈕時 `statusLabel` 暫時顯示它的說明文字，滑鼠離開（或本來就沒
    // hover 在任何鈕上）就顯示 `lastStatusMessage`。所有「设定状态」的地方一律呼叫
    // `setStatus(_:)`（見該函式），不要直接寫 `statusLabel.stringValue`。
    private var lastStatusMessage = ""
    private let statusLabel = NSTextField(labelWithString: "")
    private let restoreTrimButton = NSButton(title: "還原剪裁", target: nil, action: nil)
    private let openLocationButton = NSButton(title: "開啟位置", target: nil, action: nil)
    // 喇叭切換鈕：僅當母帶有音軌才顯示（見 buildUI 建立處與 detectAudioTrack 的說明）。
    private let audioButton = NSButton(title: "靜音切換", target: nil, action: nil)
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
        // hover 說明機制需要 mouseMoved 事件才會送達 tracking area（同 SelectionOverlayController.swift:21
        // 的說明：NSTrackingArea 的 `.mouseMoved` 選項要求視窗顯式開啟這個旗標，`.mouseEnteredAndExited`
        // 本身不需要，但我們兩者都要用）。
        acceptsMouseMovedEvents = true
        buildUI()
        detectAudioTrack()
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
        q.isMuted = true   // 循環播放不吵——spec §0，喇叭鈕（見下）讓使用者自行取消靜音
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

        let hoverRow = HoverHintRow()
        hoverRow.translatesAutoresizingMaskIntoConstraints = false
        // 離開所有控件（或本來就沒 hover 在任何控件上）：回復最後一次真正的狀態訊息，不是
        // SelectionToolbar 那種固定預設文字（見 lastStatusMessage 宣告處的說明）。
        hoverRow.onHint = { [weak self] hint in
            guard let self else { return }
            self.statusLabel.stringValue = hint ?? self.lastStatusMessage
        }

        // 喇叭切換鈕：不屬於下面「編輯」／「輸出」任一群，獨立放在最左（見 detectAudioTrack
        // 的說明：只有偵測到母帶含音軌才會顯示，一開始先隱藏）。player 建立處已把 q.isMuted
        // 設成 true（循環播放不吵——spec §0），這顆鈕讓使用者自行取消靜音。圖示初值對應
        // 靜音狀態（speaker.slash），toggleAudio() 切換時同步換圖示。
        configureSymbolButton(audioButton, symbol: "speaker.slash", accessibilityLabel: "取消靜音",
                              action: #selector(toggleAudio))
        setHelp("預覽預設靜音，點一下切換播放聲音", for: audioButton, in: hoverRow)
        audioButton.isHidden = true   // 母帶是否含音軌要 async load 才知道，見 detectAudioTrack()

        // 左群（編輯）：剪裁／還原剪裁／拍快照。三顆都用 configureSymbolButton（照抄
        // SelectionToolbar.configureSymbolButton 的固定尺寸／borderless／cornerRadius 做法，
        // 差異只在不設 contentTintColor——SelectionToolbar 疊在螢幕內容上要固定白色圖示，
        // RecordPreviewWindow 是普通視窗、跟著系統外觀走，留給預設值自動適配淺色/深色模式）。
        let trimButton = NSButton()
        configureSymbolButton(trimButton, symbol: "scissors", accessibilityLabel: "剪裁",
                              action: #selector(trimAction))
        setHelp("拖動原生剪裁列選取時間段，之後三種匯出格式都套用這段範圍", for: trimButton, in: hoverRow)

        configureSymbolButton(restoreTrimButton, symbol: "arrow.uturn.backward", accessibilityLabel: "還原剪裁",
                              action: #selector(restoreTrimAction))
        setHelp("清除剪裁範圍，恢復播放與匯出整段母帶", for: restoreTrimButton, in: hoverRow)
        restoreTrimButton.isEnabled = false   // 還沒剪裁過（trimRange 為 nil）沒有可還原的東西

        let snapshotButton = NSButton()
        configureSymbolButton(snapshotButton, symbol: "camera", accessibilityLabel: "拍快照",
                              action: #selector(snapshotAction))
        setHelp("把目前播放位置的畫面複製到剪貼簿（⌘⇧V 可貼成浮動貼圖）", for: snapshotButton, in: hoverRow)

        // 右群（輸出）：存檔▾（pull-down 選單收納存 GIF／存 APNG／存 MP4／存 WebP）／開啟位置／丟棄。
        // icon 放在 pull-down 的**第一個 menu item**（標題佔位項）上，不是 popup button 自己的
        // `.image`——實測過（一次性渲染腳本比對）：直接設 `NSPopUpButton.image` 在 pull-down
        // 模式下不會顯示，pull-down cell 只認第一個 menu item 的 title/image 當「持續顯示」的
        // 內容；佔位項因此只給 image、不給 title（image-only 比 icon+文字擠在一起乾淨），
        // 不設 action/target，選不到（也不該選到）任何行為。
        let saveMenu = NSMenu()
        let savePlaceholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        savePlaceholder.image = NSImage(systemSymbolName: "square.and.arrow.down",
                                        accessibilityDescription: "存檔")
        saveMenu.addItem(savePlaceholder)
        func saveMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self   // 不留 nil 靠 responder chain 找——跟其餘按鈕一貫的明確 target-action
            return item
        }
        saveMenu.addItem(saveMenuItem("存 GIF", #selector(saveGifAction)))
        saveMenu.addItem(saveMenuItem("存 APNG", #selector(saveApngAction)))
        saveMenu.addItem(saveMenuItem("存 MP4", #selector(saveMp4Action)))
        // 「存 WebP」只在偵測到 img2webp 時才加進選單（設計文件 §1.7b：沒有內建 WebP 編碼器
        // 可退，沒裝就不出現這個選項，不是灰掉的選項）。
        if img2webpPath != nil {
            saveMenu.addItem(saveMenuItem("存 WebP", #selector(saveWebpAction)))
        }
        let savePopUpButton = NSPopUpButton(frame: .zero, pullsDown: true)
        savePopUpButton.menu = saveMenu
        savePopUpButton.isBordered = false
        // 佔位 menu item 的 image 有帶 accessibilityDescription（見上方 savePlaceholder），
        // 但 AppKit 會不會把它橋接到 popup button 本身的 accessibility label 沒有 header
        // 可查證——顯式設一次，除掉這個不確定性。
        savePopUpButton.setAccessibilityLabel("存檔")
        savePopUpButton.translatesAutoresizingMaskIntoConstraints = false
        // 30pt：一次性渲染腳本實測（icon＋系統原生下拉箭頭一起量，見 minContentWidth 註解），
        // 不是沿用 SelectionToolbar 26pt 固定值——那個尺寸沒算進 pull-down 的箭頭，會太擠。
        savePopUpButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        savePopUpButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        setHelp("選擇匯出格式並存到預設資料夾", for: savePopUpButton, in: hoverRow)

        configureSymbolButton(openLocationButton, symbol: "folder", accessibilityLabel: "開啟位置",
                              action: #selector(openLocationAction))
        setHelp("在 Finder 開啟並選取剛存的檔案", for: openLocationButton, in: hoverRow)
        openLocationButton.isEnabled = false   // 還沒存過檔前無路徑可開

        let discardButton = NSButton()
        configureSymbolButton(discardButton, symbol: "trash", accessibilityLabel: "丟棄",
                              action: #selector(discardAction))
        setHelp("丟掉這段動畫截圖並關窗（需確認）", for: discardButton, in: hoverRow)
        // 「丟棄」刻意不給快捷鍵：破壞性動作（同 ScrollPreviewWindow.discardAction 的理由）。

        buttons = [audioButton, trimButton, restoreTrimButton, snapshotButton, savePopUpButton,
                   openLocationButton, discardButton]

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)   // 同 SelectionToolbar.hintLabel 的字級

        // 兩群中間一條分隔線，照抄 SelectionToolbar.separator()（該檔 209-216 行）——
        // 1pt 寬、16pt 高、白色 25% 透明度的細線。這裡不是深色 HUD 背景，25% 透明白線在淺色
        // 視窗背景下會太淡看不見；改用 `.separatorColor`（系統語意色，本身就是為了「分隔線」
        // 這個用途設計、自動適配淺色/深色外觀），視覺角色相同、色彩來源換成本視窗合適的版本。
        let toolsRow = NSStackView(views: [audioButton, trimButton, restoreTrimButton, snapshotButton,
                                           separator(), savePopUpButton, openLocationButton, discardButton])
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 4   // 同 SelectionToolbar.toolsRow 的 spacing（不是舊版文字按鈕的 8pt）
        toolsRow.translatesAutoresizingMaskIntoConstraints = false
        hoverRow.addSubview(toolsRow)
        NSLayoutConstraint.activate([
            toolsRow.leadingAnchor.constraint(equalTo: hoverRow.leadingAnchor),
            toolsRow.trailingAnchor.constraint(equalTo: hoverRow.trailingAnchor),
            toolsRow.topAnchor.constraint(equalTo: hoverRow.topAnchor),
            toolsRow.bottomAnchor.constraint(equalTo: hoverRow.bottomAnchor),
        ])

        content.addSubview(playerView)
        content.addSubview(hoverRow)
        content.addSubview(statusLabel)

        // 佈局：playerView 佔滿上方；hoverRow（icon 鈕列）置中在 playerView 下方；statusLabel
        // 說明/狀態行整條貼底（同 SelectionToolbar 的垂直排列：toolsRow→styleRow→hintLabel，
        // 這裡對應 hoverRow→statusLabel，省了 styleRow 那一層——本視窗沒有樣式子選單）。
        // statusLabel 貼滿左右邊界（不像 hoverRow 置中）：狀態文字（匯出進度／檔名）長度
        // 不固定，需要跟按鈕列一樣寬的顯示空間，內容太長就靠 `.byTruncatingTail` 截斷。
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: hoverRow.topAnchor, constant: -8),

            hoverRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hoverRow.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    /// 照抄 `SelectionToolbar.configureSymbolButton`（該檔 197-207 行）：固定尺寸 26×22pt、
    /// borderless、cornerRadius——差異只在不強制 `.contentTintColor`（見 buildUI 呼叫處的說明）
    /// 與多了 `accessibilityLabel` 參數（team-lead 這輪要求：每顆都要 toolTip＋
    /// accessibilityDescription，SelectionToolbar 原本沒設 accessibilityDescription，這裡加嚴）。
    private func configureSymbolButton(_ b: NSButton, symbol: String, accessibilityLabel: String,
                                       action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        b.target = self
        b.action = action
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    /// 說明文字設一次、兩處生效：系統 tooltip 與 hoverRow 的 hover 說明（同
    /// `SelectionToolbar.setHelp`，該檔 180-183 行）。
    private func setHelp(_ text: String, for view: NSView, in hoverRow: HoverHintRow) {
        view.toolTip = text
        hoverRow.hints[view] = text
    }

    /// 照抄 `SelectionToolbar.separator()`（該檔 209-216 行），顏色換成 `.separatorColor`
    /// （見 buildUI 呼叫處的說明——原版的白色 25% 透明度是深色 HUD 專用）。
    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        for b in buttons { b.isEnabled = enabled }
    }

    /// 喇叭鈕只在母帶含音軌時才顯示（brief 要求）。用 `AVURLAsset.loadTracks(withMediaType:)`
    /// 的 async 版本，不用已 deprecated 的同步 `tracks(withMediaType:)`——同檔 `loadNaturalSize`
    /// 的一貫紀律，零 warning 是硬約束（見 CLAUDE.md 建置章節）。視窗一開先隱藏鈕（見 buildUI
    /// 建立處），load 回來確認有音軌才 `isHidden = false`；沒有音軌就維持隱藏，不用額外處理。
    private func detectAudioTrack() {
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: self.movieURL)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  !tracks.isEmpty else { return }
            self.audioButton.isHidden = false
        }
    }

    /// 所有「設定狀態訊息」的地方都呼叫這裡，不要直接寫 `statusLabel.stringValue`——
    /// 否則 hover 離開後 `HoverHintRow.onHint` 回復的 `lastStatusMessage` 會是舊的（見
    /// `lastStatusMessage` 屬性宣告處的說明）。
    private func setStatus(_ text: String) {
        lastStatusMessage = text
        statusLabel.stringValue = text
    }

    // MARK: - 按鈕語意

    /// 靜音切換：player 建立時預設 `isMuted = true`（循環播放不吵——spec §0），這顆鈕讓使用者
    /// 自行取消／恢復靜音，圖示同步換 slash/wave 兩態。只有偵測到母帶含音軌才會顯示（見
    /// `detectAudioTrack()`），沒有音軌時這顆鈕維持隱藏，不會被按到。
    ///
    /// **accessibilityDescription 兩態各給一個**（review 抓到的必修）：不能沿用初始建立時的
    /// 那個值——`NSImage(systemSymbolName:accessibilityDescription:)` 每次呼叫都是全新的
    /// `NSImage`，換圖就等於換掉整個 accessibility 描述，若這裡傳 `nil` 第一次點擊後 VoiceOver
    /// 就聽不到鈕名了。文案跟 `configureSymbolButton` 建立時的初始值同一套邏輯：說的是「點下去
    /// 會做什麼」，不是「目前是什麼狀態」（同 macOS 系統音量鈕的慣例）——靜音中（顯示
    /// `speaker.slash`）→ 「取消靜音」；有聲中（顯示 `speaker.wave.2`）→ 「靜音」。
    ///
    /// toolTip／hover 說明**不跟著切換**：`setHelp()` 設的那行「預覽預設靜音，點一下切換播放
    /// 聲音」本身就是狀態中立的通用說明（描述這顆鈕的功能，不是目前狀態），跟同檔
    /// `restoreTrimButton`／`openLocationButton`——`isEnabled` 隨狀態變但 toolTip 文字固定
    /// 不變——是同一個慣例，不需要另外處理。
    @objc private func toggleAudio() {
        guard let q = playerView?.player else { return }
        q.isMuted.toggle()
        audioButton.image = NSImage(systemSymbolName:
            q.isMuted ? "speaker.slash" : "speaker.wave.2",
            accessibilityDescription: q.isMuted ? "取消靜音" : "靜音")
    }

    /// 剪裁：原生 trim UI（設計文件 §1.6）。已查 AVKit header（`AVPlayerView.h`）：
    /// `canBeginTrimming` 唯讀屬性、`beginTrimmingWithCompletionHandler:` 只回傳
    /// `.okButton`/`.cancelButton`，**不直接給範圍**——選取結果要另外讀。已查 AVFoundation
    /// header（`AVPlayerItem.h`）：`forwardPlaybackEndTime`/`reversePlaybackEndTime` 是唯一
    /// 暴露在 `AVPlayerItem` 上的可編輯範圍屬性；header 本身沒有寫「這就是 trim UI 寫回的地方」
    /// （header 沒把兩者關聯起來講），但這是 AVKit 官方 trim UI 對外溝通選取結果的既定慣例
    /// （長年公開範例／文件如此），也是 `AVPlayerItem` 上唯一能表達「子範圍」的 API——
    /// 沒有第二條路可查。**實機驗證結論（診斷探針證實）**：`canBeginTrimming` 在
    /// `AVQueuePlayer`＋`AVPlayerLooper` 下是 true、`beginTrimming` 讀值成功——
    /// `player.currentItem` 那個複本的 `reversePlaybackEndTime`/`forwardPlaybackEndTime`
    /// 正確反映使用者選取範圍，讀值本身沒有問題。真正的 bug 在別處：見下方「Looper 複本」段落。
    ///
    /// **Looper 複本問題（實機 bug，已修）**：`AVPlayerLooper.loopingPlayerItems` 是 template
    /// item 的至少 3 份複本輪流播放（見 `AVPlayerLooper.h`），trim UI 只碰得到
    /// `player.currentItem`（複本之一），其餘複本的 `forwardPlaybackEndTime` 完全沒被觸及——
    /// 循環播放輪到那些複本時播的是全長，使用者實測症狀正是「剪完會重播，重播後又回到未剪的
    /// 影片」。header 明講 client 不該手動修改複本屬性，正解是用 header 提供的專用建構子
    /// `initWithPlayer:templateItem:timeRange:` 整顆重建 looper（見下方 trim 成功分支），
    /// 讓所有複本都套用同一個 timeRange，不是只有一個。
    @objc private func trimAction() {
        guard let playerView, let player, playerView.canBeginTrimming else {
            setStatus("此播放器不支援剪裁")
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
                self.restoreTrimButton.isEnabled = (self.trimRange != nil)
            }
            // 分支＝cancel（或非 okButton）：AVKit trim UI 的既定行為是取消時不套用變更，
            // 這裡不用額外處理——不更新 trimRange 就等於維持剪裁前的狀態（第一次剪裁前＝nil／
            // 已剪裁過＝上次的範圍）。（實機已驗證：這條讀值路徑本身沒問題，見下方類文件註解。）
            guard result == .okButton else { return }
            // 分支＝currentItem 為 nil：理論上不會發生（trim UI 完成時 player 一定有 currentItem），
            // 防禦性寫，不設 trimRange。
            guard let item = player.currentItem else { return }
            // reversePlaybackEndTime 無效＝使用者沒動起點（維持 0）；forwardPlaybackEndTime
            // 無效＝沒動終點（維持母帶全長）——兩者預設值都是 kCMTimeInvalid（見 header）。
            // 實機已驗證：這兩個值確實反映使用者在 trim UI 上選取的範圍。
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            let range = CMTimeRange(start: start, end: end)
            self.trimRange = range
            if range.duration.seconds <= 0 {
                // 分支＝range 退化（duration<=0，使用者把兩個把手拖到同一點）：不重建
                // looper——`AVPlayerLooper.h` 明講「valid time range 的 duration 為 0」會擲
                // NSInvalidArgumentException，重建下去會直接 crash。維持舊 looper（播全長）
                // 比 crash 安全；trimRange 仍照設，匯出端遇到這種退化範圍是既有問題，不在本次
                // 修法範圍內。
                self.setStatus(String(format: "已剪裁 %.1fs–%.1fs，匯出將套用",
                                      start.seconds, end.seconds))
                return
            }
            // 分支＝成功：重建 looper（根因修法，實機已驗證）。`loopingPlayerItems` 是
            // template item 的複本（見 `AVPlayerLooper.h` `loopingPlayerItems` 屬性說明），
            // trim UI 只改到 `player.currentItem`（複本之一）的 forwardPlaybackEndTime，其餘
            // 複本完全沒被觸及——looper 輪替到下一個複本時播的仍是全長，這正是使用者實機回報
            // 「剪完會重播回未剪影片」的根因（診斷探針確認：currentItem 有 reverse/forward
            // 值，其餘複本都是 invalid）。正解不是去改每個複本（header 講「client 不該碰複本
            // 屬性」），是照 header 給的專用建構子重建：`initWithPlayer:templateItem:timeRange:`
            // ——「Time range will be accomplished by seeking to range start time and setting
            // AVPlayerItem's forwardPlaybackEndTime property **on the looping item replicas**」
            // （已用最小重現專案確認這個 initializer 在 `.macOS(.v14)` target 下零 warning，
            // 無額外可用性標記，不是 macOS 14+ 才有的那個 `existingItemsOrdering:` 版本）。
            // 用全新 `AVPlayerItem`（不是被 trim UI 動過的那個）當 template：header 的
            // 用法就是「乾淨 template item ＋ timeRange 參數」，不是「先設好
            // forwardPlaybackEndTime 的 item」。使用者實機驗證：循環播放的確是剪裁後的那段。
            self.looper = nil   // 舊 looper 的複本／佇列由 dealloc 收尾（同 header：destroyed 時恢復佇列）
            let freshItem = AVPlayerItem(url: self.movieURL)
            self.looper = AVPlayerLooper(player: player, templateItem: freshItem, timeRange: range)
            // 重剪語意：重建後 currentItem 是新複本（沒有 reverse/forward 值），使用者再按
            // 「剪裁」時 trim UI 會從全長重新選——「重剪＝從全長重新選」，可接受；
            // beginTrimming 是否在重建後的 looper 上仍可用，跟原本同一種構造（AVQueuePlayer+
            // AVPlayerLooper），理論上行為一致，仍待實機驗證（見待驗清單）。
            self.setStatus(String(format: "已剪裁 %.1fs–%.1fs，匯出將套用",
                                  start.seconds, end.seconds))
        }
        // 再按「剪裁」可重剪：beginTrimming 用 currentItem 目前的
        // forwardPlaybackEndTime/reversePlaybackEndTime 當 trim UI 初始選取範圍，第二次呼叫
        // 因此會從上次的結果繼續調整，覆蓋 `trimRange` 屬性即可，不需要額外的「清除剪裁」入口
        // （「還原剪裁」鈕是給使用者主動清除、不是這裡自動處理）。
    }

    /// 還原剪裁：清掉 `trimRange`（回到匯出整段母帶），並把預覽 looper 重建回全長——
    /// 呼叫 `AVPlayerLooper(player:templateItem:)`（沒有 `timeRange` 參數的版本）跟
    /// `buildUI()` 最初建立 looper 時是同一個建構子，header 說明「不給 timeRange 等同
    /// kCMTimeRangeInvalid，也就是 [0, itemToLoop's duration]」——即全長。
    @objc private func restoreTrimAction() {
        guard trimRange != nil, let player else { return }
        trimRange = nil
        looper = nil
        let freshItem = AVPlayerItem(url: movieURL)
        looper = AVPlayerLooper(player: player, templateItem: freshItem)
        restoreTrimButton.isEnabled = false
        setStatus("已還原全長")
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
        setStatus("WebP 匯出中… 0%")
        let tmpURL = movieURL.deletingPathExtension().appendingPathExtension("webp")
        let fps = Double(AppSettings.recordGifFps)
        GifExporter.exportWebP(movieURL: movieURL, to: tmpURL, pointScale: captureScale,
                               fps: fps, timeRange: trimRange, img2webpPath: img2webpPath,
                               progress: { [weak self] p in
                                   self?.setStatus("WebP 匯出中… \(Int(p * 100))%")
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
                                       self.setStatus(saved.map { "已存 \($0.lastPathComponent)" }
                                           ?? "WebP 存檔失敗")
                                   case .failure(let e):
                                       // 不回退（設計文件 §1.7b：沒有內建 WebP 編碼器）——直接顯示錯誤，
                                       // GifExporter.exportWebP 內部已經把同款診斷寫進 RecordSessionLog。
                                       self.setStatus("WebP 匯出失敗：\(e)")
                                   }
                                   self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
                                   self.restoreTrimButton.isEnabled = (self.trimRange != nil)
                               })
    }

    /// GIF／APNG 共用的匯出＋存檔流程：fps 讀 `AppSettings.recordGifFps`（設計文件 §1.2——
    /// 兩種格式共用同一個 fps 設定項，不需要分開的 APNG fps）。`label` 只用於狀態列文案，
    /// 副檔名／UTType 由 `format.fileExtension` 與 `GifExporter` 內部決定。
    private func exportAndSave(format: AnimationFormat, label: String) {
        isExporting = true
        setButtonsEnabled(false)
        setStatus("\(label) 匯出中… 0%")
        let ext = format.fileExtension
        let tmpURL = movieURL.deletingPathExtension().appendingPathExtension(ext)
        let fps = Double(AppSettings.recordGifFps)
        GifExporter.export(movieURL: movieURL, to: tmpURL, pointScale: captureScale,
                           fps: fps, format: format, timeRange: trimRange,
                           progress: { [weak self] p in
                               self?.setStatus("\(label) 匯出中… \(Int(p * 100))%")
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
                                   self.setStatus(saved.map { "已存 \($0.lastPathComponent)" }
                                       ?? "\(label) 存檔失敗")
                               case .failure(let e):
                                   self.setStatus("\(label) 匯出失敗：\(e)")
                               }
                               // 「開啟位置」不是跟著上面 setButtonsEnabled(true) 無條件打開：
                               // 還沒存過檔（lastSavedURL 是 nil）就不該讓使用者按得下去——
                               // 沒有路徑可開，按了也只是 guard 直接 return，但那是「看起來能按
                               // 卻沒反應」，比「本來就是灰的」更讓人困惑。「還原剪裁」同一套
                               // 邏輯（trimRange 決定，不是無條件打開）。
                               self.openLocationButton.isEnabled = (self.lastSavedURL != nil)
                               self.restoreTrimButton.isEnabled = (self.trimRange != nil)
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
            setStatus(saved.map { "已存 \($0.lastPathComponent)" } ?? "MP4 存檔失敗")
            return
        }
        isExporting = true
        setButtonsEnabled(false)
        setStatus("MP4 剪裁匯出中…")
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
                self.restoreTrimButton.isEnabled = (self.trimRange != nil)
            }
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: self.movieURL),
                                                     presetName: AVAssetExportPresetPassthrough) else {
                self.setStatus("MP4 剪裁匯出失敗：無法建立匯出工作階段")
                return
            }
            session.timeRange = trimRange
            do {
                // macOS 15 的 `export(to:as:)`（SDK header 實查 API_DEPRECATED_WITH_REPLACEMENT）：
                // 取代 outputURL/outputFileType 賦值＋exportAsynchronously＋status/error 三件套。
                // 失敗直接 throw——不再有「status 非 completed 但 error 為 nil」的模糊地帶。
                try await session.export(to: tmpURL, as: .mp4)
                let saved = self.output.saveCopy(from: tmpURL, ext: "mp4", vars: self.vars)
                try? FileManager.default.removeItem(at: tmpURL)
                if let saved { self.lastSavedURL = saved }
                self.setStatus(saved.map { "已存 \($0.lastPathComponent)" } ?? "MP4 存檔失敗")
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
                self.setStatus("MP4 剪裁匯出失敗：\(error.localizedDescription)")
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
                self.setStatus("快照已複製（⌘⇧V 可貼出）")
            } catch {
                self.setStatus("拍快照失敗：\(error)")
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

    // MARK: - 按鈕列 hover 說明

    /// 按鈕列 hover 說明機制：完整比照 `SelectionToolbar`（該檔 27-49、272-307 行）的做法——
    /// 用一個 tracking area 換算滑鼠是否落在哪個已註冊控件的 bounds 內，不靠系統 tooltip
    /// （同款理由：tooltip 要停留一兩秒才浮出，對一整排小 icon 太慢；這裡雖然不是 nonactivating
    /// panel，但一樣要「meaningfully instant」）。與 `SelectionToolbar.hintLabel` 的唯一差異
    /// 寫在 `RecordPreviewWindow.lastStatusMessage` 屬性宣告處：離開時回復的不是固定預設文字，
    /// 是「最後一次真正的狀態訊息」——這行同時兼職 hover 說明與匯出進度/存檔結果/剪裁範圍
    /// 的顯示，SelectionToolbar 的說明列沒有第二種角色，因此那份參照沒有這個機制，這裡是
    /// team-lead 這輪核可的自行設計（brief 原文：「沒有就實作…並記錄」）。
    ///
    /// 不覆寫 `mouseDown`（跟 `SelectionToolbar` 不同）：那邊要擋掉點擊穿透到底下的
    /// `SelectionView`（overlay 疊在使用者正在操作的畫面上）；這裡的按鈕列只是普通視窗最下方
    /// 的一排控件，底下沒有東西需要保護，讓 AppKit 正常的子視圖 hit-test 把點擊事件送給實際
    /// 被點到的按鈕就好——tracking area 只負責 hover 資訊，不干涉點擊派送。
    private final class HoverHintRow: NSView {
        var hints: [NSView: String] = [:]
        var onHint: ((String?) -> Void)?   // nil＝滑鼠離開所有已註冊控件，回復狀態訊息

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { updateHint(with: event) }
        override func mouseMoved(with event: NSEvent) { updateHint(with: event) }
        override func mouseExited(with event: NSEvent) { onHint?(nil) }

        /// 找滑鼠底下註冊過說明的控件（同 `SelectionToolbar.updateHint` 的做法：不用
        /// `hitTest(_:)`，直接對每個控件換算座標，控件數量小，成本可忽略）。
        private func updateHint(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            for (view, text) in hints {
                guard !view.isHiddenOrHasHiddenAncestor else { continue }
                if view.bounds.contains(view.convert(point, from: self)) {
                    onHint?(text)
                    return
                }
            }
            onHint?(nil)
        }
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
        // 高 = 寬×影片長寬比 + 60（playerView 下緣到 content 下緣的固定量：
        // 8pt 間距＋hoverRow 22pt＋4pt 間距＋statusLabel 說明/狀態行約 14pt＋10pt 底邊距＝58pt，
        // 取 60 留一點餘裕），下限 minContentHeight；兩者都 clamp 進螢幕。這個常數改版前是 90
        // （文字按鈕列比 icon 列高、也沒有獨立的說明/狀態行，見 RecordPreviewWindow.buildUI
        // 這輪佈局改版的說明），icon 化＋按鈕列變窄變矮之後跟著往下調。
        let width = CoordinateUtils.previewWidth(pixelWidth: naturalSize.width, scale: scale,
                                                 visibleWidth: visible.width,
                                                 minWidth: RecordPreviewWindow.minContentWidth)
        let aspect = naturalSize.height / max(naturalSize.width, 1)
        // chrome 60＝playerView 下緣到 content 下緣的固定量（8+22+4+14+10≈58,留餘裕取 60）
        let height = CoordinateUtils.previewHeight(width: width, aspect: aspect, chrome: 60,
                                                   minHeight: RecordPreviewWindow.minContentHeight,
                                                   visibleHeight: visible.height)
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
