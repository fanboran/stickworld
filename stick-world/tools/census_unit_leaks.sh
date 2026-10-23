#!/usr/bin/env bash
# 逐套泄漏普查：每个套件单独起进程跑一遍（--verbose），统计退出时 ObjectDB 泄漏
# 实例数与 still-in-use 资源数，输出排序表。
# 用途：定位"退出泄漏统一 teardown"案的大头套件（2026-10 测试不稳定专项）。
#
# 用法：bash tools/census_unit_leaks.sh [输出tsv路径] [-Filter unit|integration|all]
#   - unit（默认）：.gd 套件经 tests/lib/unit_suite_main.gd 宿主逐套单进程跑；
#   - integration：.tscn 场景套件逐个 headless 跑（带 -- --fresh-start 防存档污染；
#     .tscn.suspended 悬置套件不匹配 *.tscn glob，天然跳过）；
#   - all：两层各出一份表（默认路径 /tmp/census_{unit,integration}_leaks.tsv）。
# 机制对齐：逐套独立进程 → --verbose 让 Godot 在退出时打 Leaked instance /
# Resource still in use 清单 → 按行计数。
set -u
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
cd "$(dirname "$0")/.." || exit 1

OUT=""
FILTER="unit"
TIMEOUT_UNIT=90
# integration 套件本身可跑到 ~60s（save_completeness/长战斗链），普查串行无争用，
# 180s 预算只用于拦截挂死（统一出口前 Parse Error 曾让进程不退）。
TIMEOUT_INTEGRATION=180
while [ $# -gt 0 ]; do
	case "$1" in
		-Filter) FILTER="$2"; shift 2 ;;
		-h|--help) sed -n '2,11p' "$0"; exit 0 ;;
		*) OUT="$1" ;;
	esac
	shift
done
case "$FILTER" in
	unit|integration|all) ;;
	*) echo "[census] 未知 Filter: $FILTER（可选 unit|integration|all）"; exit 2 ;;
esac

# 假绿守卫（两层共用）：套件加载/运行失败时不会有 Leaked instance 行，看起来像
# "零泄漏"。普查结果必须同时检查退出码，否则残缺类缓存/编译错误会把漏测伪装成干净。
guard_nonzero_exit() {
	local tsv="$1"
	local bad
	bad=$(awk -F'\t' 'NR>1 && $4 != 0' "$tsv" | wc -l | tr -d ' ')
	if [ "$bad" -gt 0 ]; then
		echo "[CENSUS] 警告：$bad 个套件退出码非 0（加载/运行失败/超时 124），其泄漏计数不可信："
		awk -F'\t' 'NR>1 && $4 != 0 {print "  " $1 " exit=" $4}' "$tsv"
		return 1
	fi
	return 0
}

census_unit() {
	local out="$1"
	printf "suite\tleaked_instances\tresources_in_use\texit_code\n" > "$out"
	for suite in tests/unit/*.gd; do
		base="$(basename "$suite" .gd)"
		timeout "$TIMEOUT_UNIT" "$GODOT" --headless --verbose --path . --script res://tests/lib/unit_suite_main.gd -- "res://$suite" > "/tmp/census_$base.log" 2>&1
		local code=$?
		local leaked
		leaked=$(grep -ac "^Leaked instance" "/tmp/census_$base.log" 2>/dev/null)
		local res
		res=$(grep -ac "^Resource still in use" "/tmp/census_$base.log" 2>/dev/null)
		printf "%s\t%s\t%s\t%s\n" "$base" "${leaked:-0}" "${res:-0}" "$code" >> "$out"
		echo "$base leaked=$leaked res=$res exit=$code"
	done
	echo "=== unit TOP 15 ==="
	sort -t$'\t' -k2 -rn "$out" | head -15
	guard_nonzero_exit "$out"
}

census_integration() {
	local out="$1"
	printf "suite\tleaked_instances\tresources_in_use\texit_code\n" > "$out"
	for suite in tests/integration/*.tscn; do
		base="$(basename "$suite" .tscn)"
		# 带 -- --fresh-start（对齐 run_all 口径）：存档类套件落盘会污染下一套
		timeout "$TIMEOUT_INTEGRATION" "$GODOT" --headless --verbose --path . "res://$suite" -- --fresh-start > "/tmp/census_$base.log" 2>&1
		local code=$?
		local leaked
		leaked=$(grep -ac "^Leaked instance" "/tmp/census_$base.log" 2>/dev/null)
		local res
		res=$(grep -ac "^Resource still in use" "/tmp/census_$base.log" 2>/dev/null)
		printf "%s\t%s\t%s\t%s\n" "$base" "${leaked:-0}" "${res:-0}" "$code" >> "$out"
		echo "$base leaked=$leaked res=$res exit=$code"
	done
	echo "=== integration TOP 20 ==="
	sort -t$'\t' -k2 -rn "$out" | head -20
	guard_nonzero_exit "$out"
}

case "$FILTER" in
	unit)
		OUT="${OUT:-/tmp/census_unit_leaks.tsv}"
		census_unit "$OUT" ;;
	integration)
		OUT="${OUT:-/tmp/census_integration_leaks.tsv}"
		census_integration "$OUT" ;;
	all)
		census_unit "${OUT:-/tmp/census_unit_leaks.tsv}"
		local_guard=$?
		census_integration "/tmp/census_integration_leaks.tsv"
		integ_guard=$?
		if [ "$local_guard" -eq 0 ] && [ "$integ_guard" -eq 0 ]; then exit 0; fi
		exit 1 ;;
esac
