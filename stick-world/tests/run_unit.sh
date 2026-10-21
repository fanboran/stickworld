#!/usr/bin/env bash
# 单元测试快速入口 —— 一个进程跑完全部 unit 层（纯逻辑），目标 <30s。
# 用法：
#   tests/run_unit.sh                     # 使用默认 Godot 路径
#   GODOT="/path/to/godot.exe" tests/run_unit.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Godot 原生程序使用 Windows 风格路径（MSYS 的 /f/... 不保证被转换）
PROJECT_DIR_WIN="$PROJECT_DIR"
if command -v cygpath >/dev/null 2>&1; then
	PROJECT_DIR_WIN="$(cygpath -m "$PROJECT_DIR")"
fi
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"

# class_name 全局类缓存预检/自愈（脚本编译层守门，函数与根因档案见 tests/lib/class_cache_guard.sh）
source "$SCRIPT_DIR/lib/class_cache_guard.sh"
ensure_class_cache "$GODOT"

"$GODOT" --headless --path "$PROJECT_DIR_WIN" res://tests/batch_runner.tscn
exit $?
