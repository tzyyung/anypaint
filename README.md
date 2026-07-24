# anypaint

一個 macOS 原生的螢幕截圖 + 貼圖工具，仿 Snipaste 的核心功能。用 Swift + AppKit + ScreenCaptureKit，以 Swift Package Manager 建置（不需 Xcode）。內部代號與識別碼仍為 `anypaint`。

## 功能
- 全域快鍵：截圖（預設 `⌘⇧A`）、貼圖（預設 `⌘⇧V`），可在 設定 → 控制 重新錄製。
- 框選截圖：8 控制點縮放、框內拖曳、框外重畫、即時尺寸；標註（矩形／橢圓／直線／箭頭／畫筆／螢光筆／馬賽克／文字／序號、色盤與粗細、undo/redo、選取與層次調整）；多條退出與看門狗自動取消。
- 貼圖：把剪貼簿影像變成置頂浮動視窗——拖曳、滾輪縮放、⌘+滾輪透明度、雙按關閉、中鍵重設、⇧+右鍵 OCR 複製文字；選單列「關閉所有貼圖」。
- 輸出：檔名樣板（日期 token／變數）、手動另存／快速儲存／自動儲存、儲存通知。

## 安裝（給使用者）

**系統需求：** macOS 14（Sonoma）以上。

### 步驟 0：安裝 Command Line Tools
本專案用 Swift 建置，需要 Apple 的命令列開發工具（不需完整 Xcode）。

```bash
xcode-select --install
```
會跳出系統對話框安裝（約數百 MB）。驗證：

```bash
xcode-select -p        # 應印出工具路徑
swift --version        # 需顯示 Swift 6.0 以上
```
若 Swift 版本過舊：到「系統設定 → 一般 → 軟體更新」更新系統，或安裝 Xcode 16+。

### 步驟 1–3
```bash
git clone <本 repo URL>
cd anypaint
bash scripts/install.sh
```
安裝腳本會自建並把「anypaint.app」放進 `/Applications`（不可寫時放 `~/Applications`）。裝好後：

1. 開啟後**沒有 Dock 圖示與視窗**——看「選單列右上角」的剪刀圖示。
2. 首次按截圖快鍵（`⌘⇧A`）時，macOS 會要求螢幕錄製權限：**系統設定 → 隱私權與安全性 → 螢幕錄製 → 允許「anypaint」**。
3. **授權後必須 `⌘Q` 完全結束再重新開啟**才會生效（僅切開關或再按快鍵不會生效）。

### 常見問題
- **授權後仍黑屏／擷取空白**：把螢幕錄製權限開關關掉再開，並 `⌘Q` 重啟。
- **開機自動啟動**：設定 → 一般 → 勾「登入時自動啟動」。
- **快鍵衝突**：設定 → 控制 → 重新錄製。

## 使用
- 截圖 `⌘⇧A`：拖曳框選 → 可調整/標註 → 按「複製」（或 `Enter`）複製到剪貼簿；工具列另有 存檔/另存/貼上。
- 貼圖 `⌘⇧V`：把剪貼簿影像貼成置頂浮動圖。滾輪縮放、`⌘`+滾輪調透明度、左鍵雙按關閉、`⇧`+雙按切換縮圖、中鍵重設、`⇧`+右鍵 OCR 取字。
- 設定分四頁：一般（開機啟動）／截圖（看門狗）／輸出（檔名樣板與儲存）／控制（快鍵改鍵＋滑鼠一覽）。
- 檔名樣板語法：`$…$` 日期 token（如 `$yyyy-MM-dd HH.mm.ss$`）、`%…%` 變數；詳見設定頁「命名規則」視窗。

## 開發
```bash
swift build                       # 建置
swift run anypaint                # 直接跑
swift run anypaint-selftest       # 純邏輯自我測試
./scripts/build_app.sh release    # 組 .app bundle 並簽章（產出 build.noindex/anypaint.app）
```

架構：`Sources/AnypaintKit/`（核心模組）、`Sources/anypaint/`（進入點）、`Sources/anypaint-selftest/`（測試執行檔）。KeyboardShortcuts 為本機 vendored（`vendored/KeyboardShortcuts`，patch 過資源查找）。設計文件見 `docs/superpowers/specs/`。

### 選用：持久簽章身分（給會反覆 rebuild 的開發者）
ad-hoc 簽章每次 build 識別會變，導致 TCC 螢幕錄製權限每次重置。建立持久自簽身分可讓授權跨重建保留。

**前置需求：** homebrew 的 OpenSSL 3.x（`brew install openssl`；系統內建 LibreSSL 不支援腳本所需的 `-legacy`）。

```bash
./scripts/make_signing_cert.sh    # 建一次即可，之後 build_app.sh 自動偵測使用
```
只想安裝使用的人**不需要**這步——ad-hoc 一次性安裝即可正常授權。

## 環境
macOS 14+、Swift 6.0+（開發於 macOS 26、Swift 6.3、Command Line Tools 無完整 Xcode）。
