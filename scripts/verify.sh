#!/bin/bash
# 一鍵驗證：L1 selftest → build app → L2 實機自檢 → 彙總。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

echo "== L1: selftest =="
OUT=$(cd "$ROOT" && swift run -c release anypaint-selftest 2>&1)
PASS_N=$(echo "$OUT" | grep -c "^✅"); FAIL_N=$(echo "$OUT" | grep -c "^❌")
echo "   ✅ $PASS_N  ❌ $FAIL_N"
[ "$FAIL_N" -eq 0 ] || { echo "$OUT" | grep "^❌"; FAIL=1; }

echo "== build app (release) =="
"$ROOT/scripts/build_app.sh" release >/dev/null || FAIL=1

echo "== L2: 錄影自檢 =="
pkill -f "anypaint.app" 2>/dev/null || true
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
pkill -f "anypaint.app" 2>/dev/null || true

echo; [ "$FAIL" -eq 0 ] && echo "== 總結: PASS ==" || echo "== 總結: FAIL =="
exit $FAIL
