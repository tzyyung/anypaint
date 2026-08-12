# 本機自動化 RPC

anypaint 內建一個**只在明確要求時才啟動**的本機 RPC 伺服器，讓外部工具（測試腳本、其他
agent）不必操作滑鼠鍵盤就能查狀態、截自己的 UI、以及驅動動畫截圖的開始/停止。安全邊界：
`UITestServer` 正常啟動完全不註冊，只有 `--uitest` 啟動參數，或 `AppSettings.allowLocalAutomation`
設定開關開著，才會啟動這個伺服器。

程式碼：`Sources/AnypaintKit/UITest/UITestServer.swift`（伺服器與命令表）、
`Sources/anypaintctl/main.swift`（CLI 客戶端）。動畫截圖特有的命令（`startRecord`／
`stopRecord`／`abortRecord`）接線在 `AppDelegate.handleUITestCommand`——這份文件只講 RPC
協定本身；`RecordSession` 狀態機與事件觸發時機的細節見 `docs/animated-capture.md`。

---

## 1. 傳輸與啟動

- **傳輸**：`CFMessagePort`（本機 IPC，非網路 socket），port 名稱固定
  `com.aidaris.anypaint.uitest`。註冊在主執行緒 runloop（`.commonModes`），callback 因此天然在
  `@MainActor` context 上執行，可直接碰 UI 狀態。
- **請求／回應格式**：JSON。請求至少要有 `"cmd"` 鍵；其餘鍵依命令而定。回應一律是物件，至少有
  `"ok"`（`Bool`）與 `"seq"`（伺服器目前的事件計數器值）。**`seq` 只在事件真正發出時遞增**
  （`UITestServer.emit`，見 §3）——`handle` 本身不會讓它前進，連續呼叫但中間沒有任何事件發出
  的命令（例如連打兩次 `getState`）會拿到**相同**的 `seq`，不能拿它判斷「這是第幾個命令」。
- **啟動 app**：`open -n -a <bundle> --args --uitest`（`-n` 開獨立實例、`--args` 才會把參數傳給
  app 自己的授權身分——理由同 `CLAUDE.md` 的 `open -n --args` 教訓）；或把
  `AppSettings.allowLocalAutomation` 設成 true 讓正常啟動的 app 也開這個埠（給長駐 dev 實例用，
  不用每次重開）。
- **事件 log**：`/tmp/anypaint-uitest-events.jsonl`（JSON Lines，一行一個事件，見 §3）。
  `register()` 在每次啟動時會先 truncate 這個檔案——`seq` 每次啟動都從 0 重新算，若不清掉上一輪
  留下的舊行，這次的 `seq` 會跟舊行撞號，`wait-event --after` 的游標保證就整條失效。一個實例＝
  一條乾淨時間軸，不是跨啟動累積的歷史記錄。
- **自拍截圖目錄**：`/tmp/anypaint-uitest-shots`（`screenshotSelf` 落地的 PNG，見 §2）。

---

## 2. 命令表

前三個是 `UITestServer` 內建、不需要 `AppDelegate` 接線就能用；後四個是動畫截圖專用，由
`AppDelegate.handleUITestCommand` 回應（`UITestServer.handle` 的 `default` 分支：先問
`commandHandler`，回 `nil` 才落回 `unknownCommand`）。

| 命令 | 參數 | 成功回應 | 失敗回應 |
|---|---|---|---|
| `getState` | 無 | `{ok:true, windows:[{title,frame,class}], eventLog:"/tmp/anypaint-uitest-events.jsonl"}`（`windows` 只列 `isVisible` 的視窗） | — |
| `dumpUI` | 無 | `{ok:true, tree:[{title,class,views:{...}}]}`——`tree` 陣列每項對應一個可見視窗；`views` 是該視窗 `contentView` 的**根節點物件**（不是陣列）。**兩層 key 名不同**：每個節點自己的欄位是 `class`／`frame`／`hidden`（`NSButton` 多帶 `title`／`enabled`，`NSTextField` 多帶 `text`），往下遞迴的子視圖放在 `subviews`（陣列，只有非空時才會出現這個 key）——最外層是 `views`（單數、單一物件），遞迴層是 `subviews`（複數、陣列），兩者不是同一個 key | — |
| `screenshotSelf` | 無 | `{ok:true, paths:["/tmp/anypaint-uitest-shots/winN-<epoch>.png", ...]}`（對每個可見視窗的 `contentView` 各存一張 PNG） | — |
| `openSettings` | 無 | `{ok:true}` | — |
| `startRecord` | `rect`: `"x,y,w,h"`（AppKit 全域座標，點，左下原點） | `{ok:true}`（跳過拉框互動，直接以此矩形進 armed 並開始錄製——`RecordSession.startProgrammatically`） | `{ok:false, error:"busy"}`（已有錄製在跑，不是 toggle）／`{ok:false, error:"noScreenRecordingPermission"}`（`CGPreflightScreenCaptureAccess()` 為 false——RPC 路徑不進互動式權限詢問，直接拒絕，避免在 CFMessagePort callback 上 runModal 卡死整條通道）／`{ok:false, error:"badRect"}`（`rect` 解析失敗、或矩形沒有完整落在目標螢幕的 `frame` 內、或找不到目標螢幕）／`{ok:false, error:"selectionTooSmall"}`（矩形合法但邊長 < `RecordSession.minSelectionEdgePt`） |
| `stopRecord` | 無 | `{ok:true}`（正常停止，收檔保留——同熱鍵在 recording 狀態下再按一次） | `{ok:false, state:"<RecordSession.state 的字串描述>"}`（呼叫當下不是 `.recording`——例如還在 `selecting`／`armed`／`finishing`。**這種情況不會呼叫 `cancelIfActive()`**：若真的呼叫，`selecting`／`armed` 下會被解讀成取消並發出 `recordingAborted`，那不是 `stopRecord` 的語意，呼叫端明確表達的是「結束並保留母帶」，不該在還沒開始錄製時被誤當成取消） |
| `abortRecord` | 無 | `{ok: <是否真的不在 active 狀態了>, state:"<RecordSession.state 的字串描述>"}` | `.finishing` 狀態不接受取消（刻意保留的紀律，見 `docs/animated-capture.md` §4），這時 `ok` 會是 `false`，`state` 仍是 `"finishing"`——不能因為呼叫成功就假設母帶已經被丟棄 |
| `micDevices` | 無 | `{ok:true, devices:[{uniqueID,name,isDefault}], systemDefaultID:"<uniqueID>"或null}`（`AudioInputDeviceList.all()` 的直接映射；`systemDefaultID` 罕見情況可能是 `null`——見 `AudioInputDeviceList.systemDefaultID()` 對聚合裝置的邊界說明） | — |
| `micProbeStart` | `deviceID`（可省略／空字串＝系統預設輸入） | `{ok:true, authorized:<Bool>}`——`authorized` 是**當下**的麥克風授權狀態（`AVCaptureDevice.authorizationStatus`）；`false` 時 `MicLevelMonitor.start()` 靜默不啟動任何 session（不 crash），之後 `micLevel` 會恆回 0，呼叫端要靠這個欄位分辨「已啟動只是還沒收到聲音」與「根本沒有授權」 | — |
| `micLevel` | 無 | `{ok:true, level:<Float 0..1>}`（RPC 專用 `MicLevelMonitor` 的 `latestLevel`，未 `micProbeStart` 或已 `micProbeStop` 時恆為 0） | — |
| `micProbeStop` | 無 | `{ok:true}` | — |
| 其他未知命令 | — | — | `{ok:false, error:"unknownCommand:<cmd>"}` |

`rect` 字串範例：`"100,140,260,160"`（四段皆須是合法數字，否則整體判定 `badRect`）。

**`startRecord` 觸發的錄影不限時**，只會被 `stopRecord`／`abortRecord`／10 分鐘上限看門狗結束——
不會沿用 HUD 秒數欄殘留的設定（`RecordSession.startProgrammatically` 明確把 `durationLimit`
壓成 `nil` 並重新 arm 看門狗，見 `docs/animated-capture.md`）。同時 HUD 上會短暫顯示「🤖 遠端
自動化錄影」提示（3 秒自動消失），讓實機操作者知道這段錄製是被自動化觸發，不是使用者自己按的。

**`micProbeStart`/`micLevel`/`micProbeStop` 用的是 `AppDelegate` 自己另外持有的一個
`MicLevelMonitor` 實例**，與設定頁「截圖」分頁裡 `CaptureSettingsViewController` 自己的那個
`MicLevelMonitor` 是**兩個獨立物件**（取簡，見 `AppDelegate.micProbeMonitor` 的註解）。
`MicLevelMonitor` 沒有 singleton 防同裝置多 session——若設定頁同時開著、且勾了同一顆裝置，
會有兩條 `AVCaptureSession` 各自對同一顆麥克風起 `AVCaptureDeviceInput`；實測（2026-08-13，
兩者同時對 DaiLing G3 起 session）沒有 crash，兩邊各自拿到自己的樣本流。正常自動化情境設定頁
通常沒開，這個重疊窗口很少發生。

---

## 3. 事件

`UITestServer.emit(name:payload:)` 把事件寫進 `/tmp/anypaint-uitest-events.jsonl`（append，一行
一個 JSON 物件，含 `seq`／`event`／payload 展開的其他鍵）。動畫截圖目前會發三種：

| 事件 | payload | 發送時機 |
|---|---|---|
| `recordingStarted` | `{}` | `RecordSession` 真正開始錄製（`RecordFrameSource.start` 的 await 已經回來，stream 已起）——不是「使用者按下開始鈕」那一刻，兩者中間有一段 async 空窗 |
| `recordingStopped` | `{outputURL: "<path>"}` | 正常停止（手動鈕／倒數到／看門狗／stream error 五條路徑共用）且收檔成功 |
| `recordingAborted` | `{}` | 取消（Esc／取消鈕／`abortRecord` 命令），母帶被丟棄 |
| `recordingFailed` | `{reason: "<字串>"}` | 三條失敗路徑各自發一次：`startFailed: <error>`（`RecordFrameSource.start` 的 await 拋錯，例如 TCC 拒絕、`noDisplays`）、`finishFailed: <error>`（`stopAndFinish()` 失敗，包含 `RecordError.noFrames`／`.writerFailed`）、`finishingTimeout`（`.finishing` 的 30 秒看門狗放生——`stopAndFinish()` 鏈路卡死時的最後防線）。三者都與對應的 `onFinished?(nil, …)` 回呼同一次失敗綁在一起，不是額外的獨立事件流 |

`channelReady`（`{}`）在伺服器註冊完成時發一次，可用來確認 app 已經準備好接收命令（比起輪詢
`getState` 直到成功，等這個事件更直接）。

---

## 4. `anypaintctl` CLI

`anypaintctl` 是這個 RPC 的命令列包裝，不用自己拼 JSON 送 `CFMessagePort`。

```bash
anypaintctl <cmd> [--json '{...}']
anypaintctl wait-event <name> [--after N] [--timeout S]
```

- **命令別名**：`UITestServer` 的命令名是駝峰（`getState`／`dumpUI`／`screenshotSelf`），CLI
  額外接受 kebab-case／全小寫（`get-state`／`getstate` 皆可），其餘命令名原樣透傳（`startRecord`
  等動畫截圖命令目前沒有別名，要打對大小寫）。
- **`--json`**：額外參數以 JSON 物件合併進請求（例如 `startRecord` 的 `rect`）：
  `anypaintctl startRecord --json '{"rect":"100,140,260,160"}'`。
- **`wait-event <name>`**：輪詢事件 log（200ms 間隔），找到 `seq > --after`（預設 0）且
  `event == name` 的第一行就印出並成功結束；`--timeout`（預設 30 秒）內找不到就失敗退出。
  `--after` 通常填上前一個命令回應裡的 `seq`（**所有**回應都帶這個欄位，見 §1）當基準，避免撈到
  舊事件——但記得 `seq` 只在事件真正發出時前進（見 §1），連續呼叫但中間沒有新事件的命令會拿到
  相同的 `seq`，拿它當 `--after` 基準本身沒問題（`wait-event` 找的是嚴格大於）。
- **exit code**：一般命令看回應的 `"ok"`（`true`→0，`false`或連不上→1）；`wait-event` 找到就 0，
  逾時就 1。

範例：程式化開始一段錄製、等它真的開始、停止、等收檔完成：

```bash
anypaintctl getstate   # 記下目前 seq（假設是 3）
anypaintctl startRecord --json '{"rect":"100,140,400,300"}'
anypaintctl wait-event recordingStarted --after 3 --timeout 10
sleep 2
anypaintctl stopRecord
anypaintctl wait-event recordingStopped --after 3 --timeout 15
```

範例：列出麥克風裝置、對指定裝置起試音錶、輪詢電平：

```bash
anypaintctl micDevices                                            # 找出想測的 uniqueID
anypaintctl micProbeStart --json '{"deviceID":"BuiltInMicrophoneDevice"}'
anypaintctl micLevel                                              # {"ok":true,"level":0.0xx}
anypaintctl micProbeStop
```

