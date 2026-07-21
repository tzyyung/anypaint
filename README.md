# anypaint

一個 macOS 原生的螢幕截圖 + 貼圖（pin）工具，仿 Snipaste 的靈魂功能。用 Swift + AppKit + ScreenCaptureKit，以 Swift Package Manager 建置（不需 Xcode）。

## 功能（MVP）
- 全域快鍵：截圖（預設 `⌘⇧A`）、貼圖（預設 `⌘⇧V`）——**可在選單列「設定…」重新錄製**（用 KeyboardShortcuts 套件，底層仍是 Carbon，免輔助使用權限）
- 框選截圖（先凍結全螢幕 → 拖曳框 → **可調整**）：8 個控制點縮放、框內拖曳移動、框外重畫；旁邊工具列顯示即時尺寸，按「**擷取**」（或 Enter）才完成 → 複製到剪貼簿
  - 多條退出：`Esc`、右鍵、工具列「取消」、再按一次截圖快鍵；外加**看門狗**（無操作自動取消：預設 1 分鐘，觸發前 15 秒有倒數警告、逾時會先把目前框選內容存進剪貼簿再解除；設定頁可選 關閉/1/2/3/5/10 分鐘，任何操作都會重置它）
  - **標註**（框選後、擷取前）：矩形/橢圓/直線/箭頭，色盤 7 色＋粗細三檔（每工具各自記住），`⌘Z`/`⌘⇧Z` 復原重做；有標註時框鎖定（undo 清空解鎖）；擷取與看門狗搶救都會把標註合成進影像。文字（點擊輸入、單行、再點既有文字可重編輯、Esc/Enter 完成）與序號 ①②③（點擊生成、刪除自動重編號）已支援；畫筆/螢光筆/馬賽克/選取編輯為後續階段
- 貼圖：把剪貼簿影像變成**置頂浮動視窗**
  - 拖曳移動、捲動縮放、`[` / `]` 調透明度、`0` 還原、`c` 複製、`Esc` 關閉；右鍵選單
  - MVP **刻意不做穿透點擊**（避免鎖死風險）；選單列有「關閉所有貼圖」

## 建置與執行
```bash
# 純邏輯自我測試（座標翻轉等）
swift run anypaint-selftest

# 開發直接跑
swift run anypaint

# 組成 .app bundle 並簽章後啟動
./scripts/build_app.sh debug      # 或 release
open anypaint.app
```

首次截圖時 macOS 會要求**螢幕錄製權限**：系統設定 → 隱私權與安全性 → 螢幕錄製 → 允許 anypaint，然後再按一次 `⌘⇧A`。

### （選用）避免權限每次 build 重置
ad-hoc 簽章每次 build 的識別會變，導致螢幕錄製權限重置。建立一次持久簽章身分即可解決：
```bash
./scripts/make_signing_cert.sh   # 建立 self-signed 身分 anypaint-dev
```

## 架構
- `Sources/AnypaintKit/` — 核心模組（library）
  - `Hotkey/Shortcuts` — 全域快鍵定義（KeyboardShortcuts 套件，可改鍵）
  - `Settings/SettingsWindowController` — 快鍵設定頁
  - `Capture/ScreenCapturer` — ScreenCaptureKit 擷取
  - `Capture/SelectionOverlay` — 框選 overlay
  - `Pin/PinWindowController` — 貼圖浮動視窗
  - `Pasteboard/PinboardService` — 剪貼簿
  - `Geometry/CoordinateUtils` — 座標翻轉（純函式、有測試）
  - `MenuBar/MenuBarController`、`AppDelegate` — 選單列與協調
- `Sources/anypaint/` — app 進入點
- `Sources/anypaint-selftest/` — 純邏輯測試執行檔

設計文件見 `docs/superpowers/specs/2026-07-20-anypaint-design.md`。

## 環境
macOS 14+（開發於 macOS 26, arm64, Swift 6.3，Command Line Tools 無完整 Xcode）。
