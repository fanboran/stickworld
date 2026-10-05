#!/usr/bin/env bash
# 观察场快照跑批（工位三件套之一）——headless 跑大乱斗观察场并按间隔截图，
# 产物自动归集进本 worktree 的 temp/观察场快照/<时间戳>/ 并打印完整绝对路径。
# 用法（stick-world/ 或任意目录均可）：
#   tools/dev/arena_shot.sh                    # 预设1（标准48），20s，每5s一屏
#   tools/dev/arena_shot.sh 0 12 3             # 预设0，12s，每3s一屏
#   tools/dev/arena_shot.sh 2 60 10 mytag      # 预设2，60s，每10s，前缀 mytag
# 截图源 = user://shots/（ArenaWorkbench 前缀），归集后清源防串场。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
PRESET="${1:-1}"; SECS="${2:-20}"; EVERY="${3:-5}"; TAG="${4:-workbench}"
USER_SHOTS="$APPDATA/Godot/app_userdata/火柴人帝国模拟/shots"
OUT_BASE="$(git -C "$PROJ_ROOT" rev-parse --show-toplevel)/temp/观察场快照"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OUT_BASE/${STAMP}_p${PRESET}"
mkdir -p "$OUT_DIR"
rm -f "$USER_SHOTS"/"${TAG}"_p*.png 2>/dev/null
# 注意：带窗口跑（不 --headless）——headless 渲染服务器无 viewport 纹理可采
# （库内 diag_arena_shots 同口径"必须带显示"；截图走真实渲染帧）。
"$GODOT" --path "$PROJ_ROOT" res://tools/dev/arena_shot_boot.tscn --resolution 1920x1080 -- \
	--preset "$PRESET" --secs "$SECS" --every "$EVERY" --tag "$TAG" || true
cp "$USER_SHOTS"/"${TAG}"_p*.png "$OUT_DIR/" 2>/dev/null
rm -f "$USER_SHOTS"/"${TAG}"_p*.png 2>/dev/null
COUNT=$(ls "$OUT_DIR" 2>/dev/null | wc -l)
if [ "$COUNT" -eq 0 ]; then
	echo "[arena_shot] 失败：无截图产出（先查 GPU/headless 渲染可用性）" >&2
	exit 1
fi
# cygwin/msys 路径转 Windows 绝对路径（创始人可直接粘贴进资源管理器）
WIN_DIR="$(cygpath -w "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"
echo "[arena_shot] $COUNT 张 → $WIN_DIR"
