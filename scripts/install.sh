#!/usr/bin/env bash
# 任截圖 一鍵安裝：檢查環境 → build → 裝到 /Applications → 引導螢幕錄製權限。
# 端使用者路徑用 ad-hoc 簽章，不依賴 homebrew／OpenSSL。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DISPLAY_NAME="任截圖"

echo "==> 檢查開發工具環境"
# 第一道閘用 xcode-select -p：乾淨機上 command -v swift/git 是 CLT shim（假陽性），
# 而 xcode-select -p 在無 toolchain 時只回非零、不彈系統框。
if ! xcode-select -p >/dev/null 2>&1; then
  echo "缺 Command Line Tools。請執行：xcode-select --install，裝好後重跑本腳本。" >&2
  exit 1
fi

# Swift 版本 ≥ 6.0（major/minor 各自轉整數比，不可字串比大小）
SWIFT_VER="$(swift --version 2>/dev/null | grep -oE 'version [0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
if [[ -z "$SWIFT_VER" ]]; then
  echo "無法取得 Swift 版本；請確認 Command Line Tools 已正確安裝。" >&2
  exit 1
fi
SWIFT_MAJOR="${SWIFT_VER%%.*}"
SWIFT_MINOR="${SWIFT_VER#*.}"
if (( SWIFT_MAJOR < 6 )); then
  echo "需要 Swift 6.0 以上（目前 $SWIFT_VER）。請更新 Command Line Tools 或安裝 Xcode 16+。" >&2
  exit 1
fi

# macOS ≥ 14
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 14 )); then
  echo "需要 macOS 14（Sonoma）以上（目前 $(sw_vers -productVersion)）。" >&2
  exit 1
fi

echo "==> 建置（首次需連網下載相依）"
if ! ./scripts/build_app.sh release; then
  echo "" >&2
  echo "建置失敗。若為首次建置：需連網下載相依（KeyboardShortcuts）；" >&2
  echo "離線或公司 proxy 環境請先設定 git proxy 或改用可連外網路後重試。" >&2
  exit 1
fi

echo "==> 安裝 $DISPLAY_NAME.app"
if [[ -w /Applications ]]; then
  DST="/Applications"
else
  DST="$HOME/Applications"
  mkdir -p "$DST"
  echo "   （/Applications 不可寫，改裝到 $DST）"
fi
pkill -x anypaint 2>/dev/null || true
sleep 1
rm -rf "$DST/$DISPLAY_NAME.app"
cp -R "$ROOT/$DISPLAY_NAME.app" "$DST/"

echo ""
echo "✅ 已安裝到 $DST/$DISPLAY_NAME.app"
echo ""
echo "下一步："
echo "  1. 開啟：open \"$DST/$DISPLAY_NAME.app\""
echo "  2. 本 app 無 Dock 圖示與視窗——啟動後看「選單列右上角」的剪刀圖示。"
echo "  3. 首次按截圖快鍵（預設 ⌘⇧A）時，macOS 會要求螢幕錄製權限："
echo "     系統設定 → 隱私權與安全性 → 螢幕錄製 → 允許「${DISPLAY_NAME}」。"
echo "     ★ 授權後必須 ⌘Q 完全結束 $DISPLAY_NAME 再重新開啟才會生效。"
echo "  4. 貼圖快鍵預設 ⌘⇧V；兩者都可在 設定 → 控制 重新錄製。"
