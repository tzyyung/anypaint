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
  `"ok"`（`Bool`）與 `"seq"`（伺服器單調遞增計數器，每次 `handle` 呼叫都會加一，不論命令是否
  成功）。
- **啟動 app**：`open -n -a <bundle> --args --uitest`（`-n` 開獨立實例、`--args` 才會把參數傳給
  app 自己的授權身分——理由同 `CLAUDE.md` 的 `open -n --args` 教訓）；或把
  `AppSettings.allowLocalAutomation` 設成 true 讓正常啟動的 app 也開這個埠（給長駐 dev 實例用，
  不用每次重開）。
- **事件 log**：`/tmp/anypaint-uitest-events.jsonl`（JSON Lines，一行一個事件，見 §3）。
- **自拍截圖目錄**：`/tmp/anypaint-uitest-shots`（`screenshotSelf` 落地的 PNG，見 §2）。

---

## 2. 命令表

前三個是 `UITestServer` 內建、不需要 `AppDelegate` 接線就能用；後四個是動畫截圖專用，由
`AppDelegate.handleUITestCommand` 回應（`UITestServer.handle` 的 `default` 分支：先問
`commandHandler`，回 `nil` 才落回 `unknownCommand`）。

| 命令 | 參數 | 成功回應 | 失敗回應 |
|---|---|---|---|
| `getState` | 無 | `{ok:true, windows:[{title,frame,class}], eventLog:"/tmp/anypaint-uitest-events.jsonl"}`（`windows` 只列 `isVisible` 的視窗） | — |
| `dumpUI` | 無 | `{ok:true, tree:[{title,class,views:[...遞迴視圖樹...]}]}`（每個節點含 `class`／`frame`／`hidden`；`NSButton` 多帶 `title`／`enabled`，`NSTextField` 多帶 `text`） | — |
| `screenshotSelf` | 無 | `{ok:true, paths:["/tmp/anypaint-uitest-shots/winN-<epoch>.png", ...]}`（對每個可見視窗的 `contentView` 各存一張 PNG） | — |
| `openSettings` | 無 | `{ok:true}` | — |
| `startRecord` | `rect`: `"x,y,w,h"`（AppKit 全域座標，點，左下原點） | `{ok:true}`（跳過拉框互動，直接以此矩形進 armed 並開始錄製——`RecordSession.startProgrammatically`） | `{ok:false, error:"busy"}`（已有錄製在跑，不是 toggle）／`{ok:false, error:"badRect"}`（`rect` 解析失敗、或矩形超出螢幕邊界、或找不到目標螢幕）／`{ok:false, error:"selectionTooSmall"}`（矩形合法但邊長 < `RecordSession.minSelectionEdgePt`） |
| `stopRecord` | 無 | `{ok:true}`（正常停止，收檔保留——同熱鍵在 recording 狀態下再按一次） | — |
| `abortRecord` | 無 | `{ok: <是否真的不在 active 狀態了>, state:"<RecordSession.state 的字串描述>"}` | `.finishing` 狀態不接受取消（刻意保留的紀律，見 `docs/animated-capture.md` §4），這時 `ok` 會是 `false`，`state` 仍是 `"finishing"`——不能因為呼叫成功就假設母帶已經被丟棄 |
| 其他未知命令 | — | — | `{ok:false, error:"unknownCommand:<cmd>"}` |

`rect` 字串範例：`"100,140,260,160"`（四段皆須是合法數字，否則整體判定 `badRect`）。

---

## 3. 事件

`UITestServer.emit(name:payload:)` 把事件寫進 `/tmp/anypaint-uitest-events.jsonl`（append，一行
一個 JSON 物件，含 `seq`／`event`／payload 展開的其他鍵）。動畫截圖目前會發三種：

| 事件 | payload | 發送時機 |
|---|---|---|
| `recordingStarted` | `{}` | `RecordSession` 真正開始錄製（`RecordFrameSource.start` 的 await 已經回來，stream 已起）——不是「使用者按下開始鈕」那一刻，兩者中間有一段 async 空窗 |
| `recordingStopped` | `{outputURL: "<path>"}` | 正常停止（手動鈕／倒數到／看門狗／stream error 五條路徑共用）且收檔成功 |
| `recordingAborted` | `{}` | 取消（Esc／取消鈕／`abortRecord` 命令），母帶被丟棄 |

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
  `--after` 通常填上一次已知的 `seq`（例如 `startRecord` 回應裡沒有 seq，但可以先呼叫一次
  `getState` 記下當下的 `seq` 當基準），避免撈到舊事件。
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
