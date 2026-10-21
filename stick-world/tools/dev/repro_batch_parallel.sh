#!/usr/bin/env bash
# unit(batch) 并行轮转复现台 v2：同 worktree 内自并行 N 个 batch_runner 实例，
# 错峰启动（模拟多会话真实形态，避开同毫秒冷启动的相变态），逐实例捕获
# stdout/stderr/trace（SW_BATCH_TRACE 实时进度），汇总 [BATCH-FAIL] 集。
# 用法: repro_batch_parallel.sh [并行数=3] [轮数=3] [输出根目录=/tmp/wf_repro] [错峰秒=8]
set -u
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
N="${1:-3}"
ROUNDS="${2:-3}"
OUT="${3:-/tmp/wf_repro}"
STAGGER="${4:-8}"
# 脚本位于 stick-world/tools/dev/，工程根 = 上两级（--path 少一级会指向 tools/——
# 那目录没有 project.godot，Godot 4.7 会带着 StringName BUG 报错原地挂死，谨防再踩）
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT"
# SW_BATCH_TRACE 由 Windows 原生 Godot 写：必须给 Windows 形态路径（cygpath -m），MSYS /tmp 形态它写不了
trace_win() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || echo "$1"; }

for r in $(seq 1 "$ROUNDS"); do
	rd="$OUT/round$r"
	rm -rf "$rd"; mkdir -p "$rd"
	echo "=== ROUND $r: 并行 $N 实例（错峰 ${STAGGER}s）$(date +%T) ==="
	# 外源干扰快照：本轮起始时机器上的全部 godot 进程（排除/佐证外源负载）
	ps -W | grep -i "godot.windows" | awk '{print "  [ext-snapshot]", $1, $4, $7}' || true
	t0=$(date +%s%3N)
	pids=()
	for i in $(seq 1 "$N"); do
		( SW_BATCH_TRACE="$(trace_win "$rd/inst$i.trace")" \
		  "$GODOT" --headless --path "$PROJECT" res://tests/batch_runner.tscn \
			>"$rd/inst$i.out" 2>"$rd/inst$i.err" </dev/null; echo $? >"$rd/inst$i.res" ) &
		pids+=($!)
		[ "$i" -lt "$N" ] && sleep "$STAGGER"
	done
	for p in "${pids[@]}"; do wait "$p"; done
	t1=$(date +%s%3N)
	echo "round $r 用时 $(( (t1-t0)/1000 ))s"
	for i in $(seq 1 "$N"); do
		code=$(cat "$rd/inst$i.res" 2>/dev/null || echo NA)
		summary=$(grep -a "批量汇总" "$rd/inst$i.out" | tail -1)
		nfail=$(grep -ac "BATCH-FAIL" "$rd/inst$i.out" || true)
		echo "  [inst$i] exit=$code fails=$nfail | $summary"
		grep -a "BATCH-FAIL" "$rd/inst$i.out" | sed 's/^/      /'
	done
done
echo "=== 复现数据在 $OUT ==="
