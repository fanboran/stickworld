#!/usr/bin/env bash
# 门禁一体化（工位三件套之二）——一次跑完五段：静态审计 → import 自检 → 改动面编译 → 变更测试 → 报错扫描。
# 静态审计段（audit_deps + file_size_ratchet）：纯文本扫描不启 Godot，秒级，
#   依赖环/越界与文件行数棘轮在最先暴露——结构性违规不必等编译测试跑完。
# 改动面编译段（批0 教训⑤：fx 并损=常量丢失属编译期错，测试才炸不如编译先炸）：
#   diff 出改动/新增的 .gd 逐个 --check-only 编译，红一个即停。
# 用法（任意目录均可）：
#   tools/dev/gate.sh                     # 默认：-Changed HEAD（工作区改动）
#   tools/dev/gate.sh HEAD~1              # 指定对比基线（如提交后验证上一笔）
#   tools/dev/gate.sh --full              # 全量测试（慢，收线用；编译段仍按 HEAD 工作区）
#   tools/dev/gate.sh --skip-import       # 跳过 import（未动资源时省时）
# 退出码 0=全绿；任何一段失败即停并给出定位提示。各段耗时单独计时。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
GATE_START="$(date +%s)"
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

step "静态审计（依赖审计 + 行数棘轮，纯文本扫描不启 Godot）"
# 两脚本均按自身 __file__ 定位工程根，与 cwd 无关；仓库根 tools/ 在 stick-world/ 上层
python "$PROJ_ROOT/../tools/audit_deps.py" || fail "依赖审计有红线（新增环/越界超基线）"
python "$PROJ_ROOT/../tools/file_size_ratchet.py" || fail "行数棘轮有红线（新超线文件/在册文件增行）"
echo "   ok (${SECONDS}s)"

if [ "$DO_IMPORT" -eq 1 ]; then
	step "import 自检（--headless --import）"
	"$GODOT" --headless --path . --import > /dev/null 2>&1 || fail "import 失败"
	echo "   ok (${SECONDS}s)"
fi

step "改动面编译自检（运行时上下文 load）"
# 注：不能用 --check-only（不解析 autoload 标识符，引用 EventBus 等的脚本全假红），
# 改用 compile_check.tscn 在完整启动链里 load 每个改动脚本（见其脚本头注释）。
mapfile -t CHANGED_GD < <(git diff --name-only --diff-filter=ACMR "$REF" -- '*.gd' 2>/dev/null; git ls-files --others --exclude-standard -- '*.gd' 2>/dev/null)
if [ "${#CHANGED_GD[@]}" -eq 0 ]; then
	echo "   无 .gd 改动，跳过"
else
	# 仓库根在 stick-world/ 上层时 diff 路径带 stick-world/ 前缀，去掉映射回 res://
	RES_ARGS=()
	for f in "${CHANGED_GD[@]}"; do
		RES_ARGS+=("res://${f#stick-world/}")
	done
	"$GODOT" --headless --path . res://tools/dev/compile_check.tscn -- "${RES_ARGS[@]}" \
		> /tmp/gate_compile.log 2>&1
	if [ $? -ne 0 ]; then
		grep -E "compile_check|SCRIPT ERROR|Parse Error" /tmp/gate_compile.log | head -30 >&2
		fail "编译失败（明细见上）"
	fi
	echo "   ok（${#CHANGED_GD[@]} 个 .gd，${SECONDS}s）"
fi

step "测试（$([ $FULL -eq 1 ] && echo 全量 || echo "-Changed $REF")）"
# 日志隔离：user://logs 按项目名跨 worktree 共享且轮转保留——不挪走旧日志，
# 报错扫描段会数到历史会话（含修复前）的错误。归档到子目录，只扫本门禁新日志。
LOG_DIR="$APPDATA/Godot/app_userdata/$(sed -n 's/^config\/name="\(.*\)"/\1/p' project.godot | head -n1)/logs"
if [ -d "$LOG_DIR" ] && ls "$LOG_DIR"/godot*.log >/dev/null 2>&1; then
	ARCH="$LOG_DIR/archive_gate_$(date +%Y%m%d_%H%M%S)"
	mkdir -p "$ARCH"
	mv "$LOG_DIR"/godot*.log "$ARCH"/ 2>/dev/null
fi
if [ "$FULL" -eq 1 ]; then
	bash tests/run_all.sh || fail "测试有失败"
else
	bash tests/run_all.sh -Changed "$REF" || fail "测试有失败（改到的套件红）"
fi
echo "   ok (${SECONDS}s)"

step "报错扫描（user:// 日志，仅本 gate 窗口）"
# -Since：多会话并行共用 user://logs（按项目名跨 worktree 共享），只扫本 gate
# 启动后新建/更新的日志，防并行会话（旧分支/旧 worktree）的报错打红本仓门禁。
bash tools/check_godot_errors.sh -Since "$GATE_START" > /dev/null 2>&1 || fail "运行时报错非零"
echo "   ok (${SECONDS}s)"

echo "[gate] ✓ 全绿（静态审计 + import + 编译 + tests + errors）"
