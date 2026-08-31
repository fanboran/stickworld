extends Node
## 战斗仿真统计器（headless 批量观察闭环，非 CI 测试）。
##
## 动机（2026-08-31 用户需求）：肉眼看打不过来——自动跑多组遭遇战场景，
## 采样每个单位的行为/位移/交战距离，输出"发呆率 / 远程交战距离 / 行为分布 /
## 战斗时长"，用数据驱动行为参数迭代。也是将来参数自动寻优（进化策略）的地基：
## 仿真闭环 + 可读指标就位后，把"人调参数"换成"机器扫参数"即可，无需引入 RL 黑盒。
##
## 运行：
##   godot --headless --path . res://tests/dev/battle_sim.tscn
##
## 场景矩阵（对齐用户点名的遭遇战类型）：
##   10剑v10剑 / 10剑v20剑（以少打多）/ 混编镜像 / 三组单挑（剑剑/矛剑/弓矛）
##
## 指标口径：
##   - daze（发呆）：连续 ≥3s 位移 <6px 且行为处于 idle/move/wander——
##     attack 站桩是有效输出不算；move 带方向也不算（除非根本没挪窝）
##   - ranged_engage_dist：弓/杖单位与最近敌人的距离采样（均值/中位）
##   - behavior 分布：各行为采样占比

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

## 武器类型（对齐 WeaponMount.WeaponType）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_STAFF: int = 4

## 场景矩阵：left/right = 兵种数组（数量即人数）
const SCENARIOS: Array = [
	{
		"name": "10剑_v_10剑",
		"left": [W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD],
		"right": [W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD],
	},
	{
		"name": "10剑_v_20剑",
		"left": [W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD],
		"right": [
			W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD,
			W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD,
		],
	},
	{
		"name": "混编8矛8剑2杖2弓_v_镜像",
		"left": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
			W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD,
			W_STAFF, W_STAFF, W_BOW, W_BOW,
		],
		"right": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
			W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD,
			W_STAFF, W_STAFF, W_BOW, W_BOW,
		],
	},
	{ "name": "1剑_v_1剑", "left": [W_SWORD], "right": [W_SWORD] },
	{ "name": "1矛_v_1剑", "left": [W_SPEAR], "right": [W_SWORD] },
	{ "name": "1弓_v_1矛", "left": [W_BOW], "right": [W_SPEAR] },
]

## 每场景最长模拟时长（游戏秒）
const SCENARIO_TIMEOUT: float = 45.0
## 两团出生中心相对中线的偏移
const TEAM_OFFSET_X: float = 650.0
## 出生排内 y 间距（对齐 SWL 队列：单位间约 1 个身位余量）
const SPAWN_GAP: float = 90.0
## headless 加速倍率（hitstop 在 headless 已禁用，无恢复冲突）
const SIM_TIME_SCALE: float = 3.0

var _game_root: Node = null
var _map: Node2D = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	_game_root.set("suppress_battlefield_enemies", true)
	for i in 10:
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map("battlefield")
	for i in 20:
		await get_tree().process_frame
		var m: Node2D = _game_root.get_current_map()
		if m != null and "battlefield" in str(m.scene_file_path):
			break
	_map = _game_root.get_current_map()
	if _map == null:
		print("[BattleSim][FATAL] 地图未加载")
		get_tree().quit(1)
		return
	for e in _map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame

	Engine.time_scale = SIM_TIME_SCALE
	var report: Dictionary = {}
	for sc in SCENARIOS:
		var t0 := Time.get_ticks_msec()
		report[sc["name"]] = await _run_scenario(sc)
		var wall: float = float(Time.get_ticks_msec() - t0) / 1000.0
		print("[BattleSim] %s 完成（真实耗时 %.1fs）" % [sc["name"], wall])
	Engine.time_scale = 1.0

	print("\n[BattleSim] ================ 汇总 ================")
	for k in report.keys():
		print("[BattleSim] %s => %s" % [k, JSON.stringify(report[k])])
	get_tree().quit(0)


## 跑一个场景：出生 → 开战 → 采样 → 统计 → 清场
func _run_scenario(sc: Dictionary) -> Dictionary:
	var mid_x: float = (_map.map_left + _map.map_right) * 0.5
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	var left: Array = []
	var right: Array = []
	for side in [["left", -1.0, left], ["right", 1.0, right]]:
		var arr: Array = sc[side[0]]
		var sign_x: float = side[1]
		var units: Array = side[2]
		for i in arr.size():
			var y: float = spawn_y + (float(i) - (arr.size() - 1) * 0.5) * SPAWN_GAP
			var u: Node2D = _spawn_unit(Vector2(mid_x + sign_x * TEAM_OFFSET_X, y), int(arr[i]))
			if u != null:
				units.append(u)
	await get_tree().process_frame
	await get_tree().process_frame

	var battle: Node = _game_root.start_test_battle(left, right)
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)

	# ── 采样循环 ──
	var behavior_count: Dictionary = {}
	var samples: int = 0
	var alive_samples: int = 0          # 只累计存活单位的采样数（行为占比的分母）
	var battle_still_active: bool = true
	var ranged_dists: Array = []
	var still_time: Dictionary = {}     # iid -> 连续静止秒
	var dazed: Dictionary = {}          # iid -> {weapon, faction}
	var last_pos: Dictionary = {}       # iid -> Vector2
	var sim_time: float = 0.0
	while sim_time < SCENARIO_TIMEOUT:
		await get_tree().create_timer(0.25).timeout
		sim_time += 0.25
		# 战斗结束（BattleInstance 结束即 queue_free）→ 记录并退出循环
		if battle == null or not is_instance_valid(battle):
			battle_still_active = false
			break
		if not battle.has_method("is_active") or not battle.is_active():
			battle_still_active = false
			break
		samples += 1
		for u: Node2D in left + right:
			if not is_instance_valid(u) or u.is_dead():
				continue
			alive_samples += 1
			var ai: Node = u.get_node_or_null("AIController")
			var behavior: String = ai.get_current_behavior() if ai != null else "?"
			behavior_count[behavior] = int(behavior_count.get(behavior, 0)) + 1
			# 发呆检测：连续静止 3s 且行为 idle/move/wander（attack 站桩=有效输出）
			var iid: int = u.get_instance_id()
			var pos: Vector2 = u.global_position
			var moved: bool = last_pos.has(iid) and pos.distance_to(last_pos[iid]) > 6.0
			last_pos[iid] = pos
			if moved:
				still_time[iid] = 0.0
			else:
				still_time[iid] = float(still_time.get(iid, 0.0)) + 0.25
			if still_time[iid] >= 3.0 and behavior in ["idle", "move", "wander"] \
					and not dazed.has(iid):
				dazed[iid] = { "weapon": u.get("weapon_mount").weapon_type if u.get("weapon_mount") != null else -1 }
			# 远程交战距离：弓/杖与最近敌人的距离采样
			var wm: Node = u.get_node_or_null("WeaponMount")
			if wm != null and int(wm.weapon_type) in [W_BOW, W_STAFF]:
				var d: float = _nearest_enemy_dist(u)
				if d > 0.0:
					ranged_dists.append(d)

	# ── 结算统计 ──
	var alive_l := _count_alive(left)
	var alive_r := _count_alive(right)
	var dist_sorted := ranged_dists.duplicate()
	dist_sorted.sort()
	var dist_median: float = dist_sorted[dist_sorted.size() / 2] if not dist_sorted.is_empty() else -1.0
	var dist_avg: float = 0.0
	if not ranged_dists.is_empty():
		for d in ranged_dists:
			dist_avg += d
		dist_avg /= ranged_dists.size()
	var behavior_pct: Dictionary = {}
	for b in behavior_count.keys():
		behavior_pct[b] = snappedf(float(behavior_count[b]) / maxf(1.0, float(alive_samples)) * 100.0, 0.1)
	var result: Dictionary = {
		"duration": sim_time,
		"ended": not battle_still_active,
		"left_alive": alive_l,
		"right_alive": alive_r,
		"behavior_pct": behavior_pct,
		"daze_units": dazed.size(),
		"ranged_engage_avg": snappedf(dist_avg, 1.0),
		"ranged_engage_median": snappedf(dist_median, 1.0),
	}
	# 清场
	for u in left + right:
		if is_instance_valid(u):
			u.queue_free()
	for i in 3:
		await get_tree().process_frame
	return result


## 出生一个单位（照抄 battle_arena：脚底对齐 + 不附身 + 设武器 + hp 兜底）
func _spawn_unit(pos: Vector2, wtype: int) -> Node2D:
	var e: Node2D = _map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


## 最近敌人距离（无战斗/无敌返回 -1）
func _nearest_enemy_dist(u: Node2D) -> float:
	if not u.has_method("get_battle_instance"):
		return -1.0
	var bi: Node = u.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_enemies_of"):
		return -1.0
	var faction: int = u.get_faction() if u.has_method("get_faction") else 0
	if faction == 0:
		return -1.0
	var best: float = -1.0
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
			continue
		var d: float = u.global_position.distance_to(e.global_position)
		if best < 0.0 or d < best:
			best = d
	return best


func _count_alive(units: Array) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n
