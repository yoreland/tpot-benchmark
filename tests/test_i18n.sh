#!/usr/bin/env bash
# =============================================================================
# i18n 库测试套件（issue #9）— 纯 bash，无需 bats，零外部副作用
# =============================================================================
# 验证 scripts/lib/i18n.sh 的语言解析顺序、英文回退、--lang 开关与帮助渲染。
# 该套件在 lib 不存在时必然失败（source 报错），lib 到位后全部通过。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/i18n.sh"
RUN_BENCH="$REPO_ROOT/scripts/run-benchmark.sh"

PASS=0
FAIL=0

ok() {
    if [[ "$1" == "$2" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $3"
        echo "        expected: [$2]"
        echo "        actual:   [$1]"
    fi
}

contains() {
    if [[ "$1" == *"$2"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $3"
        echo "        [$1] does not contain [$2]"
    fi
}

echo "== i18n 库测试 =="

# ---- 前置：lib 必须存在（这正是回归锚点：改动前不存在 -> source 失败 -> 退出 1）
if [[ ! -f "$LIB" ]]; then
    echo "  FAIL: 找不到 i18n 库 scripts/lib/i18n.sh —— 功能尚未实现"
    exit 1
fi
# shellcheck source=../scripts/lib/i18n.sh
source "$LIB"

# ---- 1) 显式 --lang 优先，且能加载 zh
i18n_init "zh"
ok "$(i18n_lang)" "zh" "显式 --lang zh 解析为 zh"
ok "$(t verdict.pass)" "PASS" "zh 下 verdict.pass 为 PASS"
contains "$(t usage.opt.help)" "显示帮助信息" "zh 下帮助文案为中文"

# 保存/恢复语言相关环境，确保子用例在父 shell 内运行、断言能累计
_save_env() { _S_LANG="${LANG-__UNSET__}"; _S_LCALL="${LC_ALL-__UNSET__}"; _S_TPOT="${TPOT_LANG-__UNSET__}"; }
_restore_env() {
    [[ "$_S_LANG"  == "__UNSET__" ]] && unset LANG     || export LANG="$_S_LANG"
    [[ "$_S_LCALL" == "__UNSET__" ]] && unset LC_ALL   || export LC_ALL="$_S_LCALL"
    [[ "$_S_TPOT"  == "__UNSET__" ]] && unset TPOT_LANG || export TPOT_LANG="$_S_TPOT"
}

# ---- 2) 默认（无任何信号）回退英文
_save_env; unset LANG LC_ALL TPOT_LANG
i18n_init ""
ok "$(i18n_lang)" "en" "无语言信号时回退 en"
_restore_env

# ---- 3) 未知语言回退英文
i18n_init "jp"
ok "$(i18n_lang)" "en" "未知语言 jp 回退 en"

# ---- 4) TPOT_LANG 环境变量生效（低于 --lang，高于 LANG）
_save_env; export TPOT_LANG="zh" LANG="en_US.UTF-8"; unset LC_ALL
i18n_init ""
ok "$(i18n_lang)" "zh" "TPOT_LANG 覆盖 LANG"
_restore_env

# ---- 5) 显式 --lang 覆盖 TPOT_LANG
_save_env; export TPOT_LANG="zh"
i18n_init "en"
ok "$(i18n_lang)" "en" "--lang 覆盖 TPOT_LANG"
_restore_env

# ---- 6) LANG=zh_CN.UTF-8 规范化为 zh
_save_env; unset LC_ALL TPOT_LANG; export LANG="zh_CN.UTF-8"
i18n_init ""
ok "$(i18n_lang)" "zh" "LANG=zh_CN.UTF-8 规范化为 zh"
_restore_env

# ---- 7) %s 占位符展开
i18n_init "en"
ok "$(t usage.title "/path/to/x")" "Usage: /path/to/x [options]" "en 下 %s 展开"
i18n_init "zh"
ok "$(t usage.title "/path/to/x")" "用法: /path/to/x [选项]" "zh 下 %s 展开"

# ---- 8) 缺失 key：zh 缺某 key 时回退英文（人为造一个只在 en 的 key）
# 本仓库两个 locale key 集一致，这里直接验证完全不存在的 key 原样打印
i18n_init "zh"
ok "$(t this.key.does.not.exist)" "this.key.does.not.exist" "缺失 key 原样打印"

# ---- 9) en/zh 两个 locale 的 key 集必须完全一致（all-or-nothing sibling 契约）
EN_KEYS="$(jq -r 'to_entries[] | select(.key|startswith("_meta")|not) | .key' "$REPO_ROOT/locales/en.json" | sort)"
ZH_KEYS="$(jq -r 'to_entries[] | select(.key|startswith("_meta")|not) | .key' "$REPO_ROOT/locales/zh.json" | sort)"
ok "$ZH_KEYS" "$EN_KEYS" "en 与 zh 的 key 集完全一致"

# ---- 10) 端到端：run-benchmark.sh --lang en --help 输出英文 usage
if [[ -x "$RUN_BENCH" || -f "$RUN_BENCH" ]]; then
    HELP_EN="$(bash "$RUN_BENCH" --lang en --help 2>&1 || true)"
    contains "$HELP_EN" "Usage:" "run-benchmark.sh --lang en --help 为英文"
    contains "$HELP_EN" "--lang LANG" "帮助列出 --lang 选项"
    HELP_ZH="$(bash "$RUN_BENCH" --lang zh --help 2>&1 || true)"
    contains "$HELP_ZH" "用法:" "run-benchmark.sh --lang zh --help 为中文"
fi

echo ""
echo "== 汇总：通过 $PASS，失败 $FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
