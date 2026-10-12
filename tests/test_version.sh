#!/usr/bin/env bash
# =============================================================================
# --version / -V 回归测试（issue #11）— 纯 bash，无副作用
# =============================================================================
# 验证 scripts/run-benchmark.sh 的 --version 与 -V：退出码 0、输出单行且格式为
# `run-benchmark.sh X.Y.Z`，且 -V 与 --version 行为一致、--version 在其它参数在
# 场时仍短路退出。改动前（无该标志）这些断言必然失败。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_BENCH="$REPO_ROOT/scripts/run-benchmark.sh"

PASS=0
FAIL=0

ok() {
    if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1));
    else FAIL=$((FAIL + 1)); echo "  FAIL: $3"; echo "        expected: [$2]"; echo "        actual:   [$1]"; fi
}
matches() {
    if [[ "$1" =~ $2 ]]; then PASS=$((PASS + 1));
    else FAIL=$((FAIL + 1)); echo "  FAIL: $3"; echo "        [$1] does not match /$2/"; fi
}

echo "== --version / -V 测试 =="

# 格式：run-benchmark.sh 后跟语义化版本号
VERSION_RE='^run-benchmark\.sh [0-9]+\.[0-9]+\.[0-9]+$'

# ---- 1) --version 退出码 0
OUT="$(bash "$RUN_BENCH" --version 2>&1)"; RC=$?
ok "$RC" "0" "--version 退出码为 0"
matches "$OUT" "$VERSION_RE" "--version 输出格式为 'run-benchmark.sh X.Y.Z'"

# ---- 2) --version 输出恰好一行
LINES="$(printf '%s\n' "$OUT" | grep -c . )"
ok "$LINES" "1" "--version 输出恰好一行"

# ---- 3) -V 退出码 0 且与 --version 一致
OUT_V="$(bash "$RUN_BENCH" -V 2>&1)"; RC_V=$?
ok "$RC_V" "0" "-V 退出码为 0"
ok "$OUT_V" "$OUT" "-V 与 --version 输出一致"

# ---- 4) --version 在其它参数在场时仍短路退出 0
OUT_MIX="$(bash "$RUN_BENCH" --region us-east-1 --version 2>&1)"; RC_MIX=$?
ok "$RC_MIX" "0" "--version 混在其它参数中仍退出 0"
matches "$OUT_MIX" "$VERSION_RE" "--version 混用时输出仍为版本行"

# ---- 5) 版本号被 usage() 文档化（--help 列出 --version）
HELP="$(bash "$RUN_BENCH" --lang en --help 2>&1 || true)"
case "$HELP" in
    *"--version"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); echo "  FAIL: --help 未列出 --version" ;;
esac

echo ""
echo "== 汇总：通过 $PASS，失败 $FAIL =="
(( FAIL > 0 )) && exit 1
exit 0
