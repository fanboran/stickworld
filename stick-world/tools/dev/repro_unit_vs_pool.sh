#!/usr/bin/env bash
# unit(batch) 复现台 v3：模拟创始人真实形态——unit 批跑 + 3 个重集成套件并行池
# 同 worktree 内自并行（共享 .godot 与 user://），等价于多会话 run_all 交叠。
# 用法: repro_unit_vs_pool.sh [轮数=3] [输出根=/tmp/wf_repro5]
set -u
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
ROUNDS="${1:-3}"
OUT="${2:-/tmp/wf_repro5}"
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trace_win() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || echo "$1"; }
# 重集成三件套（run_all 里超时预算最大的三个：GameRoot boot + 换图 + 存读档链）
PEERS=(
	"res://tests/integration/test_save_completeness.tscn"
	"res://tests/integration/test_battle_lifecycle.tscn"
	"res://tests/integration/test_anim_finished.tscn"
)
mkdir -p "$OUT"
for r in $(seq 1 "$ROUNDS"); do
	rd="$OUT/round$r"; rm -rf "$rd"; mkdir -p "$rd"
	echo "=== ROUND $r: unit批 + 3集成并行 $(date +%T) ==="
	# 先起 3 个集成对等体（错峰 2s），再起 unit 批
	pids=()
	for i in 1 2 3; do
		( "$GODOT" --headless --path "$PROJECT" "${PEERS[$((i-1))]}" -- --fresh-start \
			>"$rd/peer$i.out" 2>"$rd/peer$i.err" </dev/null; echo $? >"$rd/peer$i.res" ) &
		pids+=($!)
		sleep 2
	done
	( SW_BATCH_TRACE="$(trace_win "$rd/unit.trace")" \
	  "$GODOT" --headless --path "$PROJECT" res://tests/batch_runner.tscn \
		>"$rd/unit.out" 2>"$rd/unit.err" </dev/null; echo $? >"$rd/unit.res" ) &
	pids+=($!)
	for p in "${pids[@]}"; do wait "$p"; done
	code=$(cat "$rd/unit.res"); summary=$(grep -a "批量汇总" "$rd/unit.out" | tail -1)
	nfail=$(grep -ac "BATCH-FAIL" "$rd/unit.out" || true)
	echo "  [unit] exit=$code fails=$nfail | $summary"
	grep -a "BATCH-FAIL" "$rd/unit.out" | sed 's/^/      /'
	grep -a "LOAD-FAIL\|TIMEOUT" "$rd/unit.trace" 2>/dev/null | sed 's/^/      trace: /'
	for i in 1 2 3; do
		echo "  [peer$i] exit=$(cat "$rd/peer$i.res" 2>/dev/null) $(grep -a 测试汇总 "$rd/peer$i.out" | tail -1 | head -c 60)"
	done
done
echo "=== 复现数据在 $OUT ==="
