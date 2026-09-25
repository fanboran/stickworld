#!/usr/bin/env bash
# L1 视图包全量重烤（Wg-3b）：69 批量包 + 1 出生包（v2 出生点 = l1_049 / settlement_city_427）。
# 前置：city_split_v3 + refine_city_labels + export_l3_l1_view 已跑（output/l1_v2 新代）。
set -e
PY="C:\Users\fanbo\AppData\Local\Programs\Python\Python312\python.exe"
cd "$(dirname "$0")/../../.."   # 仓库根（tools/worldgen/l1 → 根）

# 69 批量包（margin 45 默认，与旧代窗口一致）
for i in $(seq 1 69); do
  n=$(printf "%03d" "$i")
  echo "=== l1_$n ==="
  "$PY" tools/worldgen/l1/export_l1_view_context.py --start-l1 "$i" \
    --out-dir "stick-world/config/strategic_map/l1_packs/l1_$n" || echo "!! l1_$n FAILED"
done

# 出生包（margin 30 与旧出生包同窗风格；v2 出生点 = 关洋湾都城 settlement_city_427）
echo "=== spawn (l1_049 / settlement_city_427) ==="
"$PY" tools/worldgen/l1/export_l1_view_context.py --start-l1 49 --margin 30 \
  --spawn-settlement settlement_city_427
echo "ALL DONE"
