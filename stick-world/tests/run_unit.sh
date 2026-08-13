#!/usr/bin/env bash
# 单元测试快速入口 —— 一个进程跑完全部 unit 层（纯逻辑），目标 <30s。
# 用法：
#   tests/run_unit.sh                     # 使用默认 Godot 路径
#   GODOT="/path/to/godot.exe" tests/run_unit.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"

"$GODOT" --headless --path "$PROJECT_DIR" res://tests/batch_runner.tscn
exit $?
