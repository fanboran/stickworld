#!/usr/bin/env bash
# 观察场渲染性能跑批（S2 渲染直渲 A/B 工位）——带窗口跑观察场并采样
# 帧时分位/draw calls/显存/烘焙计数，控制台即出数（JSON 仅记路线元信息）。
# A/B 用法：
#   tools/dev/arena_renderperf.sh 1 30           # 预设1（标准48），30s，当前默认路线
#   STICK_CHAR_RENDER=direct tools/dev/arena_renderperf.sh 1 30   # 直渲路线
#   tools/dev/arena_renderperf.sh 2 30           # 预设2（极端压力96）
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
PRESET="${1:-1}"; SECS="${2:-30}"; EVERY="${3:-10}"; TAG="${4:-perf}"
USER_OUT="$APPDATA/Godot/app_userdata/火柴人帝国模拟/renderperf"
OUT_BASE="$(git -C "$PROJ_ROOT" rev-parse --show-toplevel)/temp/渲染性能"
STAMP="$(date +%Y%m%d_%H%M%S)"
ROUTE="${STICK_CHAR_RENDER:-bake}"
OUT_DIR="$OUT_BASE/${STAMP}_p${PRESET}_${ROUTE}"
mkdir -p "$OUT_DIR"
rm -f "$USER_OUT"/renderperf_*.json 2>/dev/null
# 带窗口跑（性能口径走真实渲染帧）
"$GODOT" --path "$PROJ_ROOT" res://tools/dev/arena_shot_boot.tscn --resolution 1920x1080 -- \
	--preset "$PRESET" --secs "$SECS" --every "$EVERY" --renderperf --tag "$TAG" 2>&1 | tee "$OUT_DIR/console.log" || true
cp "$USER_OUT"/renderperf_*.json "$OUT_DIR/" 2>/dev/null
WIN_DIR="$(cygpath -w "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"
echo "[arena_renderperf] 产物 → $WIN_DIR"
