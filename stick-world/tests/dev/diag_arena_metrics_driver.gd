extends Node
## 无头指标采集 —— 观察场战斗 AI 的数据点测试台（先量化症状，再改算法，数字对比验收）。
## 主症状（创始人 2026-09-30 口述）：双方士兵在屏幕上几乎均匀分布，
## 明明身边有敌人却疲于奔命地互相追逐。
## 量化口径：
##   疲于奔命率 = 近敌(<=80px) 却在高机动跑动的单位占比 —— 核心坏指标，越低越好
##   追逐翻转率 = 交火带(<=240px)内"接近→远离"符号翻转的占比 —— 追逐振荡签名
##   均匀铺开度 = 全场 4x4 网格人数变异系数 CV —— 越低越说明均匀铺开（坏），抱团交战 CV 高
##   互为最近对占比 = 我最近的敌人其最近的单位也是我 —— 距离配对拆散两军的名场面
## 用法：godot --headless --path stick-world res://tests/dev/diag_arena_metrics_shots.tscn
## 输出：stdout 摘要 + 逐采样 CSV（user://shots/arena_ai_metrics.csv）

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const CSV_PATH := "user://shots/arena_ai_metrics.csv"
const SETTLE_FRAMES := 90       # 出生列阵完成
const SAMPLE_EVERY := 30        # ~0.5s 一采样
const TOTAL_SAMPLES := 120      # 共 60s 战斗
const ENGAGE_BAND := 80.0       # 近战接战带（像素）
const FIRE_BAND := 240.0        # 交火带
const CHASE_SPEED := 60.0       # 采样间位移速度高于此视为"在跑"（px/s）
const GRID_N := 4               # 均匀度网格 4x4

var _rows: Array = []


func run() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)
	await _frames(SETTLE_FRAMES)
	var battle := _find_battle_instance()
	if battle == null:
		push_error("[ArenaMetrics] 找不到 battle_instance，无法采数")
		get_tree().quit(1)
		return
	var f := FileAccess.open(CSV_PATH, FileAccess.WRITE)
	f.store_line("t,alive_a,alive_d,routed,near80,near80_run,mutual_pair,dens_cv,mean_nn,churn_flip")
	for s in TOTAL_SAMPLES:
		await _frames(SAMPLE_EVERY)
		# 溃散收敛（9k-2）：战斗可能提前结算、实例 queue_free——收敛即止，
		# 摘要按已采样本算（血鹰批次兼容补丁：原实现对已释放实例取名册会崩）
		if not is_instance_valid(battle) or not battle.is_active():
			print("[ArenaMetrics] 战斗已于第 %d 次采样前收敛结束，采样提前止步（溃散收敛新语义）" % s)
			break
		var row := _sample(battle, s * SAMPLE_EVERY / 60.0, s)
		f.store_line(row["csv"])
	f.flush()
	f.close()
	_summary()
	get_tree().quit(0)


## 单次采样：只读单位公共面（位置/阵营/健康），位移速度用采样间差分（不依赖实体 velocity 语义）
func _sample(battle: Node, t: float, idx: int) -> Dictionary:
	var units: Array = []
	for arr in [battle.get("_units_attacker"), battle.get("_units_defender")]:
		if arr == null:
			continue
		for u in arr:
			if not is_instance_valid(u):
				continue
			var hp: Node = u.get_health() if u.has_method("get_health") else null
			if hp != null and hp.is_dead():
				continue
			var routed: bool = hp != null and hp.is_routed()
			units.append({"u": u, "pos": (u as Node2D).global_position, "routed": routed})
	var alive := units.size()
	var routed_n := 0
	for it in units:
		if it["routed"]:
			routed_n += 1
	# 最近敌 + 位移速度
	var near_d := {}
	var speed := {}
	for it in units:
		var best := INF
		var best_u: Node = null
		for ot in units:
			if ot["u"] == it["u"]:
				continue
			if ot["routed"]:
				continue    # 溃兵不算战斗对手
			var d: float = (it["pos"] as Vector2).distance_to(ot["pos"])
			if d < best:
				best = d
				best_u = ot["u"]
		near_d[it["u"].get_instance_id()] = {"d": best, "e": best_u}
		var key: int = it["u"].get_instance_id()
		if _prev_pos.has(key):
			speed[key] = (it["pos"] as Vector2).distance_to(_prev_pos[key]) / (SAMPLE_EVERY / 60.0)
		else:
			speed[key] = 0.0
		_prev_pos[key] = it["pos"]
	# 指标
	var near80 := 0
	var near80_run := 0
	var mutual := 0
	var churn := 0
	var nn_sum := 0.0
	var nn_n := 0
	for it in units:
		var id: int = it["u"].get_instance_id()
		var nd: Dictionary = near_d[id]
		if nd["d"] == INF:
			continue
		nn_sum += nd["d"]
		nn_n += 1
		if nd["d"] <= ENGAGE_BAND:
			near80 += 1
			if speed.get(id, 0.0) > CHASE_SPEED:
				near80_run += 1
		# 互为最近对
		var e: Node = nd["e"]
		if e != null and near_d.has(e.get_instance_id()):
			if near_d[e.get_instance_id()]["e"] == it["u"]:
				mutual += 1
		# 接近/远离翻转
		if nd["d"] <= FIRE_BAND:
			var sign_now := signf((near_d[id]["e"] as Node2D).global_position.x - (it["pos"] as Vector2).x)
			if _prev_dir.has(id) and sign_now != 0.0 and _prev_dir[id] != 0.0 \
					and sign_now != _prev_dir[id] and speed.get(id, 0.0) > CHASE_SPEED:
				churn += 1
			if sign_now != 0.0:
				_prev_dir[id] = sign_now
	var cv := _density_cv(units)
	var mean_nn := nn_sum / nn_n if nn_n > 0 else 0.0
	var row := {
		"t": t, "alive": alive,
		"near80": near80, "near80_run": near80_run,
		"mutual": mutual, "cv": cv, "mean_nn": mean_nn, "churn": churn,
		"csv": "%2.1f,%d,%d,%d,%d,%d,%d,%.3f,%.1f,%d" % [
			t, _alive_of(battle, 0), _alive_of(battle, 1), routed_n,
			near80, near80_run, mutual, cv, mean_nn, churn],
	}
	_rows.append(row)
	return row


func _alive_of(battle: Node, faction: int) -> int:
	var arr: Array = battle.get("_units_attacker" if faction == 0 else "_units_defender")
	if arr == null:
		return 0
	var n := 0
	for u in arr:
		if is_instance_valid(u):
			var hp: Node = u.get_health() if u.has_method("get_health") else null
			if hp != null and not hp.is_dead():
				n += 1
	return n


## 全场包围盒 4x4 网格人数变异系数：均匀铺开 → 趋近 0；抱团交战 → 明显大
func _density_cv(units: Array) -> float:
	if units.is_empty():
		return 0.0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for it in units:
		lo = lo.min(it["pos"])
		hi = hi.max(it["pos"])
	var size := (hi - lo).max(Vector2(1, 1))
	var counts := []
	for i in GRID_N * GRID_N:
		counts.append(0)
	for it in units:
		var off: Vector2 = ((it["pos"] as Vector2) - lo) / size
		var gx: int = clampi(int(off.x * GRID_N), 0, GRID_N - 1)
		var gy: int = clampi(int(off.y * GRID_N), 0, GRID_N - 1)
		counts[gy * GRID_N + gx] += 1
	var mean := float(alive_n(counts)) / counts.size()
	if mean <= 0.0:
		return 0.0
	var var_sum := 0.0
	for c in counts:
		var d: float = c - mean
		var_sum += d * d
	return sqrt(var_sum / counts.size()) / mean


func alive_n(counts: Array) -> int:
	var n := 0
	for c in counts:
		n += c
	return n


## 汇总：全程均值 + 三时段分解，直接可贴进验收报告的数字
func _summary() -> void:
	var n := _rows.size()
	if n == 0:
		return
	var bands := {"早盘": [0, n / 3], "中盘": [n / 3, 2 * n / 3], "残局": [2 * n / 3, n]}
	print("[ArenaMetrics] ===== 摘要（采样 %d 次 / %.0fs）=====" % [n, n * SAMPLE_EVERY / 60.0])
	print("[ArenaMetrics] 指标口径：疲于奔命率=near80_run/near80；均匀铺开度=dens_cv(越低越坏)；追逐翻转=churn")
	for b in bands:
		var lo: int = bands[b][0]
		var hi: int = bands[b][1]
		var sum := {"near80": 0.0, "run": 0.0, "cv": 0.0, "nn": 0.0, "churn": 0.0, "mutual": 0.0}
		var m := 0
		for i in range(lo, hi):
			var r: Dictionary = _rows[i]
			sum["near80"] += r["near80"]
			sum["run"] += r["near80_run"]
			sum["cv"] += r["cv"]
			sum["nn"] += r["mean_nn"]
			sum["churn"] += r["churn"]
			sum["mutual"] += r["mutual"]
			m += 1
		if m == 0:
			continue
		var fatigue: float = sum["run"] / maxf(sum["near80"], 1.0)
		print("[ArenaMetrics] %s：接战带内均值=%.1f 疲于奔命率=%.0f%% 追逐翻转=%.1f 互为最近对=%.1f 均匀度CV=%.3f 平均最近敌=%.0fpx" % [
			b, sum["near80"] / m, fatigue * 100.0, sum["churn"] / m, sum["mutual"] / m, sum["cv"] / m, sum["nn"] / m])
	print("[ArenaMetrics] CSV 已存 user://shots/arena_ai_metrics.csv")


var _prev_pos := {}
var _prev_dir := {}


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## battle_instance 挂在地图装配深处且不对外暴露名册——测试台按脚本路径定位并读
## 名册私有数组（GDScript 无真私有，测试工具豁免架构纪律，勿在玩法代码效仿）
func _find_battle_instance() -> Node:
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_script() != null \
				and String(n.get_script().resource_path).ends_with("battle_instance.gd"):
			return n
		stack.append_array(n.get_children())
	return null
