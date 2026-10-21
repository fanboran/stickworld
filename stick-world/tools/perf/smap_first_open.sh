#!/usr/bin/env bash
# smap_first_open.sh —— 战略图 L1/L2/L3 首开分相基准·多进程中位跑批
#
# 用法（在 stick-world/ 或仓库任意处均可，脚本自定位）：
#   bash tools/perf/smap_first_open.sh [进程轮数，默认 5]
#
# 做什么：
#   1. 逐轮拉起独立 godot 进程跑 res://tests/dev/perf_bench_smap.tscn
#      （轮内 rounds=1，只取冷值——热值由进程内 --rounds 自测，不在此重复）；
#   2. 各轮 CSV 追加到 temp/perf/smap_first_open.csv（gitignored）；
#   3. 汇总本轮批次的冷值中位表（并行会话负载下以中位为准）。
# 规范：docs/技术/规范/性能量测规范.md（headless、无音频、通道按 config/name 隔离）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STICK_WORLD="$(cd "$HERE/../.." && pwd)"
GODOT="${GODOT_BIN:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
ROUNDS="${1:-5}"
CSV="$STICK_WORLD/temp/perf/smap_first_open.csv"
BATCH_STAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$STICK_WORLD/temp/perf"
# 本批从干净 CSV 起步（历史数据按 stamp 列可区分，但中位聚合只算本批）
rm -f "$CSV"

echo "[smap-first-open] godot=$(basename "$GODOT") 进程轮数=$ROUNDS 环境负载:$(tasklist //FI "IMAGENAME eq godot.windows.opt.tools.64.exe" 2>/dev/null | grep -c "godot" || true) 个 godot 进程在跑"

for i in $(seq 1 "$ROUNDS"); do
  echo "--- 进程轮 $i/$ROUNDS ---"
  "$GODOT" --headless --path "$STICK_WORLD" res://tests/dev/perf_bench_smap.tscn \
      -- --rounds=1 --csv=res://temp/perf/smap_first_open.csv 2>&1 | grep -E "^R0" || true
done

echo
echo "[smap-first-open] 本批（$BATCH_STAMP）冷值中位汇总："
awk -F, 'NR>1 && $3=="1" {key=$4"."$5; vals[key]=vals[key]" "$6; n[key]++}
END {
  for (k in vals) {
    m=split(vals[k], arr, " ")
    # 插入排序取中位
    for (a=2; a<=m; a++) { v=arr[a]; for (b=a-1; b>=1 && arr[b]+0>v+0; b--) arr[b+1]=arr[b]; arr[b+1]=v }
    med=(m%2==1)?arr[int(m/2)+1]:(arr[m/2]+arr[m/2+1])/2
    printf "  %-22s 中位 %8.2f ms（n=%d）\n", k, med, m
  }
}' "$CSV" | sort
echo "[smap-first-open] 明细 CSV: $CSV"
