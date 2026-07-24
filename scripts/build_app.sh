#!/usr/bin/env bash
# 把 SwiftPM 執行檔組裝成 macOS .app bundle 並簽章。
# 用法：scripts/build_app.sh [debug|release]   （預設 debug）
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="anypaint"           # 執行檔名／CFBundleExecutable／.app 檔名
BUNDLE_ID="com.aidaris.anypaint"
BUILD_DIR="$ROOT/build.noindex"   # 目錄名以 .noindex 結尾＝Spotlight 明確略過（避免 dev 產物與 /Applications 安裝版都被搜到）
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "找不到執行檔：$BIN_PATH" >&2
  exit 1
fi

echo "==> 組裝 $APP_NAME.app"
mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# 打包 SwiftPM 生成的資源 bundle（KeyboardShortcuts 的本地化）到 Contents/Resources。
# 放根目錄會被 codesign 拒（unsealed contents）；放 Contents/Resources 才 strict 過，
# 且 vendored patch 過的 .localized 正是從這裡找（見 vendored/KeyboardShortcuts）。
RES_BUNDLE="$(dirname "$BIN_PATH")/KeyboardShortcuts_KeyboardShortcuts.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$RES_DIR/"
else
  echo "警告：找不到資源 bundle $RES_BUNDLE —— recorder 本地化會退回英文（不影響運作）" >&2
fi

# 簽章：優先使用持久的 self-signed 身分（避免 TCC 螢幕錄製權限每次 build 重置）；
# 找不到就退回 ad-hoc（每次 build 需重新授權）。
SIGN_IDENTITY="anypaint-dev"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  echo "==> 以持久身分簽章：$SIGN_IDENTITY"
  codesign --force --deep \
    --entitlements "$ROOT/Resources/anypaint.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "==> 以 ad-hoc 簽章（提示：跑 scripts/make_signing_cert.sh 可建立持久身分，避免權限每次重置）"
  codesign --force --deep \
    --entitlements "$ROOT/Resources/anypaint.entitlements" \
    --sign - "$APP_DIR"
fi

echo "==> 完成：$APP_DIR"
echo "    啟動：open \"$APP_DIR\"   或   \"$MACOS_DIR/$APP_NAME\""
