#!/usr/bin/env bash
# anypaint 開發選單：把常用指令包成互動選單。用法：bash scripts/menu.sh
# 相容 macOS 內建 bash 3.2；含 CJK 的字串一律 ${VAR} 大括號界定（避免多位元組解析崩潰）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
APP_NAME="anypaint"
DEV_APP="${ROOT}/build.noindex/${APP_NAME}.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"

pause() { printf "\n（按 Enter 回選單）"; read -r _; }

build_and_open() {
    echo "==> 關閉執行中實例並建置（release）"
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
    # 用 release 不用 debug：滾動截圖的影像匹配在 -Onone 下慢約 50 倍（實測單格 1.7 秒 vs 20ms），
    # debug build 的滾動截圖無法正常拼接。編譯錯誤迭代可直接用 swift build。
    if "${ROOT}/scripts/build_app.sh" release; then
        open "${DEV_APP}" && echo "已開啟 ${DEV_APP}"
    else
        echo "建置失敗，未開啟。" >&2
    fi
}

install_app() {
    echo "==> 執行 install.sh（release，裝到 /Applications）"
    bash "${ROOT}/scripts/install.sh"
}

run_selftest() {
    echo "==> 自我測試"
    local n
    n="$(swift run anypaint-selftest 2>&1 | grep -c "^✅")"
    echo "通過 ${n} 項（綠勾數）"
}

kill_all() {
    echo "==> 關閉所有 ${APP_NAME} 實例"
    pkill -x "${APP_NAME}" 2>/dev/null && echo "已送出關閉。" || echo "沒有執行中的實例。"
}

clean_build() {
    echo "==> 清理建置產物"
    rm -rf "${ROOT}/build.noindex" "${ROOT}/.build"
    echo "已刪除 build.noindex/ 與 .build/。"
}

make_cert() {
    echo "==> 建立持久簽章身分（需 homebrew OpenSSL 3.x）"
    bash "${ROOT}/scripts/make_signing_cert.sh"
}

# 滾動截圖自檢：自己開一個會動的視窗、真實擷取、跑完整匹配鏈，全自動驗證管線。
scroll_selfcheck() {
    echo "==> 建置 release 並執行滾動截圖自檢"
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
    "${ROOT}/scripts/build_app.sh" release >/dev/null || { echo "建置失敗" >&2; return 1; }
    rm -f /tmp/anypaint-selfcheck.log
    # 必須用 open（走 launchd）而非直接跑 binary：從終端直跑會讓 TCC 把螢幕錄製責任歸給終端機。
    open -a "${DEV_APP}" --args --scroll-selfcheck
    echo "自檢執行中（約 10 秒）…"
    sleep 13
    echo "----------------"
    cat /tmp/anypaint-selfcheck.log 2>/dev/null || echo "沒有產生 log（可能是螢幕錄製權限未授予）"
    echo "----------------"
    pkill -x "${APP_NAME}" 2>/dev/null || true
}

uninstall_app() {
    if [ -d "${INSTALLED_APP}" ]; then
        echo "==> 從 /Applications 移除 ${APP_NAME}"
        pkill -x "${APP_NAME}" 2>/dev/null || true
        sleep 1
        rm -rf "${INSTALLED_APP}" && echo "已移除 ${INSTALLED_APP}"
    else
        echo "${INSTALLED_APP} 不存在，無需移除。"
    fi
}

while true; do
    cat <<MENU

======== anypaint 開發選單 ========
  1) 建置並開啟 dev app（release）
  2) 安裝到 /Applications（release，正式）
  3) 執行自我測試（selftest）
  4) 關閉所有執行中實例
  5) 清理建置產物（build.noindex/、.build/）
  6) 建立持久簽章身分（避免權限每次重置）
  7) 從 /Applications 移除 anypaint
  8) 滾動截圖自檢（自動，不需互動）
  0) 離開
===================================
MENU
    printf "選擇："
    read -r choice || break
    case "${choice}" in
        1) build_and_open; pause ;;
        2) install_app; pause ;;
        3) run_selftest; pause ;;
        4) kill_all; pause ;;
        5) clean_build; pause ;;
        6) make_cert; pause ;;
        7) uninstall_app; pause ;;
        8) scroll_selfcheck; pause ;;
        0|q|Q) echo "掰。"; break ;;
        *) echo "無效選項：${choice}" ;;
    esac
done
