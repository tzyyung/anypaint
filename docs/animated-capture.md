# 動畫截圖：功能與做法

**這是動畫截圖的單一事實來源**：功能行為、資料流、每格處理、核心設計決定、驗證方式，
以及 §8「不要改回去」的收斂清單，全部在這裡。程式碼與這份不符時**以程式碼為準並立刻修這份**。

`CLAUDE.md` 只放跨功能的通用規範，**不重複本文的內容**（兩邊各記一份必然漂移，
`docs/scroll-capture.md` 已經吃過這個虧）。
`docs/superpowers/specs/2026-07-29-animated-capture-design.md` 是「當初為什麼這樣決定」的
設計快照，不是現況——實作期間有幾處被 review 修正過（見各段落標註）。

最後更新：2026-07-29

---

## 1. 使用者看到的行為

`⌘⇧R`（設定可改）→ 拉框圈住要錄的區域 → HUD 待命（可設錄製秒數，空白＝不限）→
按「開始」→ 錄製（HUD 顯示計時／倒數）→ 停止（手動鈕／倒數到／看門狗／stream error 共用
同一條路徑）→ 預覽視窗（AVPlayerView 循環播放）→〔存 GIF〕〔存 MP4〕〔丟棄〕。
「丟棄」與紅鈕關閉共用同一個 `close()`；GIF 匯出中關閉會先跳警示，需要選「強制關閉」才會
真正關窗並刪除母帶（見 §6 的逃生口說明）。

定位是「會動的截圖」，不是螢幕錄影機：不錄音訊、不能暫停續錄、不做 webcam。

| 行為 | 說明 |
|---|---|
| 逃生路徑：取消（丟棄） | Esc（僅 selecting/armed）、HUD 取消鈕、selecting/armed 中再按同一顆全域快鍵（Carbon，不受 app 前景狀態影響） |
| 逃生路徑：停止（收檔保留） | recording 中再按同一顆全域快鍵、HUD 停止鈕、倒數到、看門狗、stream error 兜底——五者共用同一條停止程序（§4） |
| 不限時看門狗 | 10 分鐘自動走正常停止路徑（防忘記停吃光磁碟） |
| 錄製中顯示游標／點擊高亮圈 | 設定可各自關；**游標關閉時點擊圈勾選框連動停用**（`CaptureSettingsViewController.updateClickRingEnabledState`）——點擊圈要開，游標必須先開（Kap 的 UX 細節，設定 → 控制/截圖分頁） |
| 最小選區 | 64 **點**（`RecordSession.minSelectionEdgePt`；錄製無匹配需求，門檻遠低於滾動截圖的 320px） |
| 匯出 MP4 | 搬移母帶（copy，非 move——之後可能還要匯 GIF）；零轉檔，母帶本身即最終品質 |
| 匯出 GIF | 12fps、1x（點）尺寸，背景 queue 解碼，預覽窗顯示進度 |

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
     └─ RecordPreviewWindowController      收檔後開預覽視窗
          └─ GifExporter                   母帶 → GIF（背景 Task.detached）

RecordMath.swift     純計算（GIF delay／sample-and-hold／尾格判斷／HUD 時鐘文字），selftest 可測
RecordOutputService  暫存母帶路徑、殘留清掃、快速儲存（CaptureOutputService 的 side path）
RecordSelfCheck.swift 內建自檢工具（見 §7），不參與正式流程
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

## 6. GIF 匯出（`GifExporter`）

1. `AVAssetReader` + BGRA output settings **循序解碼**母帶——不用 `AVAssetImageGenerator`
   （精準 seek 慢，Gifski.app 已遷移過這條路）。
2. 均勻目標網格（12fps，`RecordMath.gridTimes`）＋ **sample-and-hold**
   （`RecordMath.sampleHoldIndices`）：對每個目標時間取「PTS ≤ 目標」的最新解碼格；一格可
   重複使用、也可被跳過——天然消化 VFR 母帶的靜止空洞（SCK 靜止不供格）。
   `GifExporter.exportAsync` 內的線上迴圈（`current`/`next` 解碼超前一格）與這個純函式
   逐字對應，行為若歧異以純函式（有 selftest）為準。
3. 縮到 **1x（點）尺寸**（2x Retina GIF 檔案爆炸；Gifski.app 對長邊 >1200px 也會警告）。
4. `CGImageDestination` 寫入：
   - per-frame delay 用**累計捨入**（`RecordMath.gifDelaysCentiseconds`）：
     `delay_cs = round(累計秒×100) − 已寫入 cs`，clamp 下限 2cs（逐格天真捨入 1/12s→8cs
     會累積漂移，長片會加速約 4%；gifski `src/lib.rs` 同法）。
   - `kCGImagePropertyGIFLoopCount = 0`（無限循環）。
   - 逐格轉完即釋放（`decodeNext` 讀出當下立刻 `downscaled(...)`，不延後），因為
     `output.alwaysCopiesSampleData = false`——sample buffer 背後是 reader 內部緩衝區的借用，
     下一次 `copyNextSampleBuffer()` 就可能回收，留著等下一輪才轉是 use-after-free。
5. **`reader.status == .failed` 必須顯式檢查**（round 2 review fix）：`copyNextSampleBuffer()`
   回 nil 之後，不查 status 就無法分辨「真的讀完」還是「讀到一半失敗」——母帶中途損毀
   （例如錄影當掉留下的截斷檔）會讓 reader 轉 `.failed`，若不查，迴圈只看到 `decodeNext`
   回 nil、誤判成「這段期間畫面靜止」，靜默拿最後一格補滿剩餘所有格，
   `CGImageDestinationFinalize` 照樣成功——吐出一支大半凍結、看起來正常但漏掉損毀點之後
   內容的 GIF。損毀母帶不得靜默成功。
6. **不可跨執行緒呼叫 `cancelReading()`**（Gifski.app 遷移警告：會觸發 MediaToolbox
   `EXC_BAD_ACCESS`）。`GifExporter` 全程在同一顆 `Task.detached` 裡跑，`await progress(...)`
   只是暫停點、不是另開一顆 Task 平行碰 reader，因此天然滿足這條紀律，`reader.cancelReading()`
   直接用 `defer` 收尾即可，不需要 cooperative check。
7. 已知品質上限：ImageIO 是單一全域 256 色調色盤、無時域抖色——UI 操作類（大片平色）可接受，
   漸層/照片內容會 banding。這是零依賴的自覺取捨，不是 bug。

### 為什麼不用 gifski / ffmpeg（AGPL 與依賴取捨）

- **gifski 是 AGPL**：不能 vendor 進本專案（本專案是零外部依賴的離線 native app，AGPL 的
  網路服務條款與這個定位不合，也沒有商業授權預算）。借的是它的**演算法配方**
  （sample-and-hold、累計捨入、2cs 下限），不是程式碼本身。
- **ffmpeg**：需要外部二進位或動態連結，違反零外部依賴定位；`AVAssetReader` +
  `CGImageDestination` 都是系統框架，換不到更好的畫質但換到「不需要額外安裝任何東西」。
- 代價很明確：全域調色盤、無抖色，畫質上限低於 gifski/ffmpeg palettegen 路線。
  這是本專案「簡單、零依賴」優先於「畫質最優」的產品裁決，寫在這裡讓日後不會有人
  想「順手」引入 gifski 又踩到授權問題。

### 預覽視窗：匯出中關閉的強制關閉逃生口

`RecordPreviewWindowController.present(...)` 本身是 **async**：視窗尺寸公式需要母帶的實際
像素尺寸，讀 `naturalSize` 只有 async API（載入完才建窗，不是「先開預設尺寸再 resize」——
避免使用者看到視窗尺寸跳動一次）。

`RecordPreviewWindow.close()`（`RecordPreviewWindow.swift:156-192`）在 GIF 匯出中被呼叫
（紅鈕或「丟棄」）時，`GifExporter` 沒有 cancel/timeout，背景 `Task.detached` 可能卡死
（例如母帶損毀導致 reader 卡住），若只「擋下關閉、要求等待」而不給逃生口，使用者除了強制
砍掉整個 app 別無他法。因此提供兩顆鈕：「繼續等待」（**預設鈕**，Enter 觸發，避免誤觸）與
「強制關閉」。

強制關閉的安全性（三點都已個別確認，不是假設）：
1. 被拋下的 `GifExporter.export` 背景 Task 會繼續跑到完成或失敗——它的 completion closure
   用 `[weak self]`，視窗這時已 forget／可能已釋放，`self` 為 nil 時直接 no-op，不會 crash。
2. `movieURL` 在強制關閉時會被 `removeItem` 刪掉，但 `AVAssetReader` 對它的檔案描述符已經
   開啟——APFS／POSIX 的 unlink 語意是「目錄項目消失，已開啟的 fd 仍可讀到刪除前的內容」，
   reader 不會因此中途壞掉；最壞頂多是提前 EOF 或 `reader.status` 轉 `.failed` →
   `GifExporter` 走 `completion(.failure(...))`，一樣是上一點的 no-op。
3. 暫存 GIF（`saveGifAction` 裡的 `tmpGif`）不會變孤兒垃圾：它是 `movieURL`
   （`RecordOutputService.tempMovieURL()` 產出，檔名前綴固定 `anypaint-record-`）換副檔名
   而來，落在同一個暫存目錄，app 下次啟動時 `RecordOutputService.cleanupStaleTempFiles()`
   照前綴掃描會一併清掉。

---

## 7. 驗證

```bash
swift run -c release anypaint-selftest             # 純邏輯（GIF delay／sample-and-hold／尾格判斷）
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
| 6 | armed HUD 秒數欄可打字 | 選區框好、HUD 進入 armed 後，滑鼠點進秒數欄能正常打字並在「開始」後生效（nonactivating panel 的鍵盤路由是 CLAUDE.md 點名的高風險區） |

---

## 8. 不要改回去（曾經試過、失敗了，或被 review 擋下）

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
