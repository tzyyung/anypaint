# anypaint 專案規範與踩坑紀錄

macOS / Swift / AppKit / ScreenCaptureKit 的實測經驗。**每一條都是實機付出代價換來的**，
動手前先讀完相關段落，不要重蹈。

## 建置與驗證

```bash
swift build                                  # 編譯錯誤迭代
swift run -c release anypaint-selftest       # 純邏輯測試（release 才快；目前 302 項）
./scripts/build_app.sh release               # 組 .app（滾動截圖務必用 release，見下）
bash scripts/menu.sh                         # 互動選單（選 8＝滾動截圖自檢）
```

- **測試基線是硬約束**：`swift run -c release anypaint-selftest 2>&1 | grep -c "^✅"`，
  任何改動後不得低於基線且 `grep -c "^❌"` 必須是 0。
- **debug build 的影像匹配慢約 50 倍**（實測單格 1.3–1.7 秒 vs release 30–46ms）。
  滾動截圖在 debug 下**不可用**：主執行緒被塞爆 → 計時器／HUD／事件監聽全部餓死。
  `menu.sh` 的 dev app 因此改用 release。
- commit **一律不加 Claude 落款**（無 Co-Authored-By），訊息用繁中。
- `docs/superpowers/` 與 `.superpowers/` 在 .gitignore 內（設計文件與進度 ledger 只留本機）。

## 影像處理／滾動截圖的核心教訓

### 1. 動作判定必須用「影像證據」，不可用輸入事件量
**最貴的一條**：曾用「累積滾輪位移 ≥ 10 點」當 motion gate。實機診斷顯示整場 session
收到 **116 格影格（畫面確實一直在動）但累積滾輪只有 3 點**，全被門檻擋掉、一次匹配都沒跑，
長圖等於單張影格。

原因：`scrollingDeltaY` 的尺度隨輸入裝置差異極大，而且使用者可能用**捲軸拖曳、鍵盤 Page Down、
或頁面自行捲動**——那些完全沒有滾輪事件。

SCStream 只在畫面改變時供格，所以「這格與上次處理過的格不同」才是唯一可靠的動作證據
（現用抽樣 2048 點的指紋比對）。**任何「靠輸入事件推斷世界狀態」的設計都要先問：
有沒有直接觀察結果的方法？**

### 2. 匹配用整個重疊區的 ZNCC，不要 band 取樣
band 取樣連續踩三個互相牽制的坑：
1. 平坦 band 的 ZNCC 若回 1（完美相關），無資訊的 band 在**任何位移**下都投完美 →
   分數曲面被抹平 → 深色終端機／大片留白頁面永久判 ambiguous。
2. 改成剔除平坦 band 後，band 位置隨候選位移改變 → 大位移剩少數 band 更易得低分 →
   系統性偏好過大位移（實測拼出 203% 的重複內容）。
3. 想用固定 band 位置兩全，卻在「窄（大位移才有效）vs 寬（稀疏內容才有料）」之間無解。

ZNCC 本身已正規化 → 不同大小的重疊可直接比較；去均值後平坦區對分子分母貢獻趨零，
既不冒充相關也不壓過有紋理處。**三個坑一次消解。**

### 3. 金字塔精修的餘裕與取樣精度
- 精修半徑要 **6**（不是 3）：每上一層放大 2 倍，前層 ±1~2 量化誤差會變成 ±2~4，
  ±3 只剩 1px 餘裕，實測會落在窗外造成 dy 差 1px。
- 粗掃層可隔列取樣省成本，**最終層必須全列**：隔列取樣讓分數對 ±1px 不敏感甚至排名反轉
  （實測 dy=201 的分數比正解 dy=200 更低）。

### 4. 救援層不可自己說了算
Vision 全圖對位與 1-D 相位相關在**完全沒有重疊**的影格上仍會給出看似合理的位移，
接受後會把錯誤內容永久拼進長圖。所有救援估計都要經 matcher 以它為 prior 複核並過閘門；
唯一例外是「近似接合」路徑，那條要自帶絕對品質閘（實測分佈：真匹配 ≈0.0、無重疊 ≈0.43，
門檻 0.35 可分開）。

### 5. 失敗的預設行為要是「保留內容」，不是「丟格」
原本「三層匹配鏈全敗就丟格」，在稀疏內容下會讓整段捲動內容永久消失——使用者的實際感受是
「捲了很多卻只看到最初框選的一小塊」，不可接受。**完整性優先於接縫完美**：改為用影像估計
（相位相關原始值）近似接合，HUD 明確告知。

### 6. 收工條件不可用「連續失敗次數」
「連續 10 格失敗 → 收工」在 30fps 下只有 **1/3 秒**，使用者手一甩超出可匹配範圍就被強制結束，
來不及依提示回捲救回。改用時間門檻（12 秒完全無進展）。

### 7. 已知未解：稀疏＋等行距內容的行倍數誤對齊
相位相關在「大半空白、文字等行距」的內容上會對齊到錯誤的行倍數
（自檢實測估出 64/72/96，真值 48）→ 長圖過量約 47%（內容都在但有重複段）。
試過「真實匹配平均速度當上界」但真實匹配稀少時無效。候選方向見 `.superpowers/sdd/progress.md`。

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
640px、比設計嚴格一倍（實測 600px 的合格選區被誤擋）。**跨層傳遞尺寸時一律在型別或參數名
標明單位**。

## ScreenCaptureKit

- `SCContentFilter(display:excludingApplications:exceptingWindows:)` 按 bundleID 排除自家 app；
  **不可用 `excludingWindows:`**（那是建立當下的靜態視窗快照，session 中途才開的 HUD 會被拍進去）。
- `sourceRect` 單位是**點**、display logical 上左原點 → 需像素格對齊 + Y 翻轉。
- `width`/`height` **必設**，否則輸出被縮進預設 1920×1080，匹配直接失準。
- 畫面靜止時**不供新格**（只送 `.idle`）。任何「等下一格」的判定都要計時器驅動。
- handler 內立即 copy 成 CGImage，不可外流 CVPixelBuffer（IOSurface 池只有 queueDepth 張）。
- **TCC 責任歸屬**：從終端直跑 `Contents/MacOS/anypaint` 會把螢幕錄製權限歸給終端機（實測 -3801 拒絕）。
  要用 app 自己的授權身分必須走 launchd：`open -a <app> --args <參數>`（環境變數不會傳，用啟動參數）。

## 診斷工具（都是踩坑後建的，別再重造）

- **常駐 session 診斷**：每次滾動截圖自動寫 `/tmp/anypaint-scroll-session.log`
  （session 起訖、選區、第一格尺寸與平均亮度、每格 outcome 與 matcher 判定、收尾統計）。
  第一格的平均亮度可判定「擷取到的畫面是否與使用者眼見一致」——這條區分了「擷取階段」與
  「匹配階段」的問題。
- **內建自檢**（無需人工互動）：`open -a build.noindex/anypaint.app --args --scroll-selfcheck`
  自己開會動的視窗、真實 SCStream 擷取、跑完整匹配鏈，驗證拼接量落在預期 ±10%，
  結果寫 `/tmp/anypaint-selfcheck.log`、拼圖寫 `/tmp/anypaint-selfcheck.png`。
  可調參數：`--selfcheck-height=186 --selfcheck-step=90 --selfcheck-sparse=1`。
  - 自檢判準**上下界都要卡**：只設下限的話「拼太多」（重複內容）也會 PASS（曾出現 203% 報 PASS）。
  - 自檢情境要確認測資真的落在**選區內**（曾把文字畫在選區外 → 擷取到 100% 空白的無效情境）。
- **NSLog 在未公證自簽 app 撈不到**（`log show` 也查不到、從終端跑 stderr 被系統接管）→
  診斷一律直接寫檔案。

## 工作方式

- **不要憑印象寫 OS API**：本專案的 API 結論多數來自 `xcrun --show-sdk-path` 下的 header
  與實測，不是文件記憶。寫之前先查，並在動手前用文字陳述「我要用 X，已查 Y，已知風險 Z」。
- **Read 工具偶爾會把某些檔案渲染錯亂**（本 session 對 `ScrollHUD.swift` 出現重複行與截斷，
  差點基於假內容去「修」不存在的 bug）。**以 `grep` 與 `swift build` 的輸出為真相**，
  不要只信一次 Read。
- **合成測試通過 ≠ 實機可用**。本功能的三個致命缺陷都只在真實環境現形（主執行緒飽和、
  回呼被抹、滾輪門檻）。改完務必跑自檢，必要時看常駐診斷。
