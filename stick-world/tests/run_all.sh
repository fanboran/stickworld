#!/usr/bin/env bash
# 测试编排器（bash 版，替代原 run_all.ps1）
#
# 设计（2026-08 测试架构）：
#   - unit 层：单进程批量（batch_runner.tscn，套件数见 UNIT_SCRIPTS 清单）
#   - integration / smoke 层：进程级并行池（默认 4，上限 8），套件间互不共享状态
#   - 每套件耗时输出 + JSON 报告
#
# 用法（在 stick-world/ 或任意目录均可）：
#   tests/run_all.sh                          # 全量
#   tests/run_all.sh -Filter unit             # 只跑 unit（批量，秒级）
#   tests/run_all.sh -Filter integration      # 只跑 integration
#   tests/run_all.sh -Match combat            # 按套件名过滤（如 combat / world_map / battle）
#   tests/run_all.sh -Changed HEAD~1          # 只跑 git diff 影响到的套件（含 unit 批量）
#   tests/run_all.sh -Parallel 8              # 调整并行度（1-8）
#   tests/run_all.sh -Report /tmp/report.json # 输出 JSON 报告
#   GODOT="/path/to/godot" tests/run_all.sh   # 自定义 Godot 路径
#
# 退出码：0 全过，1 有失败。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Godot 原生程序使用 Windows 风格路径（MSYS 的 /f/... 不保证被转换）
PROJECT_DIR_WIN="$PROJECT_DIR"
if command -v cygpath >/dev/null 2>&1; then
	PROJECT_DIR_WIN="$(cygpath -m "$PROJECT_DIR")"
fi
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
# Windows Git Bash 下 %TEMP% 是反斜杠路径，bash 重定向不识别，需用 cygpath 归一化
if command -v cygpath >/dev/null 2>&1; then
	TMP_BASE="$(cygpath -u "${TMPDIR:-$TEMP}" 2>/dev/null || true)"
fi
if [ -z "${TMP_BASE:-}" ]; then
	TMP_BASE="${TMPDIR:-/tmp}"
fi
TMP_DIR="$TMP_BASE/sw_tests_$$"

FILTER=""
MATCH=""
CHANGED=""
PARALLEL=4
REPORT=""

while [ $# -gt 0 ]; do
	case "$1" in
		-Filter) FILTER="$2"; shift 2 ;;
		-Match) MATCH="$2"; shift 2 ;;
		-Changed) CHANGED="${2:-HEAD~1}"; shift 2 ;;
		-Parallel) PARALLEL="$2"; shift 2 ;;
		-Report) REPORT="$2"; shift 2 ;;
		-h|--help) head -30 "$0"; exit 0 ;;
		*) echo "[run_all] 未知参数: $1"; exit 2 ;;
	esac
done
[ "$PARALLEL" -gt 8 ] 2>/dev/null && PARALLEL=8
[ "$PARALLEL" -lt 1 ] 2>/dev/null && PARALLEL=1

INTEGRATION_SUITES=(
	"tests/integration/test_construction_cycle.tscn"
	"tests/integration/test_ai_behaviors.tscn"
	"tests/integration/test_game_root_assembly.tscn"
	"tests/integration/test_village_map.tscn"
	"tests/integration/test_battle_lifecycle.tscn"
	"tests/integration/test_selection_formation.tscn"
	"tests/integration/test_possession.tscn"
	"tests/integration/test_formation_presets.tscn"
	"tests/integration/test_strategic_map_p0.tscn"
	"tests/integration/test_l3_strategic_map.tscn"
	"tests/integration/test_l2_strategic_map.tscn"
	"tests/integration/test_strategic_map_ui.tscn"
	"tests/integration/test_squad_travel.tscn"
	"tests/integration/test_melee_combat.tscn"
	"tests/integration/test_combat_feedback.tscn"
	"tests/integration/test_combat_control.tscn"
	"tests/integration/test_menu_navigation.tscn"
	"tests/integration/test_modal_stack.tscn"
	"tests/integration/test_esc_key_input.tscn"
	"tests/integration/test_ui_layout.tscn"
	"tests/integration/test_battle_ui.tscn"
	"tests/integration/test_formation_system_assembly.tscn"
	"tests/integration/test_placement_grid_units.tscn"
	"tests/integration/test_tactical_orders.tscn"
	"tests/integration/test_save_roundtrip.tscn"
	"tests/integration/test_anim_finished.tscn"
)
SMOKE_SUITES=(
	"tests/smoke/test_new_game_smoke.tscn"
	"tests/smoke/test_cross_map_travel.tscn"
)

declare -A SUITE_TIMEOUT=(
	# 每套件超时：长套件按串行实测 ×2 取整，短套件统一 ≥90s
	# （2026-08 审计校准：并行 6 下 CPU 争用系数实测最高 ~2.5x，短套件 60s 边界会碰运气误杀）
	["tests/integration/test_battle_lifecycle.tscn"]=120
	["tests/integration/test_selection_formation.tscn"]=90
	["tests/integration/test_possession.tscn"]=90
	["tests/integration/test_village_map.tscn"]=90
	["tests/smoke/test_cross_map_travel.tscn"]=120
	["tests/smoke/test_new_game_smoke.tscn"]=120
	["tests/integration/test_ai_behaviors.tscn"]=90
	["tests/integration/test_game_root_assembly.tscn"]=90
	["tests/integration/test_formation_presets.tscn"]=110
	["tests/integration/test_l2_strategic_map.tscn"]=120
	["tests/integration/test_squad_travel.tscn"]=90
	["tests/integration/test_melee_combat.tscn"]=120
	["tests/integration/test_combat_feedback.tscn"]=120
	["tests/integration/test_combat_control.tscn"]=90
	["tests/integration/test_menu_navigation.tscn"]=95
	["tests/integration/test_modal_stack.tscn"]=95
	["tests/integration/test_esc_key_input.tscn"]=90
	["tests/integration/test_ui_layout.tscn"]=90
	["tests/integration/test_battle_ui.tscn"]=90
	["tests/integration/test_formation_system_assembly.tscn"]=90
	["tests/integration/test_tactical_orders.tscn"]=90
)
DEFAULT_TIMEOUT=90

# ─────────────────────────────── affected 映射 ───────────────────────────────

## 输出受变更文件影响的套件（"unit" 表示 unit 批量层，suite 路径为 integration/smoke）。
affected_suites() {
	local changed="$1"
	local -A picked
	local core_hit=""
	for f in $changed; do
		case "$f" in
			stick-world/core/*|stick-world/project.godot|stick-world/config/*|stick-world/tests/core/*|AGENTS.md|.pre-commit-config.yaml|.gitattributes)
				core_hit=1 ;;
			stick-world/modules/units/*|stick-world/assets/*)
				picked["tests/integration/test_ai_behaviors.tscn"]=1
				picked["tests/integration/test_possession.tscn"]=1
				picked["tests/integration/test_melee_combat.tscn"]=1
				picked["tests/integration/test_combat_feedback.tscn"]=1
				picked["tests/integration/test_combat_control.tscn"]=1
				picked["tests/integration/test_placement_grid_units.tscn"]=1 ;;
			stick-world/modules/combat/*)
				picked["tests/integration/test_battle_lifecycle.tscn"]=1
				picked["tests/integration/test_selection_formation.tscn"]=1
				picked["tests/integration/test_formation_presets.tscn"]=1
				picked["tests/integration/test_formation_system_assembly.tscn"]=1
				picked["tests/integration/test_tactical_orders.tscn"]=1
				picked["tests/integration/test_battle_ui.tscn"]=1
				picked["tests/integration/test_squad_travel.tscn"]=1
				picked["tests/integration/test_melee_combat.tscn"]=1
				picked["tests/integration/test_combat_feedback.tscn"]=1
				picked["tests/integration/test_combat_control.tscn"]=1 ;;
			stick-world/modules/construction/*)
				picked["tests/integration/test_construction_cycle.tscn"]=1
				picked["tests/integration/test_placement_grid_units.tscn"]=1 ;;
			stick-world/modules/world_map/*)
				picked["tests/integration/test_strategic_map_p0.tscn"]=1
				picked["tests/integration/test_l2_strategic_map.tscn"]=1
				picked["tests/integration/test_l3_strategic_map.tscn"]=1 ;;
			stick-world/modules/world/*|stick-world/tools/check_godot_errors.sh)
				picked["tests/integration/test_game_root_assembly.tscn"]=1
				picked["tests/integration/test_village_map.tscn"]=1
				picked["tests/integration/test_menu_navigation.tscn"]=1
				picked["tests/integration/test_modal_stack.tscn"]=1
				picked["tests/integration/test_battle_ui.tscn"]=1
				picked["tests/smoke/test_new_game_smoke.tscn"]=1
				picked["tests/smoke/test_cross_map_travel.tscn"]=1 ;;
			stick-world/modules/ui_global/*)
				picked["tests/integration/test_battle_ui.tscn"]=1
				picked["tests/integration/test_menu_navigation.tscn"]=1
				picked["tests/integration/test_modal_stack.tscn"]=1
				picked["tests/integration/test_esc_key_input.tscn"]=1
				picked["tests/integration/test_ui_layout.tscn"]=1 ;;
			stick-world/modules/resources/*)
				picked["tests/integration/test_construction_cycle.tscn"]=1 ;;
			stick-world/modules/organization/*)
				picked["tests/integration/test_formation_presets.tscn"]=1 ;;
			stick-world/modules/player_control/*)
				picked["tests/integration/test_possession.tscn"]=1
				picked["tests/integration/test_selection_formation.tscn"]=1
				picked["tests/integration/test_menu_navigation.tscn"]=1 ;;
			stick-world/modules/building_gen/*|stick-world/modules/texture_gen/*)
				picked["tests/integration/test_construction_cycle.tscn"]=1
				picked["tests/integration/test_village_map.tscn"]=1 ;;
			stick-world/tests/integration/test_*.tscn)
				picked["tests/integration/${f##*/}"]=1 ;;
			stick-world/tests/smoke/test_*.tscn)
				picked["tests/smoke/${f##*/}"]=1 ;;
			stick-world/tests/unit/*|stick-world/tests/batch_runner.*|stick-world/tests/run_all.sh|stick-world/tests/run_unit.sh)
				: ;; # unit 层始终随 -Changed 跑（秒级），无需挑选
		esac
	done
	if [ -n "$core_hit" ]; then
		echo "ALL"
		return
	fi
	for s in "${!picked[@]}"; do echo "$s"; done | sort
}

# ─────────────────────────────── 套件执行（内联在并行池子进程中）───────────────────────────────

## 过滤套件列表（-Match / -Filter / -Changed）
select_suites() {
	local list=("$@") out=()
	for scene in "${list[@]}"; do
		if [ -n "$MATCH" ] && [[ "$scene" != *"$MATCH"* ]]; then continue; fi
		out+=("$scene")
	done
	printf '%s\n' "${out[@]}"
}

# ─────────────────────────────── 主流程 ───────────────────────────────

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

run_unit=0 run_integration=0 run_smoke=0
case "$FILTER" in
	unit) run_unit=1 ;;
	integration) run_integration=1 ;;
	smoke) run_smoke=1 ;;
	stage) echo "[run_all] stage 无套件"; exit 0 ;;
	"") run_unit=1; run_integration=1; run_smoke=1 ;;
	*) echo "[run_all] 未知 Filter: $FILTER（可选 unit|integration|smoke）"; exit 2 ;;
esac

if [ -n "$CHANGED" ]; then
	changed_files=$(git -C "$PROJECT_DIR" diff --name-only "$CHANGED" 2>/dev/null)
	if [ -z "$changed_files" ]; then
		changed_files=$(git -C "$PROJECT_DIR" diff --name-only --cached "$CHANGED" 2>/dev/null)
	fi
	if [ -z "$changed_files" ]; then
		echo "[run_all] -Changed $CHANGED: 无 diff（可能基准不存在），退回全量"
	else
		affected=$(affected_suites "$changed_files")
		if [ "$affected" = "ALL" ]; then
			echo "[run_all] -Changed: 核心/配置改动 → 全量"
		else
			echo "[run_all] -Changed $CHANGED: 受影响套件 →"
			echo "$affected" | sed 's/^/    /'
			INTEGRATION_SUITES=($(printf '%s\n' "${INTEGRATION_SUITES[@]}" | grep -Ff <(echo "$affected")))
			SMOKE_SUITES=($(printf '%s\n' "${SMOKE_SUITES[@]}" | grep -Ff <(echo "$affected")))
			if [ ${#INTEGRATION_SUITES[@]} -eq 0 ] && [ ${#SMOKE_SUITES[@]} -eq 0 ] && [ "$run_unit" -eq 0 ]; then
				echo "[run_all] 无匹配套件（文档类改动），跳过"
				exit 0
			fi
		fi
	fi
fi

total_pass=0 total_fail=0
declare -a failures=()
declare -a report_entries=()

# unit 层：单进程批量
if [ "$run_unit" -eq 1 ]; then
	t0=$(date +%s%3N)
	unit_count=$(grep -c 'res://tests/unit/' "$SCRIPT_DIR/batch_runner.gd")
	if "$GODOT" --headless --path "$PROJECT_DIR_WIN" res://tests/batch_runner.tscn >"$TMP_DIR/unit.out" 2>"$TMP_DIR/unit.err"; then
		t1=$(date +%s%3N)
		total_pass=$((total_pass + 1))
		unit_secs=$(awk "BEGIN{printf \"%.1f\", ($t1-$t0)/1000}")
		echo "[PASS] unit 批量（${unit_count} 套） [${unit_secs}s]"
		report_entries+=("{\"suite\":\"unit(batch)\",\"result\":\"pass\",\"seconds\":$unit_secs}")
	else
		t1=$(date +%s%3N)
		total_fail=$((total_fail + 1))
		failures+=("unit(batch)")
		unit_secs=$(awk "BEGIN{printf \"%.1f\", ($t1-$t0)/1000}")
		echo "[FAIL] unit 批量 [${unit_secs}s]"
		report_entries+=("{\"suite\":\"unit(batch)\",\"result\":\"fail\",\"seconds\":$unit_secs}")
		grep -aE "测试汇总|BATCH-FAIL|SCRIPT ERROR" "$TMP_DIR/unit.out" | tail -6 | sed 's/^/    /'
	fi
fi

# integration + smoke：并行池
pool=()
if [ "$run_integration" -eq 1 ]; then pool+=("${INTEGRATION_SUITES[@]}"); fi
if [ "$run_smoke" -eq 1 ]; then pool+=("${SMOKE_SUITES[@]}"); fi
filtered=()
while IFS= read -r l; do
	[ -n "$l" ] && filtered+=("$l")
done < <(select_suites "${pool[@]}")
pool=("${filtered[@]}")

if [ ${#pool[@]} -gt 0 ]; then
	active=0
	# 单套件执行器（后台函数体）：不用 xargs/export，避免 Windows Git Bash 环境变量过大
	launch_suite() {
		scene="$1"
		base="${scene##*/}"; base="${base%.tscn}"
		out="$TMP_DIR/$base.out" err="$TMP_DIR/$base.err" res="$TMP_DIR/$base.res"
		local timeout="${SUITE_TIMEOUT[$scene]:-$DEFAULT_TIMEOUT}"
		t0=$(date +%s%3N)
		"$GODOT" --headless --path "$PROJECT_DIR_WIN" "res://$scene" -- --fresh-start >"$out" 2>"$err" &
		pid=$!
		( sleep "$timeout"; kill -9 "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
		killer=$!
		wait "$pid" 2>/dev/null; code=$?
		kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
		t1=$(date +%s%3N); ms=$((t1 - t0))
		if [[ "$code" =~ ^[0-9]+$ ]] && [ "$code" -ge 137 ]; then
			echo "TIMEOUT $ms" >"$res"; return 0
		fi
		sum=$(grep -aE "测试汇总|\[FAIL\]" "$out" | tail -8)
		if [ -z "$sum" ]; then
			echo "FAIL $ms no-summary" >"$res"
		elif printf "%s" "$sum" | grep -aq "\[FAIL\]"; then
			echo "FAIL $ms" >"$res"
		else
			echo "PASS $ms" >"$res"
		fi
	}
	for scene in "${pool[@]}"; do
		while [ "$active" -ge "$PARALLEL" ]; do
			wait -n 2>/dev/null || true
			active=$((active - 1))
		done
		launch_suite "$scene" &
		active=$((active + 1))
	done
	wait 2>/dev/null || true
	# 汇总（保持声明顺序）
	for scene in "${pool[@]}"; do
		base="${scene##*/}"; base="${base%.tscn}"
		res_file="$TMP_DIR/$base.res"
		[ -f "$res_file" ] || { echo "[FAIL] $scene (no result)"; total_fail=$((total_fail + 1)); failures+=("$scene"); continue; }
		read -r result ms extra <"$res_file"
		secs=$(awk "BEGIN{printf \"%.1f\", $ms/1000}")
		case "$result" in
			PASS)
				total_pass=$((total_pass + 1))
				echo "[PASS] $scene [${secs}s]"
				report_entries+=("{\"suite\":\"$scene\",\"result\":\"pass\",\"seconds\":$secs}") ;;
			TIMEOUT)
				total_fail=$((total_fail + 1)); failures+=("$scene (TIMEOUT)")
				echo "[FAIL] $scene [TIMEOUT]"
				report_entries+=("{\"suite\":\"$scene\",\"result\":\"timeout\",\"seconds\":$secs}") ;;
			*)
				total_fail=$((total_fail + 1)); failures+=("$scene")
				echo "[FAIL] $scene [${secs}s]"
				report_entries+=("{\"suite\":\"$scene\",\"result\":\"fail\",\"seconds\":$secs}")
				grep -aE "测试汇总|\[FAIL\]" "$TMP_DIR/$base.out" 2>/dev/null | tail -4 | sed 's/^/    /' ;;
		esac
	done
fi

# JSON 报告（-Report）
if [ -n "$REPORT" ] && [ ${#report_entries[@]} -gt 0 ]; then
	{
		printf '{\n  "summary": {"passed": %d, "failed": %d},\n  "suites": [\n' "$total_pass" "$total_fail"
		printf '    %s\n' "$(printf '%s\n' "${report_entries[@]}" | paste -sd',')"
		printf '  ]\n}\n'
	} >"$REPORT"
	echo "[run_all] 报告已写入: $REPORT"
fi

echo ""
echo "=== 汇总: $total_pass 通过 / $total_fail 失败（并行 $PARALLEL）==="
if [ ${#failures[@]} -gt 0 ]; then
	echo "失败项:"
	for f in "${failures[@]}"; do echo "  - $f"; done
	echo "建议重跑: tests/run_all.sh -Match ${failures[0]%%/*}"
	exit 1
fi
exit 0
