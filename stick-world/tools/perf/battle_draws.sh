#!/usr/bin/env bash
# battle_draws.sh —— 战斗 draw calls 回涨复核·多轮中位批跑
#
# 用法：
#   bash tools/perf/battle_draws.sh            # 全矩阵（48 基线×3 + 二分各×2，
#                                              #  96 基线×2 + 二分各×1，16 斜率点×2）
#   bash tools/perf/battle_draws.sh quick      # 快速档（48 基线×1 + 二分×1，96 基线×1）
#
# 组合：--preset 0/1/2（16v16/48v48/96v96）× base/--anim-off/--rig-hidden
#   --anim-off   冻结全部动画（2D RigHost + HD-2D JointRigHosts 隐藏求解画布）
#   --rig-hidden 隐藏全部单位视觉（2D rig + HD-2D char 宿主停写行+隐藏）
# 每跑热身 8s + 采样 20s 自动退出；draw_calls_median 为渲染管线精确统计
# （不受 CPU 负载噪声影响——fps 只作参考，跨分钟不可比，见量测规范）。
# 产物：temp/perf/battle_draws.csv + 控制台中位汇总。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STICK_WORLD="$(cd "$HERE/../.." && pwd)"
GODOT="${GODOT_BIN:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
MODE="${1:-full}"
OUT_DIR="$STICK_WORLD/temp/perf"
CSV="$OUT_DIR/battle_draws.csv"
BATCH_STAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT_DIR"
if grep -q "PerfProbe=" "$STICK_WORLD/project.godot"; then
  echo "[battle-draws] project.godot 还挂着 PerfProbe autoload（探针未还原）——先跑完/还原再跑本批" >&2
  exit 1
fi

# 组合矩阵：preset:mode:轮数
if [[ "$MODE" == "quick" ]]; then
  MATRIX=("1:base:1" "1:anim-off:1" "1:rig-hidden:1" "2:base:1")
else
  MATRIX=("1:base:3" "1:anim-off:2" "1:rig-hidden:2" "2:base:2" "2:anim-off:1" "2:rig-hidden:1" "0:base:2")
fi

echo "[battle-draws] 批 $BATCH_STAMP 矩阵 ${#MATRIX[@]} 组；环境负载:$(tasklist //FI "IMAGENAME eq godot.windows.opt.tools.64.exe" 2>/dev/null | grep -c "godot" || true) 个 godot 进程在跑"
[[ ! -f "$CSV" ]] && echo "stamp,preset,mode,run,fps_avg,draw_calls_median,worst_frame_ms,char_hosts,mmi3d,mi3d,line2d" > "$CSV"

for combo in "${MATRIX[@]}"; do
  IFS=: read -r preset mode runs <<<"$combo"
  for i in $(seq 1 "$runs"); do
    ARGS=(--path "$STICK_WORLD" --resolution 1920x1080 --audio-driver Dummy
          res://tests/dev/battle_perf.tscn -- "--preset=$preset")
    [[ "$mode" != "base" ]] && ARGS+=("--$mode")
    echo "--- preset=$preset mode=$mode run=$i ---"
    LINE="$(STICK_DEV_QUIET=1 "$GODOT" "${ARGS[@]}" 2>&1 | grep '^\[PERF\]' | tail -1)" || true
    if [[ -z "$LINE" ]]; then echo "  !! 无 [PERF] 输出"; continue; fi
    get() { sed -n "s/.*\"$1\": \([^,}]*\).*/\1/p" <<<"$LINE" | tail -1; }
    CENSUS_CH="$(grep -o '"char_rig_3d_hosts": [0-9]*' <<<"$LINE" | grep -o '[0-9]*$')"
    CENSUS_MM="$(grep -o '"MultiMeshInstance3D": [0-9]*' <<<"$LINE" | grep -o '[0-9]*$')"
    CENSUS_MI="$(grep -o '"MeshInstance3D": [0-9]*' <<<"$LINE" | grep -o '[0-9]*$')"
    CENSUS_L2="$(grep -o '"Line2D": [0-9]*' <<<"$LINE" | grep -o '[0-9]*$')"
    echo "  fps=$(get fps_avg) draws=$(get draw_calls_median) worst=$(get worst_frame_ms) hosts=${CENSUS_CH:-?} mmi=${CENSUS_MM:-?} mi=${CENSUS_MI:-?} line2d=${CENSUS_L2:-?}"
    echo "$BATCH_STAMP,$preset,$mode,$i,$(get fps_avg),$(get draw_calls_median),$(get worst_frame_ms),${CENSUS_CH:-},${CENSUS_MM:-},${CENSUS_MI:-},${CENSUS_L2:-}" >> "$CSV"
  done
done

echo
echo "[battle-draws] 本批（$BATCH_STAMP）中位汇总："
awk -F, 'NR>1 && $1=="'"$BATCH_STAMP"'" {key="P"$2"_"$3; d[key]=d[key]" "$6; f[key]=f[key]" "$5; n[key]++}
END {
  printf "  %-22s %10s %8s\n", "preset_mode", "draws_med", "fps_med"
  for (k in n) {
    m=split(d[k], a, " "); for (x=2;x<=m;x++){v=a[x];for(y=x-1;y>=1&&a[y]+0>v+0;y--)a[y+1]=a[y];a[y+1]=v}
    dm=(m%2==1)?a[int(m/2)+1]:(a[m/2]+a[m/2+1])/2
    m2=split(f[k], b, " "); for (x=2;x<=m2;x++){v=b[x];for(y=x-1;y>=1&&b[y]+0>v+0;y--)b[y+1]=b[y];b[y+1]=v}
    fm=(m2%2==1)?b[int(m2/2)+1]:(b[m2/2]+b[m2/2+1])/2
    printf "  %-22s %10.0f %8.1f  (n=%d)\n", k, dm, fm, m
  }
}' "$CSV" | sort
echo "[battle-draws] 明细 CSV: $CSV"
