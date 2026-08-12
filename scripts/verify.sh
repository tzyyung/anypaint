#!/bin/bash
# 一鍵驗證：L1 selftest → build app → L2 實機自檢 → 彙總。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

echo "== L1: selftest =="
OUT=$(cd "$ROOT" && swift run -c release anypaint-selftest 2>&1)
RUN_RC=$?
PASS_N=$(echo "$OUT" | grep -c "^✅"); FAIL_N=$(echo "$OUT" | grep -c "^❌")
echo "   exit=$RUN_RC ✅ $PASS_N  ❌ $FAIL_N"
# 三種失敗都要抓：❌>0（測試沒過）、exit!=0（編譯失敗或 swift run 本身 crash）、
# PASS_N=0（在印出任何✅之前就掛了——只看 FAIL_N 的話這種情況會被誤判成通過）。
if [ "$FAIL_N" -ne 0 ] || [ "$RUN_RC" -ne 0 ] || [ "$PASS_N" -eq 0 ]; then
    echo "$OUT" | grep "^❌"
    echo "$OUT" | tail -40
    FAIL=1
fi

echo "== build app (release) =="
"$ROOT/scripts/build_app.sh" release >/dev/null || FAIL=1

echo "== L2: 錄影自檢 =="
pkill -x anypaint 2>/dev/null || true
sleep 1
rm -f /tmp/anypaint-record-selfcheck.log
open -n "$ROOT/build.noindex/anypaint.app" --args --record-selfcheck
for _ in $(seq 1 60); do [ -f /tmp/anypaint-record-selfcheck.log ] && grep -q -- "----" /tmp/anypaint-record-selfcheck.log 2>/dev/null && break; sleep 1; done
# 判準：RecordSelfCheck 只在全部檢查跑完時寫「---- 全部通過 ----」；早退路徑（無主螢幕／
# stream 啟動失敗）與逐項失敗都不會出現這行，用它的有無當單一 PASS/FAIL 依據。
if [ -f /tmp/anypaint-record-selfcheck.log ] && grep -q "全部通過" /tmp/anypaint-record-selfcheck.log; then
    echo "   錄影自檢 PASS"
else
    echo "   錄影自檢 FAIL（或無 log——檢查螢幕錄製權限）"; cat /tmp/anypaint-record-selfcheck.log 2>/dev/null; FAIL=1
fi
pkill -x anypaint 2>/dev/null || true

echo "== L2: 音訊自檢 =="
pkill -x anypaint 2>/dev/null || true
sleep 1
rm -f /tmp/anypaint-audio-selfcheck.log
open -n "$ROOT/build.noindex/anypaint.app" --args --audio-selfcheck
for _ in $(seq 1 60); do [ -f /tmp/anypaint-audio-selfcheck.log ] && grep -q -- "----" /tmp/anypaint-audio-selfcheck.log 2>/dev/null && break; sleep 1; done
# 判準與錄影自檢同款邏輯：只在全部檢查跑完時才會寫「---- 全部通過 ----」。
# 音量鍵靜音不影響此自檢（實測：系統音量 0 時 SCK 仍撈得到全振幅系統聲，見
# docs/animated-capture.md §7「音訊」），因此不需要 osascript 調音量的兜底。
if [ -f /tmp/anypaint-audio-selfcheck.log ] && grep -q "全部通過" /tmp/anypaint-audio-selfcheck.log; then
    echo "   音訊自檢 PASS"
else
    echo "   音訊自檢 FAIL（或無 log——檢查螢幕錄製權限）"; cat /tmp/anypaint-audio-selfcheck.log 2>/dev/null; FAIL=1
fi
pkill -x anypaint 2>/dev/null || true

echo "== L2b: RPC 煙霧測試 =="
# 用上面「build app (release)」那次 swift build -c release 順帶產出的 anypaintctl，不再另外
# swift run（避免 swift run 觸發重編譯干擾這段時序）。
CTL="$ROOT/.build/release/anypaintctl"
pkill -x anypaint 2>/dev/null || true
sleep 1
rm -f /tmp/anypaint-uitest-events.jsonl
RPC_MP4=""
if [ ! -x "$CTL" ]; then
    # 含 CJK 的字串一律 ${VAR} 大括號界定（同 menu.sh 頭部註解——變數名直接接全形字元，
    # bash 在 set -u 下會把那個全形字元併進變數名解析，撞成 unbound variable）。
    echo "   RPC FAIL（找不到 ${CTL}，build app 那步是否成功？）"; FAIL=1
else
    open -n "$ROOT/build.noindex/anypaint.app" --args --uitest
    PORT_READY=0
    for _ in $(seq 1 30); do
        "$CTL" getState >/dev/null 2>&1 && { PORT_READY=1; break; }
        sleep 0.5
    done
    if [ "$PORT_READY" -ne 1 ]; then
        echo "   RPC FAIL（30 次輪詢後 port 仍未就緒——app 是否以 --uitest 啟動成功？）"; FAIL=1
    elif ! "$CTL" startRecord --json '{"rect":"100,100,400,300"}' | grep -q '"ok":true'; then
        echo "   RPC FAIL（startRecord 非 ok:true）"; FAIL=1
    elif ! "$CTL" wait-event recordingStarted --timeout 10 >/dev/null; then
        echo "   RPC FAIL（等不到 recordingStarted 事件）"; FAIL=1
    else
        sleep 2
        if ! "$CTL" stopRecord | grep -q '"ok":true'; then
            echo "   RPC FAIL（stopRecord 非 ok:true）"; FAIL=1
        else
            STOP_LINE="$("$CTL" wait-event recordingStopped --timeout 15)"
            # JSONSerialization 會把路徑裡的 "/" 跳成 "\/"（合法 JSON，但不是合法檔案路徑），
            # 擷取後要把跳脫還原，否則 [-f] 測不存在的字面值 "\/var\/..." 一律判假。
            RPC_MP4="$(echo "$STOP_LINE" | sed -E 's/.*"outputURL":"([^"]*)".*/\1/' | sed 's#\\/#/#g')"
            if [ -n "$RPC_MP4" ] && [ -f "$RPC_MP4" ]; then
                echo "   RPC PASS（mp4=${RPC_MP4}）"
            else
                echo "   RPC FAIL（收不到 recordingStopped 或輸出檔不存在：outputURL=${RPC_MP4}）"; FAIL=1
            fi
        fi
    fi
fi
[ -n "$RPC_MP4" ] && rm -f "$RPC_MP4"
pkill -x anypaint 2>/dev/null || true

echo; [ "$FAIL" -eq 0 ] && echo "== 總結: PASS ==" || echo "== 總結: FAIL =="
exit $FAIL
