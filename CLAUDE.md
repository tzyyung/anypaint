# anypaint 專案規範與踩坑紀錄

macOS / Swift / AppKit / ScreenCaptureKit 的實測經驗。**每一條都是實機付出代價換來的**，
動手前先讀完相關段落，不要重蹈。

## 建置與驗證

```bash
swift build                                  # 編譯錯誤迭代
swift run -c release anypaint-selftest       # 純邏輯測試（release 才快；目前 362 項）
./scripts/build_app.sh release               # 組 .app（滾動截圖務必用 release，見下）
bash scripts/menu.sh                         # 互動選單（選 8＝滾動截圖自檢）
```

- **測試基線是硬約束**：`swift run -c release anypaint-selftest 2>&1 | grep -c "^✅"`，
  任何改動後不得低於基線且 `grep -c "^❌"` 必須是 0。
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

### 生命週期方法的隱性副作用
`present()` 開頭呼叫 `dismiss()` 當「清乾淨」，而 `dismiss()` 會把回呼設成 nil ——
呼叫端「先設回呼、再 present」的話回呼**立刻被抹掉**，症狀是整條流程靜默失效。
拆成「只收視窗」與「完整清理」兩個方法。

### 視窗配置四件套（HUD 類浮層）
`.nonactivatingPanel` + `canBecomeKey=false`（防搶焦點）+
`collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`（fullscreen app 上才顯示）
+ level 高於其他 overlay 且保證後 orderFront。缺一有坑。

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

## 診斷原則

- **NSLog 在未公證自簽 app 撈不到**（`log show` 也查不到、從終端跑 stderr 被系統接管）→
  診斷一律直接寫檔案。
- 滾動截圖的診斷工具（常駐 session log、app 內自檢）與判準見 `docs/scroll-capture.md` §7。

## 工作方式

- commit **一律不加 Claude 落款**（無 Co-Authored-By），訊息用繁中。
- 動子系統前先讀它的文件（滾動截圖＝`docs/scroll-capture.md`）；
  文件與程式碼不符時**以程式碼為準並立刻修文件**，不要留著兩套說法。
