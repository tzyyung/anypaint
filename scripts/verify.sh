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

echo; [ "$FAIL" -eq 0 ] && echo "== 總結: PASS ==" || echo "== 總結: FAIL =="
exit $FAIL
