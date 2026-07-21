#!/usr/bin/env bash
# 把 SwiftPM 執行檔組裝成 macOS .app bundle 並簽章。
# 用法：scripts/build_app.sh [debug|release]   （預設 debug）
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="anypaint"
BUNDLE_ID="com.aidaris.anypaint"
APP_DIR="$ROOT/$APP_NAME.app"
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
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

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
