#!/usr/bin/env bash
# 观察场镜像通道指标跑批（战场观感重构批1门禁）——带窗口跑观察场并采样
# 挥砍可见率/滑步比/命中-Hit 帧偏差，JSON 归集 temp/战场指标/<时间戳>/ 并打印
# Windows 绝对路径。用法（stick-world/ 或任意目录均可）：
#   tools/dev/arena_metrics.sh               # 预设1（标准48），采样 30s
#   tools/dev/arena_metrics.sh 0 45          # 预设0，采样 45s
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
PRESET="${1:-1}"; SECS="${2:-30}"
USER_METRICS="$APPDATA/Godot/app_userdata/火柴人帝国模拟/metrics"
OUT_BASE="$(git -C "$PROJ_ROOT" rev-parse --show-toplevel)/temp/战场指标"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OUT_BASE/${STAMP}_p${PRESET}"
mkdir -p "$OUT_DIR"
rm -f "$USER_METRICS"/metrics_*.json 2>/dev/null
# 带窗口跑（指标采样走渲染帧，与镜像 feed 同拍）
"$GODOT" --path "$PROJ_ROOT" res://tools/dev/arena_shot_boot.tscn --resolution 1920x1080 -- \
	--preset "$PRESET" --secs "$SECS" --every 10 --metrics || true
cp "$USER_METRICS"/metrics_*.json "$OUT_DIR/" 2>/dev/null
COUNT=$(ls "$OUT_DIR" 2>/dev/null | wc -l)
if [ "$COUNT" -eq 0 ]; then
	echo "[arena_metrics] 失败：无指标产出" >&2
	exit 1
fi
WIN_DIR="$(cygpath -w "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"
echo "[arena_metrics] JSON → $WIN_DIR"
