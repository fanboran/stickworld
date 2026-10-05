#!/usr/bin/env bash
# 门禁一体化（工位三件套之二）——一次跑完三段：import 自检 → 变更测试 → 报错扫描。
# 用法（任意目录均可）：
#   tools/dev/gate.sh                     # 默认：-Changed HEAD（工作区改动）
#   tools/dev/gate.sh HEAD~1              # 指定对比基线（如提交后验证上一笔）
#   tools/dev/gate.sh --full              # 全量测试（慢，收线用）
#   tools/dev/gate.sh --skip-import       # 跳过 import（未动资源时省时）
# 退出码 0=全绿；任何一段失败即停并给出定位提示。各段耗时单独计时。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
REF="HEAD"; FULL=0; DO_IMPORT=1
for a in "$@"; do
	case "$a" in
		--full) FULL=1 ;;
		--skip-import) DO_IMPORT=0 ;;
		*) REF="$a" ;;
	esac
done
cd "$PROJ_ROOT"
fail() { echo "[gate] ✗ $1（耗时见上）" >&2; exit 1; }
step() { SECONDS=0; echo "── [gate] $1"; }

if [ "$DO_IMPORT" -eq 1 ]; then
	step "import 自检（--headless --import）"
	"$GODOT" --headless --path . --import > /dev/null 2>&1 || fail "import 失败"
	echo "   ok (${SECONDS}s)"
fi

step "测试（$([ $FULL -eq 1 ] && echo 全量 || echo "-Changed $REF")）"
if [ "$FULL" -eq 1 ]; then
	bash tests/run_all.sh || fail "测试有失败"
else
	bash tests/run_all.sh -Changed "$REF" || fail "测试有失败（改到的套件红）"
fi
echo "   ok (${SECONDS}s)"

step "报错扫描（user:// 日志）"
bash tools/check_godot_errors.sh > /dev/null 2>&1 || fail "运行时报错非零"
echo "   ok (${SECONDS}s)"

echo "[gate] ✓ 全绿（import + tests + errors）"
