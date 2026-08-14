#!/usr/bin/env bash
# Godot 报错检查（bash 版，替代原 check_godot_errors.ps1）。
# 两个来源：
#   1. 运行日志扫描：user://logs（godot.log + 轮转 godot<时间戳>.log）
#   2. 编辑器启动模拟（默认开）：删 .godot/editor/filesystem_cache10 强制全量重扫，
#      再跑 `godot --headless --editor --quit` 复现编辑器启动错误
#      （BOM tscn / GDExtension 加载失败 / 插件 @tool 错误等）。约 15s。
# 用法：
#   tools/check_godot_errors.sh           # 全量（日志扫描 + 启动模拟）
#   tools/check_godot_errors.sh -Quick    # 仅日志扫描
#   tools/check_godot_errors.sh -Warnings # 含 WARNING
# 退出码：1 有错误，0 干净。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Godot 原生程序使用 Windows 风格路径（MSYS 的 /f/... 不保证被转换）
PROJECT_DIR_WIN="$PROJECT_DIR"
if command -v cygpath >/dev/null 2>&1; then
	PROJECT_DIR_WIN="$(cygpath -m "$PROJECT_DIR")"
fi
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
# Windows Git Bash 下 %APPDATA%/%TEMP% 是反斜杠路径，需用 cygpath 归一化
LOG_ROOT="${APPDATA:-$HOME/AppData/Roaming}"
TMP_BASE="${TMPDIR:-$TEMP}"
if command -v cygpath >/dev/null 2>&1; then
	LOG_ROOT="$(cygpath -u "$LOG_ROOT" 2>/dev/null || echo "$LOG_ROOT")"
	TMP_BASE="$(cygpath -u "$TMP_BASE" 2>/dev/null || echo "$TMP_BASE")"
fi
LOG_DIR="$LOG_ROOT/Godot/app_userdata/stick_world/logs"
MAX_FILES=10
WARNINGS=0
QUICK=0

while [ $# -gt 0 ]; do
	case "$1" in
		-Warnings) WARNINGS=1; shift ;;
		-Quick) QUICK=1; shift ;;
		*) echo "未知参数: $1"; exit 2 ;;
	esac
done

PATTERNS=("ERROR" "SCRIPT ERROR" "Parse Error" "Invalid call" "Invalid access" "Cannot open" "Cannot load" "Cannot find" "Cannot instantiate" "Cannot create" "Cannot parse")
[ "$WARNINGS" -eq 1 ] && PATTERNS+=("WARNING")

total_errors=0

match_pattern() {
	local line="$1" p
	for p in "${PATTERNS[@]}"; do
		case "$line" in
			*"$p"*) return 0 ;;
		esac
	done
	return 1
}

count_as_error() {
	local line="$1"
	case "$line" in
		*"WARNING"*) return 1 ;;
		*) return 0 ;;
	esac
}

# ───────────────────────────── 1. 日志扫描 ─────────────────────────────
if [ -d "$LOG_DIR" ]; then
	oldest=""
	# 按修改时间取最近 MAX_FILES 个日志
	while IFS= read -r f; do
		hits=""
		while IFS= read -r line; do
			if match_pattern "$line"; then hits="$hits$line
"; fi
		done <"$f"
		if [ -n "$hits" ]; then
			n=$(printf '%s' "$hits" | grep -c .)
			echo ""
			echo "== [log] $(basename "$f") ($n hits) =="
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				if count_as_error "$line"; then total_errors=$((total_errors + 1)); fi
				echo "  $line"
			done <<<"$hits"
		fi
	done < <(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -n "$MAX_FILES")
else
	echo "[check] 无日志目录: $LOG_DIR"
fi

# ───────────────────── 2. 编辑器启动模拟 ─────────────────────
if [ "$QUICK" -eq 0 ]; then
	echo ""
	echo "== 编辑器启动模拟（删 filesystem_cache10 + --editor --quit）=="
	cache_path="$PROJECT_DIR/.godot/editor/filesystem_cache10"
	[ -e "$cache_path" ] && rm -rf "$cache_path"
	boot_log="$TMP_BASE/sw_boot_check.log"
	boot_err="$TMP_BASE/sw_boot_check_err.log"
	rm -f "$boot_log" "$boot_err"
	"$GODOT" --headless --editor --quit --path "$PROJECT_DIR_WIN" >"$boot_log" 2>"$boot_err" &
	pid=$!
	( sleep 300; kill -9 "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
	killer=$!
	wait "$pid" 2>/dev/null
	code=$?
	kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
	if [[ "$code" =~ ^[0-9]+$ ]] && [ "$code" -ge 137 ]; then
		echo "  [boot] TIMEOUT"
		exit 1
	fi
	hits=""
	while IFS= read -r line; do
		match_pattern "$line" && hits="$hits$line
"
	done < <(cat "$boot_log" "$boot_err" 2>/dev/null)
	if [ -n "$hits" ]; then
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			count_as_error "$line" && total_errors=$((total_errors + 1))
			echo "  $line"
		done <<<"$hits"
	else
		echo "  [boot] clean（无错误行）"
	fi
fi

echo ""
if [ "$total_errors" -gt 0 ]; then
	echo "=== 发现 $total_errors 个错误 ==="
	exit 1
fi
echo "=== 日志干净：无 ERROR / SCRIPT ERROR / Parse Error ==="
exit 0
