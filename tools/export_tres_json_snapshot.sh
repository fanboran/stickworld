#!/usr/bin/env bash
# 数值 .tres → JSON 快照单向导出（工位工具包装器）
#
# GDScript 本体 tools/export_tres_json_snapshot.gd 在 res:// 之外（不进工程、
# 不产生 .uid、不污染导出），而 Godot 的 -s 只认项目内相对路径，必须传绝对
# 路径执行——本包装器负责定位仓库根与 Godot、拼出绝对路径并透传参数。
#
# 用法（在仓库根或任意目录均可）：
#   tools/export_tres_json_snapshot.sh             # 全量导出/刷新快照
#   tools/export_tres_json_snapshot.sh --check     # 门禁：比对重算结果与盘上快照，漂移退出码 1
#   GODOT="/path/to/godot" tools/export_tres_json_snapshot.sh   # 自定义 Godot
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Godot 原生程序使用 Windows 风格路径（MSYS 的 /f/... 不保证被转换），同 run_all.sh 口径
if command -v cygpath >/dev/null 2>&1; then
	ROOT="$(cygpath -m "$ROOT")"
fi
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"

exec "$GODOT" --headless --path "$ROOT/stick-world" -s "$ROOT/tools/export_tres_json_snapshot.gd" -- "$@"
