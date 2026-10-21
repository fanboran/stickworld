#!/usr/bin/env bash
# probe_world_smap.sh —— PerfProbe 运行时探针·战略图 L1/L2/L3 逐帧成本差分
#
# 协议（docs/项目/待办/战略图性能下一档.md 成文协议）：
#   临时 autoload + 文件命令通道 + 每秒 CSV + sysoff 差分。
#   本脚本是可复跑封装：注入/还原 autoload、通道隔离（config/name 临时加
#   -perf 后缀 → user:// 独立目录，并行多实例互不抢答）、驱动测量相位、
#   收集 CSV/resp 到 temp/perf/。
#
# 用法：
#   bash tools/perf/probe_world_smap.sh [相位采样秒数，默认 8]
#
# 测量相位（每相 mark 后采样 N 秒，CSV 每秒一行）：
#   world_base       世界基线（三层地图常驻隐藏 + Tab 缩略窗默认展开态）
#   l1_resident_off  sysoff 战略图 L1 子树差分（常驻隐藏时的闲置 _process 成本）
#   l3_resident_off  sysoff L3 子树差分（含常驻 L2 装配的显隐账分开测）
#   l2_resident_off  sysoff L2 子树差分
#   l1_open / l3_open / l2_open  三层大图全开态（经 EventBus 层级请求，生产行为）
#
# 读数：同机同分钟内 world_base 与各差分相的 proc_ms/phys_ms/fps 之差
# （规范：docs/技术/规范/性能量测规范.md §铁律 5/6——以 CSV mark 行为准）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STICK_WORLD="$(cd "$HERE/../.." && pwd)"
GODOT="${GODOT_BIN:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
PHASE_SECS="${1:-8}"
BATCH_STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$STICK_WORLD/temp/perf"
PROJ="$STICK_WORLD/project.godot"
PROJ_BAK="$OUT_DIR/project.godot.probe.bak"
# 通道名带 PID 唯一化：user:// 目录按 config/name 隔离——并发跑两个 probe
# 或测期间另起本工程 godot 实例（读同一份被注入的 project.godot）都不会
# 抢同一通道（2026-10-22 首跑实锤：battle 冒烟与 probe 同通道互抢指令）
PROBE_NAME="火柴人帝国模拟-probe$$"
APPDATA_DIR="${APPDATA:-$(cd "$USERPROFILE/AppData/Roaming" 2>/dev/null && pwd && cd - >/dev/null)}/Godot/app_userdata/$PROBE_NAME"
CHAN_DIR="$APPDATA_DIR/perf"

mkdir -p "$OUT_DIR"
rm -rf "$CHAN_DIR"; mkdir -p "$CHAN_DIR"
# 测量期独占纪律：本工程的 godot 实例共享被注入的 config/name，测量期间
# 禁止从本 worktree 另起任何 godot（battle_perf/编辑器模拟等），否则指令互抢。

restore() {
  if [[ -f "$PROJ_BAK" ]]; then mv -f "$PROJ_BAK" "$PROJ"; fi
}
cleanup_kill() {
  if [[ -n "${GAME_PID:-}" ]] && kill -0 "$GAME_PID" 2>/dev/null; then
    echo "[probe] 发 quit 收尾"
    send_cmd "quit" >/dev/null 2>&1 || true
    sleep 3
    kill -0 "$GAME_PID" 2>/dev/null && kill -9 "$GAME_PID" 2>/dev/null || true
  fi
}
on_exit() { cleanup_kill; restore; }
trap on_exit EXIT

# ── 临时注入：PerfProbe autoload + 通道隔离名（测完还原）──
cp "$PROJ" "$PROJ_BAK"
if ! grep -q 'PerfProbe=' "$PROJ"; then
  python - "$PROJ" <<'EOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace('[autoload]\n\n', '[autoload]\n\nPerfProbe="*res://tests/dev/perf_probe.gd"\n', 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
EOF
fi
python - "$PROJ" "$PROBE_NAME" <<'EOF'
import io, sys
p, name = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8").read()
import re
s = re.sub(r'config/name="[^"]*"', 'config/name="%s"' % name, s, count=1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
EOF

echo "[probe] 通道目录: $CHAN_DIR"
echo "[probe] 环境负载: $(tasklist //FI "IMAGENAME eq godot.windows.opt.tools.64.exe" 2>/dev/null | grep -c "godot" || true) 个 godot 进程在跑（含本批启动前存量）"

# ── 启动世界场景（真渲染 + Dummy 音频 + 固定分辨率 + 后置底不抢焦点）──
STICK_DEV_QUIET=1 "$GODOT" --path "$STICK_WORLD" --resolution 1920x1080 \
    --audio-driver Dummy res://tests/dev/world_perf.tscn -- "--hold=200" \
    > "$OUT_DIR/probe_console_$BATCH_STAMP.log" 2>&1 &
GAME_PID=$!

send_cmd() {  # send_cmd <命令行> —— 先快照行数再写命令（回应不可能早于命令，
  #            快照晚了会把回应算进 before，等一个不会来的增长＝假超时）
  local cmd="$1"; local deadline=$((SECONDS + 20))
  local before=0
  [[ -f "$CHAN_DIR/resp.txt" ]] && before=$(wc -l < "$CHAN_DIR/resp.txt")
  printf '%s\n' "$cmd" > "$CHAN_DIR/cmd.txt"
  while (( SECONDS < deadline )); do
    if [[ -f "$CHAN_DIR/resp.txt" ]] && (( $(wc -l < "$CHAN_DIR/resp.txt") > before )); then
      tail -n $(( $(wc -l < "$CHAN_DIR/resp.txt") - before )) "$CHAN_DIR/resp.txt" | sed 's/^/    <- /'
      return 0
    fi
    sleep 0.25
  done
  echo "    !! 命令超时无回应: $cmd" >&2
  return 1
}

phase() {  # phase <mark名> —— 打 mark 并采样 PHASE_SECS 秒
  echo "[probe] 相位 $1（${PHASE_SECS}s）"
  send_cmd "mark $1" >/dev/null
  sleep "$PHASE_SECS"
}

# ── 等启动（CSV 出现 = PerfProbe 在跑；世界装配含战略图分帧步骤，给足 40s）──
echo "[probe] 等待世界装配（PerfProbe CSV 出现 + ping 通）..."
deadline=$((SECONDS + 60))
until [[ -n "$(ls "$CHAN_DIR"/audit_*.csv 2>/dev/null)" ]] || (( SECONDS >= deadline )); do
  kill -0 "$GAME_PID" 2>/dev/null || { echo "[probe] 游戏进程早退，看控制台日志"; exit 1; }
  sleep 1
done
sleep 30   # 世界热身（world_perf 自身 warmup 10s + 步骤表分帧装配余量）
PING_RESP="$(send_cmd "ping")" || { echo "[probe] ping 失败"; exit 1; }
# 通道归属校验：pong 必须报本探针场景——另一实例抢通道时立即中止（数据不可信）
if ! grep -q "world_perf.tscn" <<<"$PING_RESP"; then
  echo "[probe] 通道被其他实例占用（pong: $PING_RESP）——中止，勿在测量期从本 worktree 起其他 godot"
  exit 1
fi

# ── 测量相位序列 ──
phase "world_base"

echo "[probe] sysoff L1（常驻闲置差分）"; send_cmd "sysoff /root/GameRootPerf/StrategicMap" >/dev/null
phase "l1_resident_off"; send_cmd "syson /root/GameRootPerf/StrategicMap" >/dev/null

echo "[probe] sysoff L3（常驻闲置差分）"; send_cmd "sysoff /root/GameRootPerf/StrategicMapL3" >/dev/null
phase "l3_resident_off"; send_cmd "syson /root/GameRootPerf/StrategicMapL3" >/dev/null

echo "[probe] sysoff L2（常驻闲置差分）"; send_cmd "sysoff /root/GameRootPerf/StrategicMapL2" >/dev/null
phase "l2_resident_off"; send_cmd "syson /root/GameRootPerf/StrategicMapL2" >/dev/null

echo "[probe] 开 L1 大图（生产行为：EventBus 层级请求）"
send_cmd "call /root/EventBus emit_signal strategic_map_level_requested L1" >/dev/null
phase "l1_open"
send_cmd "call /root/GameRootPerf/StrategicMap/Content close" >/dev/null; sleep 2

echo "[probe] 开 L3 大世界"
send_cmd "call /root/EventBus emit_signal strategic_map_level_requested L3" >/dev/null
phase "l3_open"
send_cmd "call /root/GameRootPerf/StrategicMapL3/Content close" >/dev/null; sleep 2

echo "[probe] 开 L2（当前 L1 所属地区视图）"
send_cmd "call /root/EventBus emit_signal strategic_map_level_requested L2" >/dev/null
phase "l2_open"
send_cmd "call /root/GameRootPerf/StrategicMapL3/Content close" >/dev/null; sleep 2

send_cmd "stat" >/dev/null || true
# 收尾由 EXIT trap 统一处理（quit 游戏进程 + 还原 project.godot）

# ── 收集产物 ──
cp "$CHAN_DIR"/audit_*.csv "$OUT_DIR/smap_runtime_$BATCH_STAMP.csv" 2>/dev/null || true
[[ -f "$CHAN_DIR/resp.txt" ]] && cp "$CHAN_DIR/resp.txt" "$OUT_DIR/smap_runtime_resp_$BATCH_STAMP.txt"
echo
echo "[probe] 完成。CSV: $OUT_DIR/smap_runtime_$BATCH_STAMP.csv"
echo "[probe] 按相中位速览（proc_ms/phys_ms/draws，n=秒数）："
awk -F, 'NR>1 {
  mark=$2; proc[mark]=proc[mark]+$7; phys[mark]=phys[mark]+$8; dr[mark]=dr[mark]+$9;
  fps[mark]=fps[mark]+$3; fms[mark]=fms[mark]+$4; n[mark]++
  if ($8+0>pmx[mark]) pmx[mark]=$8+0
}
END {
  printf "  %-18s %7s %8s %8s %8s %7s\n", "mark", "n", "fps", "proc_ms", "phys_ms", "draws"
  for (m in n) printf "  %-18s %7d %8.1f %8.2f %8.2f %7.0f\n", m, n[m], fps[m]/n[m], proc[m]/n[m], phys[m]/n[m], dr[m]/n[m]
}' "$OUT_DIR/smap_runtime_$BATCH_STAMP.csv" | sort -k1
