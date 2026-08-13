# 動畫截圖：功能與做法

**這是動畫截圖的單一事實來源**：功能行為、資料流、每格處理、核心設計決定、驗證方式，
以及 §9「不要改回去」的收斂清單，全部在這裡。程式碼與這份不符時**以程式碼為準並立刻修這份**。

`CLAUDE.md` 只放跨功能的通用規範，**不重複本文的內容**（兩邊各記一份必然漂移，
`docs/scroll-capture.md` 已經吃過這個虧）。
`docs/superpowers/specs/2026-07-29-animated-capture-design.md` 是「當初為什麼這樣決定」的
設計快照，不是現況——實作期間有幾處被 review 修正過（見各段落標註）。
RPC 自動化命令表（`getState`／`startRecord` 等）與事件表獨立成 `docs/automation.md`，這裡只在
§7 提 `RecordAudioTracks` 的掛載點與 A/V 對齊語意。

最後更新：2026-08-12

---

## 1. 使用者看到的行為

`⌘⇧R`（設定可改）→（無螢幕錄製權限時先走系統詢問／既有引導提示，見下表「權限預檢」）→
拉框圈住要錄的區域 → HUD 待命（可設錄製秒數，空白＝不限）→
按「開始」（秒數欄按 Enter 同等效果）→ 錄製（HUD 顯示計時／倒數）→ 停止（手動鈕／倒數到／
看門狗／stream error 共用同一條路徑）→ 預覽視窗（AVPlayerView 循環播放），按鈕列分兩群、中間
彈性空白撐開：左＝編輯〔剪裁〕〔還原剪裁〕〔拍快照〕，右＝輸出〔存檔▾：存 GIF／存 APNG／
存 MP4／存 WebP（僅偵測到 img2webp 時多這項）〕〔開啟位置〕〔丟棄〕；播放器影像區也可直接
拖曳出整段母帶 MP4。
「丟棄」與紅鈕關閉共用同一個 `close()`；匯出中（GIF／APNG／WebP）關閉會先跳警示，需要選
「強制關閉」才會真正關窗並刪除母帶；trim overlay 顯示中關閉則只跳提示、不給強制關閉的逃生口
（見 §6 的逃生口說明）。存檔通知可直接點擊，在 Finder 開啟並選取剛存的檔案（截圖／滾動截圖／
動畫截圖三處存檔都受益，非動畫截圖獨有）。

定位是「會動的截圖」，不是螢幕錄影機：不錄音訊、不能暫停續錄、不做 webcam。

| 行為 | 說明 |
|---|---|
| 逃生路徑：取消（丟棄） | Esc（僅 selecting/armed）、HUD 取消鈕、selecting/armed 中再按同一顆全域快鍵（Carbon，不受 app 前景狀態影響） |
| 逃生路徑：停止（收檔保留） | recording 中再按同一顆全域快鍵、HUD 停止鈕、倒數到、看門狗、stream error 兜底——五者共用同一條停止程序（§4） |
| 不限時看門狗 | 10 分鐘自動走正常停止路徑（防忘記停吃光磁碟） |
| 權限預檢 | `beginAnimatedCapture()` 開頭 `CGPreflightScreenCaptureAccess()` 為 false → `CGRequestScreenCaptureAccess()`（首次觸發系統詢問）→ 仍拒絕 → 走既有 `showPermissionAlert()`、直接 return，不進 session；request 剛被使用者允許也一律 return 讓使用者重按（授權後常需重啟 app 才生效，續跑會拿到黑畫面 stream） |
| 錄製中顯示游標／點擊高亮圈 | 設定可各自關；**游標關閉時點擊圈勾選框連動停用**（`CaptureSettingsViewController.updateClickRingEnabledState`）——點擊圈要開，游標必須先開（Kap 的 UX 細節，設定 → 控制/截圖分頁） |
| 最小選區 | 64 **點**（`RecordSession.minSelectionEdgePt`；錄製無匹配需求，門檻遠低於滾動截圖的 320px） |
| HUD 秒數欄輸入 | armed 狀態的秒數欄可正常點進去打字（`RecordHUDPanel` 子類覆寫 `canBecomeKey = true`，見 §9 的實機教訓）；欄位按 Enter 與按「開始」鈕同等效果 |
| 匯出 MP4 | 無剪裁：搬移母帶（copy，非 move——之後可能還要匯 GIF/APNG）；零轉檔，母帶本身即最終品質。有剪裁：`AVAssetExportSession` + `AVAssetExportPresetPassthrough` 只切 `timeRange` 不重編碼，匯到暫存再存檔（§6） |
| MP4 編碼（HEVC） | 設定 → 截圖 → 動畫截圖：「MP4 使用 HEVC」checkbox，預設關（H.264）。開啟後檔案較小（位元率因子 0.9→0.45，同款 Azayaka 公式）、舊裝置相容性較差；檔案仍是 `.mp4`（hevc-in-mp4 合法），GIF/APNG/WebP 解碼端不受影響 |
| 匯出 GIF | fps 可設定（8/10/12/15/20，預設 12，設定 → 截圖 → 動畫截圖）、1x（點）尺寸，背景 queue 解碼，預覽窗顯示進度；偵測到外部 gifski 時優先走它產生更高品質 GIF，任何失敗自動回退內建編碼器（§6） |
| 匯出 APNG | 全彩、無 GIF 那種 256 色調色盤限制，副檔名 `.png`；檔案通常較小但非通用貼圖格式（聊天軟體支援度不一），與 GIF 並存而非取代 |
| 匯出 WebP | 只在偵測到外部 `img2webp` 時「存 WebP」鈕才出現；沒有內建可回退，沒裝就不出現（不出灰鈕不出錯誤） |
| 剪裁 | 預覽視窗「剪裁」鈕開原生 `AVPlayerView` trim UI，選定的時間段套用到之後所有匯出格式（GIF/APNG/MP4，以及偵測到 img2webp 時的 WebP），且預覽的循環播放也會改成只播剪裁段（重建 `AVPlayerLooper`，見 §6）；「還原剪裁」鈕清掉範圍、預覽與匯出都回到整段母帶；拍快照、拖曳出檔案兩者都不受剪裁影響（一律對應「目前播放位置」／「整段母帶」） |
| 拖曳出檔案 | 預覽視窗播放器影像區可直接拖曳出**整段母帶** MP4（設計決定：不受剪裁影響，一律整段，v1 語意單純化）；匯出中（GIF/APNG/WebP in-flight）也可正常拖曳 |
| 儲存通知可點擊 | 系統通知點擊 → `NSWorkspace.activateFileViewerSelecting`，Finder 開啟並選取剛存的檔案；檔案已被移走/刪除時安靜 no-op |

限制：需 macOS 14+；螢幕由**框選當下滑鼠所在位置**決定；`SCShareableContent` 偶發
`noDisplays` 是暫時性的，報錯讓使用者重試（同滾動截圖既有教訓）。

---

## 2. 資料流

```
⌘⇧R
 └─ RecordSession（@MainActor，狀態機協調者，不做編碼）
     状態：idle → selecting → armed → recording → finishing → idle
     ├─ ScrollSelectionOverlayController   拉框選區（與滾動截圖共用元件）
     ├─ RecordHUDController                待命秒數欄／錄製時鐘 HUD
     ├─ ClickRingOverlay                   點擊圈透明視窗＋滑鼠 global monitor
     ├─ RecordFrameSource                  SCStream 封裝，把 CMSampleBuffer 交給 WriterBox
     │    └─ WriterBox                     AVAssetWriter 封裝（懶啟動／補尾格／finalize）
     │         └─ RecordAudioTracks        系統聲／麥克風音軌（組合式掛載，見 §7）
     └─ RecordPreviewWindowController      收檔後開預覽視窗
          └─ GifExporter                   母帶 → GIF（背景 Task.detached）

RecordMath.swift     純計算（GIF delay／sample-and-hold／尾格判斷／HUD 時鐘文字／Goertzel 單頻能量），selftest 可測
RecordOutputService  暫存母帶路徑、殘留清掃、快速儲存（CaptureOutputService 的 side path）
RecordSelfCheck.swift 內建自檢工具（見 §8），不參與正式流程
RecordAudioSelfCheck.swift 音訊內建自檢工具（見 §7／§8），不參與正式流程
```

**分層原則**：`RecordMath` 不碰 AppKit／AVFoundation，能在 `anypaint-selftest` 端到端驗證。
`WriterBox` 只在 `RecordFrameSource.sampleQueue`（序列佇列）上被觸碰，天然序列化、無鎖
（比照 `ScrollStitchEngine` 的 `@unchecked Sendable` 論證）。

---

## 3. 每格的處理流程（SCStream → Writer）

在 `RecordFrameSource.sampleQueue` 上，主執行緒零工作：

1. attachments status 檢查：只收 `.complete`（`.idle`/`.blank` 直接 return——否則黑首格或
   時長算錯）
2. **懶啟動**：第一個 `.complete` 格才 `writer.startSession(atSourceTime:)`（`startWriting()`
   在 `WriterBox.init` 就先做，之後靠 `writer.status == .writing` 把關）
3. `input.isReadyForMoreMediaData` 為 false → **靜默丟格**（`expectsMediaDataInRealTime = true`
   的契約，不排隊不阻塞）
4. **直接 `input.append(sampleBuffer)`**——不改像素、不用 pixel buffer adaptor
5. 保留這一格的 reference（`lastSampleBuffer`），供停止時補尾格用

### SCContentFilter／SCStreamConfiguration 的關鍵取捨

- `excludingApplications: [自家 bundleID]`：app 整體排除，HUD／預覽／點擊圈中途才開也拍不進
  （建 filter 是靜態快照——CLAUDE.md 既有教訓）。
- `onScreenWindowsOnly: false`：點擊圈視窗刻意用 alpha 0，只借位給 `exceptingWindows` 白名單，
  不需要真的被看見。用 `true` 只列「畫面上看得見」的視窗，alpha 0 的視窗很可能被排除在外，
  讓 `exceptingWindows` 放空、點擊圈隨整個 app 一起被排除（review 判定為真缺陷，見
  `ClickRingOverlay.prepare(near:)` 與 `RecordFrameSource.start` 的對應註解）。
- `exceptingWindows` 是建 filter 當下的靜態快照 → **點擊圈視窗必須在建 filter 之前先建好**，
  用 `windowID == CGWindowID(window.windowNumber)` 比對（不用標題——QuickRecorder 的標題比對
  較脆弱）。
- `queueDepth = 6`：保留 `lastSampleBuffer` 永久佔掉 IOSurface 池一張，**queueDepth 必須 ≥ 5**
  才夠用（滾動截圖的 3 不夠；nonstrict 原註解）。
- `showsCursor` 交給 SCK 畫，四個實戰專案（QuickRecorder/Azayaka/Aperture/nonstrict）一致做法，
  沒人自行合成游標。

---

## 4. 停止順序（固定，任何觸發源共用——手動鈕／倒數到／看門狗／stream error）

`RecordFrameSource.stopAndFinish()` → `WriterBox.finish(nowUptime:)`：

1. `await stream.stopCapture()`
2. **補尾格**：若 `(nowUptime − 最後格 PTS) > 0.5s`（`RecordMath.needsTailFrame`），把保留的
   `lastSampleBuffer` 用 `CMSampleBufferCreateCopyWithNewTiming` 蓋成現在時間再 append。
   **用 `ProcessInfo.systemUptime` 換 CMTime，不可用 `Date`**——SCK 的 PTS 在 host clock 上，
   跟 wall-clock 的 `Date` 不是同一個時鐘，會讓補的尾格時間戳整段偏移。
   這解掉「結尾靜止 → 檔案比實際短」（selfcheck 檢查 A 的靜止尾段 2s 就是測這條）。
3. `writer.endSession(atSourceTime: 尾格 PTS)`
4. `input.markAsFinished()` → `await writer.finishWriting()`
5. **檢查 `writer.status == .completed`**，否則把 `writer.error` 包進
   `RecordError.writerFailed` 報給使用者——writer 會在最後一步靜默失敗
   （QuickRecorder `SCContext.swift:352` 教訓）。

`stream(_:didStopWithError:)` 轉送到 `RecordSession.stopRecording()`（`onStreamError` 回呼），
走同一條完整路徑，不會漏掉 finalize。

### 停止路徑的早退紀律（round 2/3 review 修正，實作期間才浮現的坑）

`RecordFrameSource` 的 `box`（`WriterBox?`）只在「這次呼叫自己手上有一個**已經
`await stream.stopCapture()` 過**的 stream」時才會被清 nil。`start()` 的 `await` 期間
（`SCShareableContent` 抓取慢了幾百毫秒），`self.stream` 還沒賦值，這時若 `abort()` 或
`stopAndFinish()` 被呼叫，兩者手上都沒有可以自己 `stopCapture()` 的 stream——這種情況下
兩者都**完全不碰 `self.box`**，只設 `pendingStop = true` 就早退，把清理完全交給 `start()`
自己的 `pendingStop` 分支收尾。沒有這條紀律時，`abort()`／`stopAndFinish()` 會在這個窗口對
`self.box` 做無同步的跨執行緒寫，跟 sampleQueue 上的 handler 讀是真的資料競爭。

`WriterBox` 也有對應的 `isTerminal` 冪等旗標：`finish()`／`cancel()` 第一次被呼叫就鎖住，
之後兩者皆變 no-op、`append` 也一併擋掉。補的是同一個窗口下，`abort()` 與 `start()` 自己的
收尾分支可能對同一個 box 各呼叫一次 `cancel()`——`markAsFinished`／`cancelWriting` 對已終結
的 writer 再呼叫一次是 AVFoundation 的 ObjC exception，Swift 攔不到，直接 crash。

`start()` 失敗（TCC 拒絕、`noDisplays` 等實機常見錯誤）時**自己清乾淨**
（`self.box`／`self.stream`／`self.outputURL` 全部回到 nil），呼叫端可以直接重試，
不需要先呼叫 `abort()`。`RecordError` 因此有三個 case：`.noFrames`（一格都沒收到就停止）、
`.writerFailed(Error?)`（finalize 後 status 非 `.completed`）、`.alreadyRecording`
（`start()` 在既有 session 收尾前又被呼叫——防重入 guard `stream == nil, box == nil`，
絕不重入覆寫 stream/box，否則舊 stream 變孤兒、舊 WriterBox 永久扣住一張 IOSurface）。

`RecordSession.State` 有五個狀態，`.finishing` 是新增的第五個（滾動截圖的
`ScrollCaptureSession` 沒有這個狀態）：`stopAndFinish()` 的 `finishWriting` 不回呼或
`stopCapture` 卡住都會讓狀態機卡在這裡，**30 秒看門狗**（`finishingWatchdogSeconds`）
是唯一救得回來的機制——沒有它，`.finishing` 是狀態機裡唯一沒有逃生繩的狀態，卡住就永久卡死
（再按快鍵被 `cancelIfActive` 的 `state != .finishing` guard 擋死，只能重啟 app）。

---

## 5. 點擊高亮圈（QuickRecorder 架構 + Screenity 視覺）

**架構：螢幕上的透明視窗，讓 SCStream 自然拍進去**——不做 live compositing。改像素就不能
直接 `append(sampleBuffer)`，且四個被調查的實戰專案無一採用 live compositing。副作用：
使用者錄製中看得到圈＝即時回饋，是 feature。

- 偵測：`NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])`
  ——**滑鼠類 global monitor 不需要輔助使用權限**（QuickRecorder production 實證 ＋
  本專案 scrollWheel 既有經驗）。只在 `recording` 狀態掛，停止即拆。
- 視窗：`.borderless` + `.nonactivatingPanel`、`ignoresMouseEvents = true`、背景透明、
  視窗四件套（`.canJoinAllSpaces, .fullScreenAuxiliary, .stationary` + `.screenSaver` level）。
- **視窗必須落在某個實際螢幕內**才建（`ClickRingOverlay.prepare(near:)` 傳選區中心）：
  舊版固定擺 `(-100, -100)`（螢幕外）被 review 判定為真缺陷——`onScreenWindowsOnly: false`
  雖然讓 alpha 0 的視窗仍可能被列到，但螢幕外＋alpha 0 疊加起來風險更高，索性直接把視窗擺在
  選區中心、只靠 alpha 0 保證使用者看不到這次借位。
- 視覺（Screenity 參數）：按下瞬間在游標處顯示 40pt 圈、**寫死 `NSColor.systemOrange`**
  （不是系統 accent 色）3pt 實色描邊為主視覺；疊一層同心、半徑微放大（+0.5pt）、4pt
  半透明黑（35% alpha）描邊在下——半徑比橘圈大 0.5pt、線寬又多 1pt，幾何上外側露出 1pt、
  內側露出 0（`ClickRingOverlay.swift:81` 註解「3pt 亮橘描邊＋1pt 深色外圈」），足夠在橘圈
  外緣提供對比（CLAUDE.md「疊色描邊」教訓的實作方式：這裡用「同心微放大」達成同樣的
  「任一背景都留得下對比」效果，不是該教訓描述的「同寬黑白交錯」手法）；按住拖曳跟隨游標；
  放開後 350ms **淡出**（`ClickRingView.fadeOut` 只動 `alphaValue`，不縮放尺寸）。

---

## 6. 匯出（GIF／APNG／WebP／MP4 剪裁，`GifExporter`）

`GifExporter` 已泛化為 `AnimationFormat`（`.gif`/`.apng`）＋`GifEngine`（`.auto`/`.builtin`）
兩個維度，加上可選的 `timeRange: CMTimeRange?`（剪裁）；WebP 走完全獨立的
`GifExporter.exportWebP`（見下方「外部引擎」小節，沒有回退，語意跟 GIF/APNG 不同，不共用同一個
`export(...)` 入口）。內建 CGImageDestination 路徑（本節前 7 點）是三種格式共同的地基，
外部 gifski/img2webp 是**在這之上**多出來的可選加值路徑，不是取代它。

1. `AVAssetReader` + BGRA output settings **循序解碼**母帶——不用 `AVAssetImageGenerator`
   （精準 seek 慢，Gifski.app 已遷移過這條路）。
2. 均勻目標網格（fps 可設定，`RecordMath.gridTimes`；GIF/APNG 匯出讀
   `AppSettings.recordGifFps`，選項 8/10/12/15/20、預設 12；**自檢顯式傳 12，不吃設定**——
   判準要確定性，見 §9）＋ **sample-and-hold**（`RecordMath.sampleHoldIndices`）：對每個目標
   時間取「PTS ≤ 目標」的最新解碼格；一格可重複使用、也可被跳過——天然消化 VFR 母帶的靜止空洞
   （SCK 靜止不供格）。`GifExporter` 內的線上迴圈（`current`/`next` 解碼超前一格）與這個純
   函式逐字對應，行為若歧異以純函式（有 selftest）為準。
3. 縮到 **1x（點）尺寸**（2x Retina 檔案爆炸；Gifski.app 對長邊 >1200px 也會警告）。
4. `CGImageDestination` 寫入，per-frame delay **依格式分兩套規則**（`AnimationFormat` 的
   `perFrameProperties`）：
   - **GIF**：**累計捨入**（`RecordMath.gifDelaysCentiseconds`）：
     `delay_cs = round(累計秒×100) − 已寫入 cs`，clamp 下限 2cs（逐格天真捨入 1/12s→8cs
     會累積漂移，長片會加速約 4%；gifski `src/lib.rs` 同法）。
   - **APNG**：`kCGImagePropertyAPNGDelayTime` 直接吃**秒（Double）**，沒有 GIF 的 2cs
     （50fps）下限，逐格用「下一格起點 − 本格起點」即可（`RecordMath.apngDelaysSeconds`），
     不需要累計捨入去消化取整誤差——那是 GIF 特有的問題。
   - 容器層級都設「無限循環」，只是 dictionary key 不同：GIF 用
     `kCGImagePropertyGIFLoopCount`、APNG 用 `kCGImagePropertyAPNGLoopCount`（都已查
     `CGImageProperties.h` 確認 key 名與所屬 dictionary）。
   - 逐格轉完即釋放（`decodeNext` 讀出當下立刻 `downscaled(...)`，不延後），因為
     `output.alwaysCopiesSampleData = false`——sample buffer 背後是 reader 內部緩衝區的借用，
     下一次 `copyNextSampleBuffer()` 就可能回收，留著等下一輪才轉是 use-after-free。
5. **`reader.status == .failed` 必須顯式檢查**（round 2 review fix）：`copyNextSampleBuffer()`
   回 nil 之後，不查 status 就無法分辨「真的讀完」還是「讀到一半失敗」——母帶中途損毀
   （例如錄影當掉留下的截斷檔）會讓 reader 轉 `.failed`，若不查，迴圈只看到 `decodeNext`
   回 nil、誤判成「這段期間畫面靜止」，靜默拿最後一格補滿剩餘所有格，
   `CGImageDestinationFinalize` 照樣成功——吐出一支大半凍結、看起來正常但漏掉損毀點之後
   內容的 GIF/APNG。損毀母帶不得靜默成功。
6. **不可跨執行緒呼叫 `cancelReading()`**（Gifski.app 遷移警告：會觸發 MediaToolbox
   `EXC_BAD_ACCESS`）。`GifExporter` 全程在同一顆 `Task.detached` 裡跑，`await progress(...)`
   只是暫停點、不是另開一顆 Task 平行碰 reader，因此天然滿足這條紀律，`reader.cancelReading()`
   直接用 `defer` 收尾即可，不需要 cooperative check。
7. 已知品質上限（GIF）：ImageIO 是單一全域 256 色調色盤、無時域抖色——UI 操作類（大片平色）
   可接受，漸層/照片內容會 banding。APNG 全彩無此限制，但非通用貼圖格式，因此與 GIF
   並存而非取代。這是零依賴（內建路徑）的自覺取捨，不是 bug。

### 預覽視窗剪裁 UI：trim 讀值時機與 `AVPlayerLooper` 重建

這節是 `trimRange` 從哪裡來（`RecordPreviewWindow.trimAction`），下一節是它怎麼被匯出端消費。

- **讀值只能在 `beginTrimming` 的 completion 當下讀**：`playerView.canBeginTrimming` 為 true、
  `beginTrimming` 結束後從 `player.currentItem.reversePlaybackEndTime`／
  `forwardPlaybackEndTime` 讀選取範圍——這兩個 header 沒明講「trim UI 寫回這裡」，是 AVKit
  官方 trim UI 溝通選取結果的既定慣例，也是 `AVPlayerItem` 上唯一能表達子範圍的 API。
  **實機驗證過這一步本身沒問題**：`canBeginTrimming` 在 `AVQueuePlayer`＋`AVPlayerLooper` 下是
  true，`completion` 裡讀到的兩個值確實反映使用者選取範圍。
- **真正的 bug 在 looper 複本，不在讀值**：`AVPlayerLooper.loopingPlayerItems`（見
  `AVPlayerLooper.h`）是 template item 的至少 3 份複本輪流播放，trim UI 只碰得到
  `player.currentItem`（複本之一），其餘複本的 `forwardPlaybackEndTime` 完全沒被觸及。使用者
  實機回報的症狀正是「剪完會重播，重播後又回到未剪的影片」——循環播放輪到那些沒被改到的複本
  時，播的是全長。header 明講 client 不該手動修改複本屬性，因此正解不是去逐一改每個複本。
- **修法：用專用建構子整顆重建 looper**：`AVPlayerLooper(player:templateItem:timeRange:)`
  （header 原文：「Time range will be accomplished by seeking to range start time and
  setting AVPlayerItem's forwardPlaybackEndTime property **on the looping item
  replicas**」）用一個全新的 `AVPlayerItem`（不是被 trim UI 動過的那個）當 template，讓所有
  複本都套用同一個 `timeRange`，不是只有一個。已用最小重現專案在 `.macOS(.v14)` target 下確認
  這個 initializer 零 warning、無額外可用性標記；使用者實機驗證循環播放的確變成只播剪裁段。
- **退化範圍（duration ≤ 0）不可餵給 looper**：使用者把兩個 trim 把手拖到同一點時，算出的
  `CMTimeRange` duration 是 0——`AVPlayerLooper.h` 明講這種情況會擲
  `NSInvalidArgumentException`，重建下去會直接 crash。做法：`trimRange` 仍照常設定（給匯出用），
  但**不重建 looper**，維持舊 looper 繼續播全長——維持舊行為比 crash 安全，這種退化範圍下
  「預覽循環的內容」與「匯出的範圍」暫時不一致，是已知取捨、不是本輪修法範圍。
- **還原剪裁＝無 `timeRange` 重建**：「還原剪裁」鈕清掉 `trimRange`（設 nil）並呼叫
  `AVPlayerLooper(player:templateItem:)`（不帶 `timeRange` 的版本，跟 `buildUI()` 最初建立
  looper 時是同一個建構子）——header 說明「不給 `timeRange` 等同 `kCMTimeRangeInvalid`，也就是
  `[0, itemToLoop's duration]`」，即整支母帶，讓預覽與匯出一起回到未剪裁狀態。
- **重剪語意**：looper 重建後 `player.currentItem` 是全新複本（沒有 `reverse/forward` 值），
  使用者再按「剪裁」時 trim UI 會從全長重新選——「重剪＝從全長重新選」，不是接續上次的選取，
  可接受。

### 剪裁（timeRange）如何影響匯出

預覽視窗「剪裁」鈕（原生 `AVPlayerView.beginTrimming`）產生的 `CMTimeRange`（母帶絕對時間軸，
見 `RecordPreviewWindow.trimAction`）往下傳到 `GifExporter.prepareReader`——**GIF／APNG／WebP
三者共用同一條路徑**：`saveGifAction`／`saveApngAction` 走 `GifExporter.export(...timeRange:
trimRange...)`，`saveWebpAction` 走 `GifExporter.exportWebP(...timeRange: trimRange...)`；內建
CGImageDestination 路徑（`exportAsync`，GIF 未偵測到 gifski 時／APNG 一律）直接呼叫
`prepareReader`，只有 gifski／img2webp 外部引擎路徑（`exportViaGifski`／`exportViaImg2webp`）
才會先經過 `extractFramesAsPNG` 再轉呼叫 `prepareReader`——不論走哪一條，下面幾條 clamp／
歸零規則都對 WebP 同樣成立，不是只有 GIF/APNG 才有：

- `reader.timeRange = timeRange` 必須在 `startReading()` 之前設（`AVAssetReader.h`：之後設值
  會丟例外）。
- **duration 要 clamp 到母帶實際長度**：`AVAssetReader.h` 對 `timeRange` 的說明是「與
  `[0, asset 實際時長]` 取交集後」才是真正讀到的範圍——呼叫端傳超出母帶尾端的範圍不會報錯，
  只會默默少讀；若這裡的 `duration` 不 clamp，grid／delay 會以「請求的長度」為準，吐出一支
  尾端補滿靜止格、比實際內容更長的動畫。做法：
  `duration = min(timeRange.duration.seconds, assetDuration − rangeStartSeconds)`。
- **PTS 要歸零**：reader 在 `timeRange` 限制下吐出的樣本，PTS 仍是整支母帶的絕對時間軸
  （`timeRange` 只篩選讀哪一段，不會重新歸零），但 grid／sample-and-hold 全部假設「首格 PTS
  對應時間 0」——`decodeNext` 讀出當下立刻減去 `rangeStartSeconds`，不歸零會讓整段輸出跟著
  剪裁範圍的起點平移。
- 存 MP4 的剪裁走完全不同的路：`AVAssetExportSession` + `AVAssetExportPresetPassthrough`
  （不重編碼，只切 `timeRange`），跟 GIF/APNG/WebP 共用的 `AVAssetReader.timeRange` 是兩條
  獨立路徑，細節見 `RecordPreviewWindow.saveMp4Action` 的 header 引用。
- 拍快照、拖曳出檔案**都不受 `trimRange` 影響**（拍快照對「目前播放位置」出手；拖曳一律給
  整段母帶，見 §9）。

### 外部引擎：gifski（GIF）／img2webp（WebP）

本專案仍是零外部依賴、離線 native app；下面兩個外部引擎是**可選加值路徑**，不是預設依賴——
使用者不裝，行為完全等同 r1（GIF 走內建 CGImageDestination；沒有 WebP 匯出）。

- **偵測**：固定路徑 `/opt/homebrew/bin/<工具>`、`/usr/local/bin/<工具>` 依序檢查、
  `isExecutableFile` 驗證——**不 shell `which`**（launchd 環境 PATH 不可靠，CLAUDE.md
  既有教訓）。`GifskiEngine.detect()`／`Img2webpEngine.detect()`。
- **呼叫方式**：`Process` 直接指定 `executableURL`，引數逐一列舉（不靠 shell glob），
  不經過 shell——跟 vendor 程式碼或動態連結完全不同，是「呼叫使用者自行安裝的系統二進位」，
  無授權疑慮（gifski 是 AGPL，見下）。
- **共用管線**：兩者都靠 `GifExporter.extractFramesAsPNG` 把同一份解碼／縮圖／sample-and-hold
  結果逐格寫成零填充檔名的 PNG（`frame-0001.png…`，確保外部工具讀到正確順序），存到
  `anypaint-record-frames-<uuid>/` 暫存目錄，用畢 `defer` 刪除（殘留由啟動清掃兜底，
  `anypaint-record-` 前綴）。進度切兩段：抽格 0→0.7，子程序執行 0.7→1.0。
- **gifski（GIF，`GifEngine.auto`）**：存 GIF 時若偵測到，先走這條路；**任何失敗**（reader
  中途壞掉、spawn 失敗、exit code ≠ 0、輸出檔不存在）都 catch 起來回退內建
  CGImageDestination 路徑，回退會寫一行診斷進 `/tmp/anypaint-record-session.log`
  （`RecordSessionLog`）。`--width` 引數**必傳**（實機驗證：`gifski -h` 記載預設限制約
  800×600，1200×900 來源不傳 `--width` 會被悄悄縮到 600×450）；傳來源寬度後原尺寸不變。
  另外實機測出 **gifski 會把相同的連續格合併**（跟內建路徑逐格輸出不同），因此
  `RecordSelfCheck` 的格數判準（檢查 C）**顯式傳 `engine: .builtin`**，不受本機是否裝 gifski
  影響（見 §9）。設定頁動畫截圖小節有唯讀 hint 顯示目前是否偵測到 gifski。
- **img2webp（WebP，無 GIF 對應的內建回退）**：本機 `CGImageDestinationCopyTypeIdentifiers()`
  探測不到 webp——ImageIO 沒有零依賴的 WebP 編碼路可走。因此「存 WebP」鈕**只在偵測到
  img2webp 時才出現**（不是灰鈕、不是先出現再報錯），失敗直接顯示錯誤，不像 gifski 那樣
  回退。`-d`（per-frame delay，套用到之後所有 frame 直到下一個 `-d`）語法照 libwebp 官方文件
  寫入、**本機未裝 img2webp，尚未實機驗證**（見 §8 手動清單）；本專案固定 fps 抽格＝等長
  delay，`Img2webpEngine.arguments` 會自動把連續相同 delay 摺疊成單一 `-d`。
- **仍不 vendor gifski 本體或連結 ffmpeg**：gifski 是 AGPL，跟零外部依賴、離線 native app
  的定位不合（也沒有商業授權預算）；ffmpeg 需要外部二進位/動態連結，同樣違反定位。內建
  CGImageDestination 路徑借的是 gifski 的**演算法配方**（sample-and-hold、累計捨入、2cs
  下限），不是程式碼本身；呼叫外部 gifski/img2webp 子程序是使用者自主安裝、Process 邊界乾淨
  的另一回事，兩者不衝突。全域調色盤、無抖色是內建路徑（沒裝外部引擎時）的自覺取捨，
  裝了 gifski 之後這個限制就解除了。

### 預覽視窗：匯出中關閉的強制關閉逃生口

`RecordPreviewWindowController.present(...)` 本身是 **async**：視窗尺寸公式需要母帶的實際
像素尺寸，讀 `naturalSize` 只有 async API（載入完才建窗，不是「先開預設尺寸再 resize」——
避免使用者看到視窗尺寸跳動一次）。

`RecordPreviewWindow.close()`（`RecordPreviewWindow.swift:156-192`）在匯出中（GIF／APNG／
WebP，`isExporting` 統一標記）被呼叫（紅鈕或「丟棄」）時，`GifExporter` 沒有 cancel/timeout，
背景 `Task.detached` 可能卡死（例如母帶損毀導致 reader 卡住），若只「擋下關閉、要求等待」而不
給逃生口，使用者除了強制砍掉整個 app 別無他法。因此提供兩顆鈕：「繼續等待」（**預設鈕**，
Enter 觸發，避免誤觸）與「強制關閉」。

強制關閉的安全性（三點都已個別確認，不是假設）：
1. 被拋下的 `GifExporter.export`／`exportWebP` 背景 Task 會繼續跑到完成或失敗——它的
   completion closure 用 `[weak self]`，視窗這時已 forget／可能已釋放，`self` 為 nil 時直接
   no-op，不會 crash。
2. `movieURL` 在強制關閉時會被 `removeItem` 刪掉，但 `AVAssetReader` 對它的檔案描述符已經
   開啟——APFS／POSIX 的 unlink 語意是「目錄項目消失，已開啟的 fd 仍可讀到刪除前的內容」，
   reader 不會因此中途壞掉；最壞頂多是提前 EOF 或 `reader.status` 轉 `.failed` →
   `GifExporter` 走 `completion(.failure(...))`，一樣是上一點的 no-op。
3. 暫存 GIF（`saveGifAction` 裡的 `tmpGif`）不會變孤兒垃圾：它是 `movieURL`
   （`RecordOutputService.tempMovieURL()` 產出，檔名前綴固定 `anypaint-record-`）換副檔名
   而來，落在同一個暫存目錄，app 下次啟動時 `RecordOutputService.cleanupStaleTempFiles()`
   照前綴掃描會一併清掉。

**剪裁中關閉不給這個逃生口**：`isTrimming` 標記與 `isExporting` 是獨立的兩個關閉守衛，處理方式
故意不同——trim overlay 顯示中按關閉，只跳「剪裁進行中——請先按剪裁列的完成或取消」提示、一顆
「好」鈕，沒有「強制關閉」選項。理由：trim 隨時可以讓使用者自己按原生剪裁列的「完成」或
「取消」結束（不像匯出可能因為母帶損毀等原因讓背景 Task 卡死、除了強制關閉別無他法），
不需要（也不該給）逃生口，避免使用者在 trim UI 顯示中把預覽視窗關掉導致不可預期的狀態。

---

## 7. 音訊

定位維持「會動的截圖，不是螢幕錄影機」（§1）沒有變——音訊是**可選**加值（兩個設定開關預設
都關），不是這個功能的預設行為。開啟後，錄出的 MP4 除了既有的一條影像軌，可能再多一條或
兩條音軌。

### 兩軌策略

系統聲與麥克風是兩個**互相獨立**的設定開關（`AppSettings.recordSystemAudio`／
`recordMicrophone`），`RecordOptions.captureSystemAudio`／`captureMicrophone` 各自承載一個。
**兩條軌來源不同**（2026-08-13 起）：系統聲走 SCK（`SCStreamConfiguration.capturesAudio`），
麥克風走 **CoreAudio HAL**（`RecordMicSource` + `AudioInputTap`）——**不走 SCK `.microphone`**，
因為 macOS 26 本機實測 AVFoundation capture 家族（AVCaptureSession／SCK `.microphone`）對麥克風
完全收不到封包（session 正常啟動、無錯、卻零 buffer），而 HAL 那層穩定拿得到。整段定位與決策見
`docs/superpowers/specs/2026-08-13-mic-hal-capture-design.md` §0。
`RecordAudioTracks`（掛在 `WriterBox` 之下，見 §2 架構圖）依開關數量建立 0～2 條
`AVAssetWriterInput`（`systemInput`／`micInput`），固定 AAC、48kHz、128kbps；聲道數：系統聲 2、
**麥克風＝裝置實際聲道數**（`WriterBox(micChannels:)` 由 `RecordMicSource.channels` 傳入，內建麥克風＝1，
不再硬寫 2）。`AVAssetWriterInput` 內部的 audio converter 負責格式轉換（見下方「與正式編碼設定的差異」）。
兩者互不影響：只開系統聲＝1 條音軌，兩者都開＝2 條，兩者都關＝0 條
（`recordAudioTracksEndToEndTests` 三種組合都有 selftest 覆蓋）。

### 掛載點

- **SCStreamConfiguration**：`RecordAudioTracks.configure(_:options:)` 只設
  `capturesAudio`／`excludesCurrentProcessAudio`（**系統聲**）；**不設 `captureMicrophone`**
  ——麥克風不走 SCK。被 `RecordFrameSource.makeStreamConfiguration` 呼叫。
- **AVAssetWriter 掛載**：`WriterBox.init` 建立 `RecordAudioTracks(options:micChannels:)` 後立刻
  `audio.attach(to: writer)`，跟影像 input 同一時間 `writer.add(...)`，都在 `writer.startWriting()`
  之前完成。
- **收格路徑（系統聲）**：`RecordFrameSource.stream(_:didOutputSampleBuffer:of:)` 用 `type` 分流——
  `.screen` 走影像那條（status gate＋`box.append`），`.audio`（系統聲）直接
  `box.appendAudio(sb, type:)`，**不做 `SCFrameStatus` 檢查**（音訊 buffer 不帶這個 attachment）。
- **收格路徑（麥克風）**：`RecordMicSource` 的 HAL IOProc callback 把 PCM 包成 `CMSampleBuffer`
  （PTS 由裝置 host time 經 `CMClockMakeHostTimeFromSystemUnits` 轉成與 SCK 影片同一條 host-time
  時間軸），派進同一條 `sampleQueue` → `box.appendAudio(sb, type: .microphone)`。錄影 stop/abort
  時先 `micSource.stop()`（AudioDeviceStop 等 IOProc 收手）再 finalize。
- `WriterBox.appendAudio` 只把關 `isTerminal`／`writer.status`，實際路由（挑 `systemInput` 還是
  `micInput`）交給 `RecordAudioTracks.append(_:type:sessionStarted:)` 的顯式 `switch`——非
  `.audio`／`.microphone` 的型別直接丟棄，不落到任何一個 input（塞錯型別的 buffer 進 AAC input
  是 Swift 攔不到的 ObjC exception，見 `RecordAudioTracks.swift` 的對應註解）。

### A/V 對齊語意

`WriterBox` 只有一個 session 起點，錨定在**第一個 `.complete` 的影像格**（`box.append` 裡
`writer.startSession(atSourceTime:)`，見 §3）。`RecordAudioTracks.append` 收到音訊 buffer 時
先檢查呼叫端傳入的 `sessionStarted`（`WriterBox` 自己那個布林值的當下快照）——
**session 還沒啟動就整批丟棄**，不緩衝、不等待、不回補。這代表：如果使用者的系統聲/麥克風
在錄影按下的瞬間比第一格畫面先送達（實務上少見，但 SCK 的音訊與畫面是兩條獨立的
`SCStreamOutputType` 派送，時序不保證影像必然先到），那一小段音訊會消失在輸出檔裡，不會被
往後挪去對齊——`recordAudioTracksEndToEndTests` 的「早到的 0.5s 音訊」案例就是測這條
（`Sources/anypaint-selftest/RecordAudioTests.swift`）。

### audio drop 語意＝破洞非漂移

每個 `CMSampleBuffer`（無論影像或音訊）都帶著 SCK 給的**真實 PTS**，`append`／`appendAudio`
只是「這一格要不要真的寫進 writer」的 gate（`isReadyForMoreMediaData` 為 false、或
session 未啟動），從不改寫時間戳、也不會把「被跳過那段時間」的長度轉嫁到後面格子上。
結果是：任何一格被丟（backpressure 也好、session gate 也好），輸出檔裡對應那段時間軸上就是
一段**空白/靜音的破洞**（影像維持上一格畫面、音訊維持靜音，各自獨立），而不是「後面所有內容
往前平移、跟另一條軌漸漸不同步」的**漂移**。這條規則對音訊與影像兩條軌都成立，也是兩條軌
即使各自獨立丟格、彼此仍能維持對齊（同一支母帶裡影像格與音訊格的絕對時間軸永遠一致）的
原因——不需要额外的同步機制去校正，因為兩者本來就沒有機會累積誤差（CLAUDE.md「不要靠輸入
事件推斷世界狀態」同一個精神：這裡靠的是每格自帶的真實時間戳，不是靠數格數／算間隔去反推）。

### 自檢判準與 log 路徑

`RecordAudioSelfCheck`（`--audio-selfcheck`，結構鏡射 `RecordSelfCheck`，見 §8）用
`AVAudioSourceNode` 播一顆 440Hz 純音（0.5 振幅）貫穿全程 4 秒，同時用
`RecordOptions(showsCursor: false, useHEVC: false, captureSystemAudio: true,
captureMicrophone: true, excludesOwnAudio: false)`（**`excludesOwnAudio: false`**——自檢要聽到
自己播的檢測音，跟正式流程預設 `true`（不錄自家音效）相反；`captureMicrophone: true`——同時驗麥克風軌）
錄下**系統聲＋麥克風**。為了讓「內建喇叭播 → 內建麥克風收」的聲學耦合穩定，自檢開始時把系統預設
輸入輸出**切到內建裝置**（`AudioHardwareControl`，以 transport type 解析、不硬寫 UID），跑完在
`finishNow` 還原。停止後：

1. **檢查A**：`asset.loadTracks(withMediaType: .audio).count == 2`（系統聲＋麥克風）。
2. **檢查B（系統聲軌）**：`AVAssetReader` + LPCM float32 輸出設定解碼音軌，交錯/planar **混平均**成單聲道
   `[Float]`，餵進 `RecordMath.goertzelPower`：440Hz 的能量必須同時滿足
   （a）**是 987Hz 能量的 100 倍以上**——987 跟 440 沒有整數倍關係，比純音的 2 倍頻 880 更
   乾淨（AAC 編碼／喇叭與麥克風的耦合都可能在諧波上漏一點能量，880 會讓比值判準不穩）；
   （b）**絕對值 > 0.017381496309072295**——這是 2026-08-12 首次實跑（本機喇叭輸出 → SCK
   系統聲擷取）量到的 440Hz 能量（0.17381496309072295）的 1/10，寫死不吃設定。純比值不夠：
   Goertzel 對頻率誤差極敏感（`goertzelPower` 的判準本身在 selftest 用 439.5Hz 的音源量到掉了
   六成能量），完全靜音時 987Hz 的能量也會趨近 0，比值可能被除法雜訊撐出一個無意義的大數字，
   絕對門檻補上這個退化情況。
3. **檢查C（麥克風軌）**：解碼第 2 條音軌（走全新 HAL 路 `RecordMicSource` 錄下的、內建麥克風
   聲學收到的 440Hz），同樣 Goertzel 判 440 遠高於 987。門檻另定：比值 10x、絕對值
   > 0.000037256（首次實跑 mic power440＝0.00037256 的 1/10）——聲學耦合能量遠低於系統聲 loopback。
4. **檢查D（時長對齊）**：麥克風軌 `timeRange.duration` 與錄製時長差 < 1s——證明 HAL 的 host-time
   PTS 有對齊 SCK 影片時間軸、沒漏封包。**注意 clamshell（螢幕蓋著）會停用內建麥克風**，此時檢查C
   會失敗（不是程式 bug，是硬體被蓋子關掉）。

另外，自檢過程會把**第一個音訊 CMSampleBuffer 的 ASBD**（`RecordFrameSource.onFirstAudioBuffer`
回呼，取自 `CMAudioFormatDescriptionGetStreamBasicDescription`）記進 log——這是 SCK 實際送來
的**原始**格式，跟 `RecordAudioTracks` 寫入時指定的 AAC/48kHz/雙聲道編碼設定是兩件事（後者是
我們自己要的輸出格式，`AVAssetWriterInput` 內部負責轉換，不代表輸入格式）。2026-08-12 本機
實測：`sampleRate=48000.0 channels=2 interleaved=false`——SCK 的系統聲原始格式是 48kHz 雙聲道
**非交錯**（planar）float。

結果寫 `/tmp/anypaint-audio-selfcheck.log`（純文字，一行一筆；逐項檢查用 `✅`／`❌` 行首，
早退路徑——無主螢幕、測試音源啟動失敗、stream 啟動失敗——用 `FAIL ` 開頭，**不是** `PASS:`／
`FAIL:` 這種帶冒號的前綴慣例；全部通過時最後一行是「---- 全部通過 ----」，有失敗則是
「---- 有 N 項失敗 ----」），跑完自動 `exit`（`exitCode` 對應是否有失敗）。啟動同樣**必須
`open -n`**（既有實例會吃掉 `--args`，見 §8）。

**其他觀察（本輪修復波記錄）**：

- **升 macOS 15 後匯出路徑有 3 個 `AVAssetExportSession` 棄用警告**：`RecordPreviewWindow.swift`
  的剪裁匯出 MP4 路徑（`exportAsynchronously(completionHandler:)`／`status`／`error` 三個成員）
  在 macOS 15+ SDK 下建置各印一個棄用警告，官方建議遷移到 `export(to:as:) async throws`。目前
  仍可正常建置與運作（deprecated ≠ 移除），列為待遷項目，不影響本輪功能，不阻塞驗證。
- **空音軌實測結論**：開了 `captureSystemAudio`／`captureMicrophone`（`RecordAudioTracks` 因此
  建了對應的 `AVAssetWriterInput`），但整段錄製期間該來源實際上零 `CMSampleBuffer` 送達時，
  `WriterBox.finish` 仍正常完成（`writer.status == .completed`），輸出檔裡對應的那條音軌
  **完全不會出現**（`tracks(withMediaType: .audio).count` 反映的是實際寫入的軌數，不是設定開了
  幾個開關）——這不是失敗路徑，一次性 probe 實測證實，`RecordAudioTests.swift` 有對應 case
  釘住這個結論。

**系統音量不影響此自檢**：2026-08-12 實測把系統輸出音量調到 0 再跑一次，440Hz 能量仍是
0.237（比開著音量的兩次跑法 0.174／0.174 還略高，屬正常誤差範圍），遠高於絕對門檻——
`SCK` 撈的是**混音前**的 app 輸出，系統音量是輸出裝置那端的後級處理，不影響擷取到的樣本值。
`scripts/verify.sh` 因此不需要 `osascript` 調音量的兜底。

---

## 8. 驗證

```bash
swift run -c release anypaint-selftest             # 純邏輯（GIF delay／sample-and-hold／尾格判斷／Goertzel）
./scripts/build_app.sh release
open -n -a "$PWD/build.noindex/anypaint.app" --args --record-selfcheck
```

**兩層驗證缺一不可**：

1. **selftest**：純邏輯。`RecordMath` 的累計捨入（長序列總時長誤差 < 1cs）、
   sample-and-hold 網格映射（VFR 輸入含大空洞）、尾格補齊判斷（0.5s 門檻）、
   HUD 時鐘文字格式。
2. **app 內自檢**（`RecordSelfCheck`，鏡射 `ScrollCaptureSelfCheck` 的結構）：自己開一個
   「內容會程式化變化的視窗」→ 用正式的 `RecordFrameSource` 真實錄製 6 秒（最後 2 秒刻意
   靜止）→ 用正式的 `GifExporter` 匯出 → 逐項驗證：
   - **檢查 A**：mp4 時長 = wall-clock ± 0.6s（含尾格容差）
   - **檢查 B**：video track 存在、`naturalSize` 等於預期像素尺寸（可播）
   - **檢查 C**：GIF 格數 ≈ 時長 × 12（±2，並與 `RecordMath.gridTimes` 交叉驗證）
   - **檢查 D**：GIF 首格像素寬 = 預期像素寬 / pointScale（1x 尺寸換算正確）

   啟動：`open -n -a <bundle> --args --record-selfcheck`（**必須 `open -n`**——既有實例會吃掉
   `--args`，症狀是「啟動了卻不寫 log」，同滾動截圖既有教訓）。結果寫
   `/tmp/anypaint-record-selfcheck.log`，跑完自動 exit。首跑全過：時長 6.00s、
   格數＝`Int(實測時長×12)`＝71（粗估 72±2 一併過關）、寬 360（＝像素寬 720 ÷ scale 2.0）。

   與正式流程唯一差異：`excludeSelf: false`（自檢要拍的正是自家測試視窗）。其餘（filter／
   sourceRect 座標鏈／queueDepth／WriterBox 補尾格／GifExporter 取樣）完全相同。

合成測試通過 ≠ 實機可用（CLAUDE.md）：`RecordFrameSource` 的收尾早退紀律、`WriterBox`
的 `isTerminal` 冪等化、`reader.status` 檢查，全部是純邏輯 selftest 測不到、只在把整條管線
接起來跑（app 內自檢或實機手動操作）才會現形的坑。

**尚未自動化、仍在手動清單上**（`RecordSelfCheck` 目前不模擬滑鼠點擊、不切前景/背景、
不打字進 HUD，以下都只有靜態推理或部分自動化，沒有端到端驗證）：

| # | 驗證項目 | 預期結果 |
|---|---|---|
| 1 | 點擊圈入鏡 | 錄出的 mp4 裡看得到橘圈（點擊圈的 `exceptingWindows` 白名單只有靜態推理＋windowID 比對邏輯的正確性，沒有自動化驗證會去真的解碼母帶確認圈有沒有拍進去） |
| 2 | HUD／選區框不入鏡 | 錄出的 mp4 裡看不到 HUD 面板或選區框線（app 整體排除兜底，但沒有解碼母帶做過確認） |
| 3 | 失去前景後仍能停止 | 錄製中點別的 app 搶走前景，再按 `⌘⇧R` 仍能正常停止並收到檔案（Carbon 全域快鍵不受 app 前景狀態影響） |
| 4 | 游標／點擊圈開關生效 | 設定分頁關閉游標後，點擊圈選項變灰且不可勾；分別開關兩者錄製，實際行為與設定一致 |
| 5 | 長時間中段靜止 | 錄 10 秒、中間靜止 5 秒 → 收到的 mp4 時長仍 ~10s（不因 SCK 靜止不供格而變短），匯出的 GIF 靜止段播放不跳格 |
| 6 | armed HUD 秒數欄可打字 | **✅ 已驗（使用者實機）**：選區框好、HUD 進入 armed 後，滑鼠點進秒數欄能正常打字，按 Enter 或按「開始」都能生效並開始錄製（`RecordHUDPanel.canBecomeKey` 修復，見 §9） |
| 7 | 通知點擊開位置 | 截圖／滾動截圖／動畫截圖存檔通知點擊後，Finder 開啟並選取該檔案；檔案已被移走時點擊安靜無反應（不報錯） |
| 8 | HEVC 可播＋奇數像素邊長選區 | 設定開啟 HEVC 後錄製匯出的 MP4 能在 QuickTime／預覽 正常播放；框選邊長換算成奇數像素時仍能正常編碼、播放不歪 |
| 9 | 剪裁全流程 | **✅ 已驗（使用者實機）**：`canBeginTrimming` 為 true、trim UI 正常顯示，OK 後選取範圍正確讀出；預覽循環播放正確只播剪裁段（`AVPlayerLooper` 重建修復，見 §6）；GIF／APNG／MP4 剪裁匯出時長一致且內容正確；「還原剪裁」後預覽循環與匯出都正確回到整段母帶。**尚未驗**：WebP 剪裁匯出（本機無 img2webp，見 #12）；剪裁後首格是否為選取起點附近畫面（非黑格或範圍外內容）；重剪（再按「剪裁」）與取消（trim UI 選 Cancel）後 `trimRange` 維持/更新是否正確；退化範圍（兩把手拖到同一點）維持舊 looper 播全長的行為是否符合使用者預期；trim overlay 顯示中按關閉，守衛 alert 出現且取消 trim 後可正常關窗 |
| 10 | 拖曳出 MP4（六項） | 拖到 Finder：檔案落地、檔名符合樣板展開（剝 .png 補 .mp4）、內容為完整可播母帶；拖到瀏覽器：`NSFilePromiseProvider` 的 promise 型拖曳是否被接收端正確接受（部分較舊/客製拖放實作只吃 `NSURL`／`NSFilenamesPboardType`，不吃 promise）；`contentOverlayView` 疊的 `DragOriginView` 確實不擋 `.inline` 控制列的滑鼠事件（scrubber 拖曳、播放/暫停按鈕、原生 click-to-pause 手勢不被吞掉）；右鍵選單／視訊分析選取等 `AVPlayerView` 原生手勢確實穿透 `DragOriginView`；拖曳進行中同時有 GIF/APNG/MP4/WebP 匯出在跑，兩者對同一份母帶的檔案 I/O 不互相干擾；拖曳中途（`writePromiseTo` 背景複製還沒完成）就關閉/丟棄預覽視窗（母帶被刪除）不出錯 |
| 11 | gifski 兩況 | 裝 gifski（`brew install gifski`）：存 GIF 走外部引擎，畫質明顯優於內建（無明顯調色盤 banding）；不裝（或暫時改名模擬移除）：存 GIF 正常回退內建路徑，行為與第一輪相同 |
| 12 | img2webp（三項） | `-d`（per-frame delay）語法在真實 img2webp 上行為與 libwebp 官方文件描述一致（本機未裝，尚未實測，見 §6）；產出的 WebP 讀回檢視畫面/fps/循環都正確；「存 WebP」鈕從偵測到匯出到開啟位置的預覽全流程正常 |
| 13 | APNG 在目標平台可動 | 匯出的 APNG 在預期會用到的平台/軟體（macOS 預覽、瀏覽器、聊天軟體等）上正確播放動畫而非靜態單張（支援度因軟體而異，是已知風險不是 bug） |
| 14 | 麥克風真人聲＋TCC 拒絕＋預覽喇叭鈕（音訊 L3） | 開麥克風設定、對著麥克風說話錄一段 → 用 QuickTime 開匯出的 MP4，確認除了系統聲那條，還有第二條麥克風音軌、內容是剛才講的話（**麥克風軌現在也有自動化覆蓋**：`--audio-selfcheck` 的檢查C／D 播 440Hz 到內建喇叭、用內建麥克風錄，Goertzel 驗 440Hz＋時長對齊——見 §7；此手動項專驗「真人聲、非內建裝置、clamshell 以外」）；首次開啟麥克風時系統彈出 TCC 詢問，選「不允許」後錄製應該正常繼續（少一條音軌而不是整個失敗，`RecordAudioTracks` 對兩個開關互相獨立）；**注意 clamshell（螢幕蓋著）會停用內建麥克風**——測內建麥克風務必開蓋；預覽視窗的喇叭/靜音鈕實際切換播放時的可聽性，不只是圖示變化 |

---

## 9. 不要改回去（曾經試過、失敗了，或被 review 擋下）

| 想改的東西 | 為什麼不能 | 詳見 |
|---|---|---|
| 點擊圈用 live compositing（收到影格後自己疊圓圈再寫入） | 改像素就不能直接 `append(sampleBuffer)`，且四個被調查的實戰專案無一採用；透明視窗讓 SCStream 自然拍入才是唯一與「直接 append」相容的架構 | §5 |
| 用 `Date()` 換算補尾格的時間戳 | SCK 的 PTS 在 host clock 上，`Date` 是 wall-clock，兩者不是同一個時鐘，補的尾格會整段偏移 | §4 |
| GIF delay 逐格天真捨入（`round(1/fps × 100)`） | 累積誤差會讓長片加速約 4%；必須用累計捨入（`已寫入 cs` 追蹤） | §6 |
| `exceptingWindows` 建 filter 之後才建點擊圈視窗 | `exceptingWindows` 是建 filter 當下的靜態快照，之後開的視窗一律拍不進、也排不掉 | §3 |
| `queueDepth` 設 < 5 | `lastSampleBuffer` 永久佔掉 IOSurface 池一張，queueDepth 必須 ≥ 5 才夠用（滾動截圖的 3 不夠） | §3 |
| `abort()`／`stopAndFinish()` 在 `self.stream` 仍是 nil 時直接碰 `self.box` | `start()` 的 await 期間 `self.box` 可能已建好、handler 也可能已在 sampleQueue 上跑；沒有自己的 stream 先 `stopCapture()` 就碰 box，是無同步的跨執行緒寫，與 sampleQueue 上的讀構成真實資料競爭。兩者都必須早退，收尾交給 `start()` 自己的 `pendingStop` 分支 | §4 |
| `WriterBox.finish()`／`cancel()` 沒有 `isTerminal` 冪等旗標 | 同一個窗口下 `abort()` 與 `start()` 收尾分支可能各呼叫一次 `cancel()`，對已終結的 writer 重複呼叫 `markAsFinished`/`cancelWriting` 是 Swift 攔不到的 ObjC exception，直接 crash | §4 |
| `.finishing` 狀態沒有看門狗 | `stopAndFinish()` 鏈路（`finishWriting` 不回呼、`stopCapture` 卡住）一旦卡死，`cancelIfActive` 會被 `state != .finishing` guard 擋死，永久卡死、只能重啟 app | §4 |
| GIF 匯出用 `AVAssetImageGenerator` 精準 seek 逐格取圖 | 精準 seek 慢（Gifski.app 已遷移過這條路到 `AVAssetReader` 循序解碼） | §6 |
| 跨執行緒呼叫 `reader.cancelReading()` | Gifski.app 遷移警告：觸發 MediaToolbox `EXC_BAD_ACCESS`；本專案靠「全程單一 `Task.detached`、await 只是暫停點」規避，不是靠 cooperative check | §6 |
| GifExporter 遇到 `copyNextSampleBuffer()` 回 nil 就直接當成讀完 | 母帶中途損毀（reader 轉 `.failed`）會被誤判成「畫面靜止」，靜默補滿剩餘格數、`Finalize` 照樣成功——必須顯式檢查 `reader.status == .failed` | §6 |
| vendor gifski 或連結 ffmpeg 換更好的 GIF 畫質 | gifski 是 AGPL，跟零外部依賴、離線 native app 的定位不合；ffmpeg 需要外部二進位/動態連結，同樣違反定位。畫質上限是自覺取捨，不是待修的 bug | §6 |
| 拿掉預覽視窗匯出中「強制關閉」逃生口，只擋下關閉要求等待 | `GifExporter` 沒有 cancel/timeout，背景 Task 卡死時（例如母帶損毀）使用者除了強制砍掉整個 app 別無他法；三點安全性已個別確認才敢給這個逃生口，不是隨手加的鈕 | §6 |
| `RecordSelfCheck` 的 fps／format／engine／useHEVC 改成跟著 `AppSettings` 走 | 判準必須確定性：自檢跑出的期望值（時長×fps 的格數、GIF 是否合併相同格、HEVC 位元率）若隨使用者這台機器的設定值或是否裝了 gifski 而變動，同一份程式碼在不同機器/不同時間跑出不同「應該通過」的數字，自檢就不再是可重現的回歸網——因此四處都顯式傳常數（fps 12、`.gif`、`.builtin`、`false`），不吃設定 | §6 |
| gifski 失敗時不回退內建、直接顯示錯誤或跳過 GIF | 使用者體驗會因為「這台機器有沒有裝 gifski」「這次子程序有沒有剛好失敗」而不一致地失敗；內建 CGImageDestination 路徑對同一支母帶一定能成功產生 GIF（本節前 7 點就是回歸網），gifski 是加值不是必要條件，沒有回退等於把「加值」變成「地雷」 | §6 |
| 讓拖曳出的 MP4 套用 `trimRange`（跟到三種匯出格式一樣剪裁後的範圍） | 設計決定（brief／spec 已核）：v1 語意刻意單純化為「一律整段母帶」——拖曳走的是檔案系統複製，不是重新編碼；要套用剪裁得比照 `saveMp4Action` 走 `AVAssetExportSession` 匯到暫存檔再供 promise 讀取，複雜度陡增，而拖曳的使用情境本來就是「快速丟出整段」，跟剪裁後只要片段的匯出情境不同 | §1、§6 |
| 有文字輸入欄位的 nonactivating panel 不覆寫 `canBecomeKey` | borderless `NSPanel` 的 `canBecomeKey` 預設 `false`；`becomesKeyOnlyIfNeeded` 只決定「何時」變 key window，前提是 `canBecomeKey` 本身要為 true——沒覆寫時面板永遠成不了 key window，文字欄收不到任何按鍵（`RecordHUD` 秒數欄實機回報「點了打不了字」，round 1 的 `becomesKeyOnlyIfNeeded` 因此完全無效，round 2 才修對）。純按鈕面板（如 `ScrollHUD`）不需要這條——按鈕靠 hit-test 不需要 key window，不要照抄 `RecordHUD` 的覆寫，兩者的正確做法本來就不同 | §1、CLAUDE.md |
| trim 讀值只在 `beginTrimming` completion 之外的時機讀，或讀完就當作已經反映到播放 | `player.currentItem` 只是 `AVPlayerLooper` 複本之一，trim UI 只改得到這一個複本的 `forwardPlaybackEndTime`；讀值本身在 completion 當下沒問題，但**不重建 looper 就不會反映到循環播放**（其餘複本沒被改到，輪到時播全長）——這是使用者實機回報「剪完會重播回未剪影片」的根因，修法是用 `AVPlayerLooper(player:templateItem:timeRange:)` 整顆重建，不是去改每個複本（header 明講 client 不該碰） | §6 |
| 退化 `timeRange`（duration ≤ 0）餵給 `AVPlayerLooper(player:templateItem:timeRange:)` | `AVPlayerLooper.h` 明講這種情況會擲 `NSInvalidArgumentException`，會直接 crash；使用者把兩個 trim 把手拖到同一點時必然發生。正解是偵測到 `duration <= 0` 就不重建 looper，維持舊 looper 繼續播全長（`trimRange` 仍照常設定，只是這種退化情況下預覽循環的內容與匯出範圍暫時不一致，是已知取捨） | §6 |
| 音訊自檢的比值判準用 880Hz（440 的 2 倍頻）當「不該有能量」對照 | 440Hz 純音經 AAC 編碼／喇叭與麥克風耦合可能在 2 倍頻上漏一點能量，讓「440 能量是 880 能量的 100 倍以上」這個比值判準在邊界附近不穩；改用 987Hz（跟 440 無整數倍關係）量到的能量更乾淨反映「這裡真的沒有訊號」——不是隨手選的數字（brief 指定），selftest 的 `goertzelTests` 仍保留 880 當純函式範例，兩者判準對象不同（selftest 測的是 `RecordMath.goertzelPower` 本身的正確性，自檢測的是「錄到的是不是自己播的音」，各自的頻率選擇不需要一致） | §7 |
| 音訊自檢只看比值、不設絕對門檻 | 完全靜音時 987Hz 的能量也會趨近 0，比值可能被除法雜訊撐出一個無意義的大數字，誤判成「440 遠高於 987」；絕對門檻（實測值的 1/10，寫死）補上這個退化情況，兩個條件必須同時成立 | §7 |
| 音訊自檢的絕對門檻改成跟著本機每次實跑動態調整（例如量到多少就當多少的基準） | 判準必須確定性（同 `RecordSelfCheck` 的既有紀律，見上一條 gifski 相關 gotcha）：門檻若隨每次實跑結果自動調整，自檢永遠會通過，就不再是能抓出「這次錄到的訊號比正常弱很多」這種真實回歸的網——門檻必須是一個獨立於本次量測結果的寫死常數 | §7 |
| `RecordAudioTracks.append` 對音訊 buffer 也做 `SCFrameStatus` 檢查（比照影像的 `.complete` gate） | 音訊 buffer 不帶 `SCFrameStatus` 這個 attachment（跟影像格是不同的 SCK 契約），檢查會永遠失敗、等於音訊全部靜默丟棄；音訊唯一的把關是 `sessionStarted`／`isReadyForMoreMediaData`，不需要也不能比照影像加 status gate | §7 |
