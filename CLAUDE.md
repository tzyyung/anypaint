# anypaint 專案規範與踩坑紀錄

macOS / Swift / AppKit / ScreenCaptureKit 的實測經驗。**每一條都是實機付出代價換來的**，
動手前先讀完相關段落，不要重蹈。

## 建置與驗證

```bash
swift build                                  # 編譯錯誤迭代
swift run -c release anypaint-selftest       # 純邏輯測試（release 才快）
./scripts/build_app.sh release               # 組 .app（滾動截圖務必用 release，見下）
bash scripts/menu.sh                         # 互動選單（選 8＝滾動截圖自檢）
```

- **測試基線是硬約束**：`swift run -c release anypaint-selftest 2>&1 | grep -c "^✅"`，
  任何改動後不得低於基線且 `grep -c "^❌"` 必須是 0。
  **基線＝動手前先跑一次拿到的數字，不是寫在文件裡的數字**——這裡刻意不記通過項數。
  記了必然過期（已經發生兩次：302→362→396），而過期的基線比沒有基線更糟。
- **debug build 的影像匹配慢約 50 倍**（實測單格 1.3–1.7 秒 vs release 21ms）。
  滾動截圖在 debug 下**不可用**：主執行緒被塞爆 → 計時器／HUD／事件監聽全部餓死。
  `menu.sh` 的 dev app 因此改用 release。
- `docs/superpowers/` 與 `.superpowers/` 在 .gitignore 內（設計文件與進度 ledger 只留本機）。

## 滾動截圖

**全部內容在 `docs/scroll-capture.md`（進版控）**——功能行為、資料流、每格處理流程、
核心設計決定、匹配演算法、並發模型、驗證與診斷、效能基準、評估過但沒採用的方案，
以及 §9「不要改回去（曾經試過、失敗了）」的收斂清單。

動這個子系統前先讀那份。**這裡不再重複它的內容**（兩邊各記一份必然漂移，
已經發生過：效能數字散落三處、各自停在不同時期）。

## 通用方法論（跨功能，血淚換來的）

### 合成測資的「物理正確性」比測資本身更重要（最貴的一條）
自檢的稀疏模式曾寫成 `if sparseMode, y < bounds.height * 0.62 { continue }`——`y` 是**視窗
相對**座標，等於「視窗上半永遠不畫字」：文字捲到分界線就消失。**那在物理上不是平移**，
任何對位演算法都必然失敗。

代價：據此「修」了好幾輪演算法，還把一個**根本不存在的缺陷**（「稀疏＋等行距會誤對齊到
行倍數、長圖過量 47%」）寫進文件當成事實。後來用物理正確的測資實測，同樣的稀疏度下
真解排名 1/257、matcher 全中。

**規則**：合成測資的內容必須只由**絕對座標**決定（開窗即得平移關係）。
寫測資時先自問：把兩個窗疊起來，重疊區的內容是否逐像素相同？不是就無效。

### 不要靠輸入事件推斷世界狀態
輸入事件（滾輪 delta、按鍵）表達的是**使用者意圖**，不是世界實際發生了什麼。
要知道世界狀態就直接觀察結果（影像、檔案、回傳值）。
兩者都有用，但**不可互相冒充**——用意圖去推斷狀態，遇到「使用者沒操作但狀態變了」
或「操作了但狀態沒變」就會全盤皆錯。

### 不要從單一測資外推演算法結論
判斷「某個元件該不該留」時，至少跑過**多種內容類型**（密集文字／稀疏留白／
無週期的照片類紋理／深色高對比）再下結論。移除相位相關前跑了 4 類 ×10 組共 40 個已知位移；
而先前把一個不存在的缺陷當真，正是因為只用了一種（而且無效的）測資。

### 改演算法前先量，不要憑推理
寫個一次性 probe 掃過所有候選、印出分數與排名，多數「以為是演算法不夠好」的問題
會當場現形為別的原因。效能同理：實測推翻過兩個「看似明顯的浪費」
（分別只有 0.001ms 與 0.008ms），真正的熱點在別處。

### 合成測試通過 ≠ 實機可用
本專案的致命缺陷幾乎都只在真實環境現形（主執行緒飽和、回呼被抹、滾輪門檻），
軌跡架構的三個坑也全是 selftest 全綠時由實機自檢抓出來的。
改完務必跑自檢，必要時看常駐診斷。

### 不要憑印象寫 OS API
本專案的 API 結論多數來自 `xcrun --show-sdk-path` 下的 header 與實測，不是文件記憶。
寫之前先查，並在動手前用文字陳述「我要用 X，已查 Y，已知風險 Z」。

### Read 工具偶爾會把檔案渲染錯亂
曾對 `ScrollHUD.swift` 出現重複行與截斷，差點基於假內容去「修」不存在的 bug。
**以 `grep` 與 `swift build` 的輸出為真相**，不要只信一次 Read。

## AppKit 陷阱

### overlay 與事件路由（accessory app 特有）
anypaint 是選單列 app（LSUIElement/.accessory），平時**不是前景**：
- `NSPanel(.nonactivatingPanel)` 在非前景 app 下 `makeKeyAndOrderFront` **不會**真正成為系統
  key window → keyDown 全部丟失。overlay `present()` 必須先 `NSApp.activate(ignoringOtherApps: true)`
  （對照可運作的 `SelectionOverlayController.swift`）。
- 即使 activate 了，**不要只依賴 `NSView.keyDown`**：nonactivating panel 被點擊前收不到
  responder 事件。Esc 要用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`。
- **global keyDown monitor 需要輔助使用權限**（本 app 刻意不要求此權限）；
  **scrollWheel 的 global monitor 不需要**。global monitor 收不到送進自家 app 的事件 → 滾輪要
  local + global 雙掛。
- `capturing` 後使用者點過選區（點擊穿透）→ app 失去前景 → local monitor 也收不到 →
  取消要靠 HUD 鈕／再按全域快鍵（Carbon，不受 active 狀態影響）／看門狗。
- borderless `NSPanel` 的 `canBecomeKey` 預設 `false`——`becomesKeyOnlyIfNeeded` 在此時完全無效
  （它只決定「何時」變 key，前提 `canBecomeKey` 已是 true）。HUD 只要有文字輸入欄位就必須子類
  覆寫 `canBecomeKey = true`；純按鈕面板（無文字欄）不需要（RecordHUD 秒數欄實機教訓，
  2026-07-30）。

### 全域 Carbon 快鍵會蓋掉自家視窗的本地鍵（2026-08-02 實測）
全域快鍵在系統層攔截，事件不會送到 app 的 `NSEvent` 本地監聽器。截圖快鍵設成 ⌘T 時，
框選中的 ⌘T（辨識文字）**完全到不了**——實測第二次 ⌘T 直接取消框選（視窗數 2→0）。
因此 overlay 期間必須 `KeyboardShortcuts.disable(MenuBarController.allShortcuts)`，
不能只讓路給部分快鍵。還原務必走單一出口（見 `a77aeb3`）。

量測方式：`CGEvent` ＋ `post(tap: .cghidEventTap)` 送鍵，用 System Events 的
`count of windows` 當觀察值。**不可用 `frontmost`**——框選層是 `.nonactivatingPanel`，前景不變。

### 已知限制（刻意保留）：看門狗關閉＋還沒拖選區＋鍵盤焦點被搶走＝唯一逃生門是結束整個 app
設定頁看門狗選單的「關閉」選項是把逾時時間設成 `0`（`AppSettings.watchdogOptions` 第一個
就是 `0`），而 `armWatchdog` 在總秒數不是正數時直接 return、不排任何逾時。framing 剛開啟、
使用者還沒拖出選區時，工具列預設是隱藏的（`SelectionView.swift` 初始化就把
`toolbar.isHidden = true`）。這兩者疊上「鍵盤焦點被搶走」（Spotlight、通知中心跳出）：
`Esc` 走的是本地 `NSEvent` monitor，焦點不在 overlay 上就收不到；畫面上又沒有取消鈕可以按
（工具列還藏著）；而框選期間全域四顆熱鍵已經整批停用（見上一條「全域 Carbon 快鍵會蓋掉
自家視窗的本地鍵」），所以連原本不受焦點影響的 Carbon 熱鍵也按不動。三者同時發生時，
**除了結束整個 app 沒有別的退出方式**。改動前，截圖熱鍵在這個狀態下仍然按得動，因為
Carbon 熱鍵本來就不看哪個視窗持有鍵盤焦點。

這是**刻意的取捨，不是待修的 bug**：曾考慮的替代方案是「只要熱鍵的組合沒有撞上六個框選
動作中的任何一個，框選期間仍保留該熱鍵可按」，但目前決定維持現狀（全部停用比部分停用
好推理、好維護）。之後若要「修」這個情境，先確認是不是要推翻這個決定，不要當成疏漏改掉。

### 剪貼簿不要放 NSImage——那是未壓縮的 TIFF（2026-08-11 實測）
`pasteboard.writeObjects([NSImage])` **只註冊 `public.tiff`，而且未壓縮**。實測（2880×1864
像素的全螢幕 Retina 選區）：

| 放法 | 剪貼簿上宣告的酬載 | 貼上後點數尺寸 | 只認 TIFF 的接收端 |
|---|---|---|---|
| `writeObjects([NSImage])` | **20.5 MB** | 正確 | 拿得到 |
| `NSPasteboardItem` 只放 PNG | **117 KB**（文字類）／2.7 MB（隨機雜訊最壞） | 正確（見下） | **仍拿得到** |

三件實測結論：

1. **只放 PNG 不犧牲相容性**——macOS 會在有人索取 `public.tiff` 時**即時從 PNG 合成**
   （`pasteboard.data(forType: .tiff)` 仍有值），而合成的那份**不在 `item.types` 裡**，
   所以剪貼簿觀察者掃不到它。`NSImage(pasteboard:)`、`readObjects(forClasses:[NSImage.self])`
   都照樣讀得到。
2. **`rep.size` 必須設成點數尺寸**，不是多餘賦值：PNG 以它寫入解析度。少了它，接收端讀回的
   點數會等於像素數，Retina 截圖貼到其他 app **變成兩倍大**。
3. 為什麼在意 20 MB：剪貼簿上的**每個觀察者**都要把宣告的型別整份讀一次（通用剪貼簿會把
   內容往其他裝置推、遠端桌面類工具會同步），不只是最終貼上的那個 app。

**這個改動與 promise 無關，不要拿它去解剪貼簿卡死。** 兩種寫法 anypaint 都**沒有**掛
promise：`writeObjects([NSImage])` 不是（NSImage 沒實作 `writingOptions`），只放 PNG 也不是
——實測寫入行程**結束之後**，另一個行程仍拿得到 `public.tiff`（1200×800px 那份 3.84 MB／
4.6 ms），所以按需那份是剪貼簿服務轉的，不是寫入端履行的。剪貼簿卡死若出現，要查的是**誰
用 `setOwner:forTypes:` 掛了 promise**（2026-08-11 實例：TeamViewer 的剪貼簿同步在
`CFPasteboardHandleFulfillMessage` 解析自己掛的 promise 時死鎖，anypaint 不在阻塞鏈上）。

也不要「PNG＋TIFF 兩份都明放」：實測那樣觀察者掃到的量回到 14.7 MB，而 TIFF 本來就要得到。

`PinboardService.imageItem(for:)` 是唯一出口，三個複製點（一般截圖、長圖、貼圖視窗）都走它，
取不到點陣資料時回 `nil` 讓呼叫端降級回 `writeObjects([image])`——寧可放大一點的 TIFF，
也不要靜默弄丟使用者的複製。

**注意 `CaptureSaver.writePNG(cgImage:to:)` 不寫 DPI**（`CGImageDestination` 直寫原生像素），
所以不能拿它產生的檔案位元組直接充剪貼簿——尺寸會跑掉。剪貼簿那份要在記憶體另外編碼。

### 生命週期方法的隱性副作用
`present()` 開頭呼叫 `dismiss()` 當「清乾淨」，而 `dismiss()` 會把回呼設成 nil ——
呼叫端「先設回呼、再 present」的話回呼**立刻被抹掉**，症狀是整條流程靜默失效。
拆成「只收視窗」與「完整清理」兩個方法。

### 視窗配置四件套（HUD 類浮層）
`.nonactivatingPanel` + `canBecomeKey=false`（防搶焦點）+
`collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`（fullscreen app 上才顯示）
+ level 高於其他 overlay 且保證後 orderFront。缺一有坑。

### 局部重繪的前提會被「貫穿全畫面的元素」打破（2026-07-27 實機）
`setNeedsDisplay(rect)` 這類局部重繪的優化，前提是「要更新的東西都在游標附近」。
加一條貫穿全螢幕的十字參考線就直接違反它——線在那塊之外的舊像素沒被清 → 殘影。
三個各自獨立的坑，全部由實機回報抓出（selftest 測不到繪製）：

1. **dirty 範圍要含線的整條帶**，且各點的帶要**分開 `setNeedsDisplay`、不要 union**
   （兩條交叉線的外接矩形就是整個畫面，union 等於放棄局部重繪）。
2. **清除不能依賴「前一個事件的座標」**：不同路徑用不同 invalidate 方式（prime 走全重繪、
   hover 走局部），加上 AppKit 合併重繪、macOS 合併 mouseMoved，那個值隨時與畫面脫鉤。
   要記錄**上次真的畫出去的位置**（`SelectionView.lastDrawnCrosshair`），清除就與事件配對無關。
3. **`draw` 裡畫整個 `bounds` 而不是 `dirtyRect`**：低頻時看不出來，一旦每次滑鼠移動都重繪
   （全螢幕背景圖 2880×1864）就跟不上快速移動。畫 `dirtyRect` 並用 `.copy`（最底層不需混合）。

### 疊色描邊在「主線與背景同色」時會掏空中心（2026-07-27 實機）
要讓參考線在任何背景上都看得見，**別用「粗黑線 ＋ 細白線疊正中央」的描邊**：
白背景上白線融進背景消失，黑框的中心被它掏空 → **看起來是兩條平行線**。
正解是**同寬兩層、黑白交錯成單一條線**（白色實線 ＋ 同寬黑色 dash 疊同位置，
同 Photoshop 選取框／Figma 參考線）：任一背景下消失掉一半，剩下的仍在同一條線上。
（也試過「黑實線＋白虛線疊同位置」指望間隙露出黑線提供對比——亮背景下不明顯。）

### 單位：點 vs 像素
spec 寫「最小選區 320px」，程式若拿 `selection.height`（**點**）直接比 320，Retina 上等於
640px、比設計嚴格一倍（實測 600px 的合格選區被誤擋；已修，見 `ScrollCaptureSession.enterArmed`）。
**跨層傳遞尺寸時一律在型別或參數名標明單位**。

換算比值要問對人（2026-07-27 實測釐清）：

| 來源 | 回什麼 | 備註 |
|---|---|---|
| `SCContentFilter.pointPixelScale` | 像素/點 | **擷取影像尺寸就是用它算的**（`ScreenCapturer` config.width/height）→ 要與影像對齊就用它 |
| `NSScreen.backingScaleFactor` | 像素/點 | 本機兩螢幕實測與上者皆為 2.0，但「總是相等」沒在非整數縮放配置下驗過 |
| `CGDisplayMode.pixelWidth/pixelHeight` | 真像素 | 內建 1440×932 點 → 2880×1864 像素 |
| `CGDisplayPixelsWide/High` | **點，不是像素** | 名字騙人（實測回 1440×932）。專案沒用到，別誤用 |

**未驗證的假設（兩處，動到座標換算前先想到它）**：
1. `ScreenCapturer` 的擷取尺寸用 `filter.contentRect`（點），`frameGlobal` 卻用 `screen.frame`（點）——
   測量讀數、即時尺寸標籤、裁切座標全都依賴兩者的點尺寸相同，但程式裡沒有任何地方確認。
   命令列驗不了（`SCContentFilter` 要螢幕錄製權限，終端直跑權限歸終端機、-3801）。
   間接證據：滾動截圖實機基準影格 1957×736 像素 ≈ 選區 978×368 點的兩倍；尺寸標籤長期無誤。
2. `ScrollCaptureSession.enterArmed` 拿 `backingScaleFactor` 當 `pointPixelScale` 用（註解自稱
   「同一顆螢幕上等同」）——本機一致，非整數縮放未驗。

## ScreenCaptureKit

- `SCContentFilter(display:excludingApplications:exceptingWindows:)` 按 bundleID 排除自家 app；
  **不可用 `excludingWindows:`**（那是建立當下的靜態視窗快照，session 中途才開的 HUD 會被拍進去）。
- `sourceRect` 單位是**點**、display logical 上左原點 → 需像素格對齊 + Y 翻轉。
- `width`/`height` **必設**，否則輸出被縮進預設 1920×1080，匹配直接失準。
- 畫面靜止時**不供新格**（只送 `.idle`）。任何「等下一格」的判定都要計時器驅動。
- handler 內立即 copy 成 CGImage，不可外流 CVPixelBuffer（IOSurface 池只有 queueDepth 張）。
- **TCC 責任歸屬**：從終端直跑 `Contents/MacOS/anypaint` 會把螢幕錄製權限歸給終端機（實測 -3801 拒絕）。
  要用 app 自己的授權身分必須走 launchd：`open -a <app> --args <參數>`（環境變數不會傳，用啟動參數）。
- **既有實例會吃掉 `--args`**：若 app 已在執行（例如留著的 dev 實例），`open -a … --args` 只會
  喚醒它、**參數完全不傳**，症狀是自檢「啟動了卻不寫 log」。要用 **`open -n`** 開獨立實例。
  自檢模式不進正常啟動流程（跑完自己 exit），不會與常駐實例搶選單列。
- `SCShareableContent` 偶發回 **`noDisplays`** 導致 stream 啟動失敗（短時間內反覆開多個實例時
  較容易遇到）。這是暫時性的：清掉殘留實例後重試即可，不要當成程式缺陷去追。
- **麥克風不要走 SCK `.microphone`（也不要走 AVCaptureSession）——走 CoreAudio HAL**（2026-08-13 實測）。
  macOS 26 本機：AVFoundation capture 家族（`AVCaptureAudioDataOutput` 與 SCK `config.captureMicrophone`/
  `.microphone` output）對麥克風**完全收不到封包**——session 正常啟動、connection active/enabled、
  `authorizationStatus=.authorized`、無 runtimeError，`captureOutput` 卻零呼叫；同機 QuickTime（同一套
  AVFoundation capture API）電平會跳、SCK **視訊**與**系統聲**都正常，只有麥克風 capture 這條死。
  用 `AudioDeviceCreateIOProcIDWithBlock`（HAL，`AudioInputTap`）在同一 app／簽章／啟動方式下穩定拿得到。
  現行麥克風路：`AudioInputTap`→`MicLevelMonitor`（電平表）／`RecordMicSource`（錄影軌）。之後若有人想
  「改回 SCK 麥克風比較簡潔」——先重讀 `docs/superpowers/specs/2026-08-13-mic-hal-capture-design.md` §0，
  這是實測付出代價換來的結論，不是沒試過。
- **clamshell（筆電螢幕蓋著）會停用內建麥克風**——內建麥克風會送純數位靜音（HAL tap 收到全 0），不是
  程式 bug。測內建麥克風務必開蓋（2026-08-13 實測，曾一度誤判內建麥克風壞掉）。

## 診斷原則

- **NSLog 在未公證自簽 app 撈不到**（`log show` 也查不到、從終端跑 stderr 被系統接管）→
  診斷一律直接寫檔案。
- 滾動截圖的診斷工具（常駐 session log、app 內自檢）與判準見 `docs/scroll-capture.md` §7。

## 工作方式

- **回答一律條列式、只講重點、不要廢話、不要鋪陳**：先給結論再（必要時）給細節，需要更多他會問。
  講錯就一行更正，不要辯解式長篇。冗長對使用者是負擔＋夾帶錯誤的風險，不是「更完整」。
- commit **一律不加 Claude 落款**（無 Co-Authored-By），訊息用繁中。
- 動子系統前先讀它的文件（滾動截圖＝`docs/scroll-capture.md`、動畫截圖＝`docs/animated-capture.md`）；
  文件與程式碼不符時**以程式碼為準並立刻修文件**，不要留著兩套說法。
