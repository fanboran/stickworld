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
##
## P6 阵营 AI 扩展（7c+11c）：
##   - 场景名含 _team_ai 的变体双开 enable_team_ai(1/2)，采样姿态序列
##   - stance_seq：每 0.25s 记录双方姿态 {t, l, r}（0=GARRISON/1=DEFEND/2=ATTACK）
##   - stance_summary：各姿态占比/切换次数/是否到达 ATTACK/GARRISON
##   - 人工验收：运行后查 stance_summary，期望"先 ATTACK 压上、损耗后 DEFEND/GARRISON 回防"；
##     l_switches=0 → 姿态机未生效（查 enable_team_ai 是否调用）；
##     GARRISON 占比高 → 驻守触发集过敏感（调 enemy_close_dist/no_defender_floor）

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

## 武器类型（对齐 WeaponMount.WeaponType）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_STAFF: int = 4
const W_MERIC: int = 5

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
	# ── P6 阵营 AI 变体（双开 enable_team_ai，采样姿态序列）──
	{
		"name": "10剑_v_10剑_team_ai",
		"left": [W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD],
		"right": [W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD, W_SWORD],
		"team_ai": true,
	},
	{
		"name": "混编8矛8剑2杖2弓_v_镜像_team_ai",
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
		"team_ai": true,
	},
	# ── P7 祭司对照场景（单侧/双侧治疗收敛曲线）──
	{
		"name": "8矛2祭_v_8矛",
		"left": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
			W_MERIC, W_MERIC,
		],
		"right": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
		],
	},
	{
		"name": "8矛2祭_v_镜像",
		"left": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
			W_MERIC, W_MERIC,
		],
		"right": [
			W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR, W_SPEAR,
			W_MERIC, W_MERIC,
		],
	},
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

	# P6 阵营 AI：双开 enable_team_ai（注册制，不注册零回归）
	var team_ai_on: bool = bool(sc.get("team_ai", false))
	if team_ai_on and battle != null and is_instance_valid(battle) \
			and battle.has_method("enable_team_ai"):
		battle.enable_team_ai(1)
		battle.enable_team_ai(2)

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
	var stance_seq: Array = []          # P6 姿态序列采样 [{t, l, r}]
	var heal_cast_count: int = 0        # P7 heal_cast 信号计数
	var eb: Node = get_node_or_null("/root/EventBus")
	var heal_handler: Callable = func(_bid: String, _caster: int, _target: int, _anim: String) -> void:
		heal_cast_count += 1
	if eb != null and eb.has_signal("heal_cast"):
		eb.heal_cast.connect(heal_handler)
	while sim_time < SCENARIO_TIMEOUT:
		await get_tree().create_timer(0.25).timeout
		sim_time += 0.25
		# 尸体淡出移除后引用失效（2026-09-01 尸体清理引入）：先从采样数组剔除
		# freed 引用——类型化迭代 `for u: Node2D` 遇 freed 会报错中断本函数；
		# lambda 参数同样不注解 Node（freed 对象无法转换成注解类型，报
		# "Cannot convert Object to Object"），靠 is_instance_valid 短路兜底
		left = left.filter(func(u) -> bool: return is_instance_valid(u))
		right = right.filter(func(u) -> bool: return is_instance_valid(u))
		# 战斗结束（BattleInstance 结束即 queue_free）→ 记录并退出循环
		if battle == null or not is_instance_valid(battle):
			battle_still_active = false
			break
		if not battle.has_method("is_active") or not battle.is_active():
			battle_still_active = false
			break
		samples += 1
		# P6 姿态序列采样（team_ai 开时每周期记录双方姿态）
		if team_ai_on and battle != null and is_instance_valid(battle) \
				and battle.has_method("get_team_ai"):
			var tl: Variant = battle.get_team_ai(1)
			var tr: Variant = battle.get_team_ai(2)
			stance_seq.append({
				"t": snappedf(sim_time, 0.25),
				"l": int(tl.get_stance()) if tl != null and is_instance_valid(tl) and tl.has_method("get_stance") else -1,
				"r": int(tr.get_stance()) if tr != null and is_instance_valid(tr) and tr.has_method("get_stance") else -1,
			})
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
		"heal_casts": heal_cast_count,
	}
	if team_ai_on:
		result["stance_seq"] = stance_seq
		result["stance_summary"] = _summarize_stance_seq(stance_seq)
	# 清场
	if eb != null and eb.has_signal("heal_cast") and eb.heal_cast.is_connected(heal_handler):
		eb.heal_cast.disconnect(heal_handler)
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


## P6 姿态序列汇总（验收断言数据：压上→胶着→回防节奏分析）。
## 返回双方各姿态占比、切换次数、是否出现 ATTACK→DEFEND/GARRISON 迁移。
## 人工验收：占比应体现"先 ATTACK 压上、力量损耗后 DEFEND/GARRISON 回防"节奏；
## 切换次数 0 = 姿态机未生效（检查 enable_team_ai 是否调用）；GARRISON 占比高 = 驻守触发集过敏感。
func _summarize_stance_seq(seq: Array) -> Dictionary:
	if seq.is_empty():
		return {"error": "空序列"}
	var l_counts: Dictionary = {0: 0, 1: 0, 2: 0}
	var r_counts: Dictionary = {0: 0, 1: 0, 2: 0}
	var l_switches: int = 0
	var r_switches: int = 0
	var prev_l: int = -1
	var prev_r: int = -1
	for s in seq:
		var l: int = int(s["l"])
		var r: int = int(s["r"])
		if l >= 0:
			l_counts[l] = int(l_counts.get(l, 0)) + 1
			if prev_l >= 0 and l != prev_l:
				l_switches += 1
			prev_l = l
		if r >= 0:
			r_counts[r] = int(r_counts.get(r, 0)) + 1
			if prev_r >= 0 and r != prev_r:
				r_switches += 1
			prev_r = r
	var total: int = seq.size()
	return {
		"l_pct": {0: snappedf(float(l_counts[0]) / total * 100, 1.0),
				1: snappedf(float(l_counts[1]) / total * 100, 1.0),
				2: snappedf(float(l_counts[2]) / total * 100, 1.0)},
		"r_pct": {0: snappedf(float(r_counts[0]) / total * 100, 1.0),
				1: snappedf(float(r_counts[1]) / total * 100, 1.0),
				2: snappedf(float(r_counts[2]) / total * 100, 1.0)},
		"l_switches": l_switches,
		"r_switches": r_switches,
		"l_reached_attack": l_counts[2] > 0,
		"r_reached_attack": r_counts[2] > 0,
		"l_reached_garrison": l_counts[0] > 0,
		"r_reached_garrison": r_counts[0] > 0,
	}
