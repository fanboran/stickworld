extends "res://tests/dev/benchmark_brains/bench_brain_base.gd"
## NN 指挥官选手 —— 把自博弈 RL checkpoint 装成 Benchmark 选手（训练设施 v1）。
##
## 原理：观察走 bench_brain_base 协议（观察面全开：单位/血量/旗点只读），决策走
## policy_net 前向（argmax 贪心，零采样），号令走 TacticalOrders 既有通道——与
## 训练侧 battle_env 的观察编码/动作词汇逐位一致（57 维自视角镜像 + 3 班×5 意图），
## 同一网络两边执掌。对手 = 场上另一侧的内嵌军师规划器 / 旧指挥。
##
## 接线细节（battle_arena 场景内）：
##   - 本方规划器除名（arena._planners.erase，同 incumbent_teamai_brain 手法）——
##     号令权归网络，防双脑互覆；
##   - 若本方恰是被除名的"结算权规划器"（惯例 = 攻方那台 drives_settlement=true），
##     本选手接手夺点占领结算 tick（每拍喂半径人数）——结算每拍只准一次的纪律不变；
##   - 无 checkpoint / 维度不符 → 退化启发式（全员攻中旗/接敌），保证对打不出错。
##
## 用法：run_parallel.py --brain-a res://tests/dev/benchmark_brains/nn_brain.gd
## 或 diag_arena_benchmark_driver.gd 把 BRAIN_A 指到本文件。

const PolicyNetScript: GDScript = preload("res://tests/dev/rl/policy_net.gd")
const OrdersScript: GDScript = preload("res://modules/tactics/scripts/tactical_orders.gd")

## 决策节拍（与训练侧 battle_env.BEAT 同拍）
const BEAT: float = 0.5
## 镜像观察的战斗时长基准（与训练侧 BATTLE_TIME_LIMIT 同口径）
const TIME_LIMIT: float = 125.0
## 号令节流（与训练侧同参：漂移重发 / 到位驻守 / 定期刷新）
const ORDER_EPS_DIST: float = 80.0
const GARRISON_ARRIVE_DIST: float = 60.0
const ORDER_REFRESH_BEATS: int = 6
## checkpoint 路径（训练器落档处）
const CHECKPOINT_PATH: String = "user://rl/checkpoint.json"

## 网络（checkpoint 加载失败 = null → 启发式退化）
var _net: RefCounted = null
## 战斗域阵营（1=攻/左，2=守/右；ctx.faction 0/1 映射）
var _my_faction: int = 1
## 镜像符号（本方永远"从左往右打"）
var _mir: float = 1.0
## 是否由本选手驱动夺点结算（本方 = 被除名的攻方结算权规划器时为真）
var _drives_settlement: bool = false
## 号令节点 / 编队系统 / 旗点（setup 时解析，解析失败走退化）
var _orders: Node = null
var _formation: Node = null
var _points: Array = []
## 我方班（编制序）：[{id, units, initial_n}]
var _squads: Array = []
## 每拍状态：节拍累积 / 上拍意图 / 号令节流
var _beat_acc: float = 0.0
var _last_intents: Array = [-1, -1, -1]
var _order_state: Dictionary = {}


func brain_name() -> String:
	return "NN指挥官" + ("(checkpoint)" if _net != null else "(启发式退化)")


func setup() -> void:
	_my_faction = int(ctx.faction) + 1
	_mir = 1.0 if _my_faction == 1 else -1.0
	# 网络：checkpoint 装载（缺失/维度不符 → null，beat 走启发式）
	_net = null
	if FileAccess.file_exists(CHECKPOINT_PATH):
		var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				var net: RefCounted = PolicyNetScript.new()
				if net.from_dict(parsed.get("net", {})):
					_net = net
	# 号令节点：benchmark driver 的 ctx 无 tactical_orders 键，经 arena._game_root 解析
	var arena: Node = ctx.get("arena")
	var game_root: Node = arena.get("_game_root") if arena != null and "_game_root" in arena else null
	if game_root != null and game_root.has_method("get_tactical_orders"):
		_orders = game_root.get_tactical_orders()
	if game_root != null and game_root.has_method("get_formation_system"):
		_formation = game_root.get_formation_system()
	# 本方规划器除名（号令权归网络）；旗点直读 arena（bench_base.flags() 找不到 RefCounted 点）
	if arena != null and "_planners" in arena:
		var planners: Dictionary = arena.get("_planners")
		if planners != null and planners.has(_my_faction):
			planners.erase(_my_faction)
			# 惯例结算权在攻方那台：把它除名了就由本选手接手结算（每拍恰一次纪律不变）
			_drives_settlement = _my_faction == 1
	if arena != null and "_capture_points" in arena:
		_points = arena.get("_capture_points")
	_resolve_squads()


## 我方班解析（编制序 = 创建序，与训练侧一致；initial_n 用 setup 时点兵数）
func _resolve_squads() -> void:
	_squads = []
	if _formation == null or not _formation.has_method("get_all_squads"):
		return
	for sid_v in _formation.get_all_squads():
		var sid: String = str(sid_v)
		var mine: Array = []
		for u in _formation.get_squad_units(sid):
			if is_instance_valid(u) and u.has_method("get_faction") \
					and int(u.get_faction()) == _my_faction:
				mine.append(u)
		if not mine.is_empty():
			_squads.append({"id": sid, "units": mine, "initial_n": mine.size()})
		if _squads.size() >= 3:
			break


## 本地快照（自持防死：不走基类，过滤口径 = 未死即算，避战者算存活）
func _snap(units: Array) -> Array:
	var out: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		var hp_v: Variant = u.get_health() if u.has_method("get_health") else null
		# 阵亡单位的 HealthComponent 可能已释放：Variant 接 + is_instance_valid 防炸
		if hp_v == null or not is_instance_valid(hp_v) or hp_v.is_dead():
			continue
		out.append({
			"node": u,
			"pos": (u as Node2D).global_position,
			"hp_ratio": hp_v.get_health_ratio() if hp_v.has_method("get_health_ratio") else 1.0,
		})
	return out


## 本地名册（不走基类 my_units/enemy_units/effective_strength——基类 _alive_units
## 运行时错误会杀死整条 await 协程）。
## 返回指定阵营存活单位（溃逃布尔态已退役：未死即算，避战者算存活）。
func _roster_units(faction: int) -> Array:
	var battle_v: Variant = ctx.get("battle")
	if battle_v == null or not is_instance_valid(battle_v):
		return []
	var arr: Array = battle_v.get("_units_attacker" if faction == 1 else "_units_defender")
	if arr == null:
		return []
	var out: Array = []
	for u in arr:
		if not is_instance_valid(u):
			continue
		var hp_v: Variant = u.get_health() if u.has_method("get_health") else null
		if hp_v != null and is_instance_valid(hp_v) and hp_v.is_dead():
			continue
		out.append(u)
	return out


func _my_units() -> Array:
	return _roster_units(_my_faction)


func _foe_units() -> Array:
	return _roster_units(3 - _my_faction)


func tick(dt: float) -> void:
	_beat_acc += dt
	if _beat_acc < BEAT:
		return
	_beat_acc -= BEAT
	# 班解析重试（arena 编班在开战同帧后才完成；setup 时可能扑空）
	if _squads.is_empty() and _formation != null:
		_resolve_squads()
	# 结算接手（若本方是被除名的攻方结算权规划器）
	if _drives_settlement:
		_drive_capture_settlement()
	if _orders == null or _formation == null or _squads.is_empty():
		return
	var intents := _decide()
	_apply_intents(intents)


## 夺点结算（同规划器口径：半径内各方人数喂点，每拍一次；
## 阵营键按战斗域 1/2 映射——本方未必是攻方）
func _drive_capture_settlement() -> void:
	for p in _points:
		var counts: Dictionary = {}
		counts[_my_faction] = _count_in_radius(_my_units(), p)
		counts[3 - _my_faction] = _count_in_radius(_foe_units(), p)
		p.tick(BEAT, counts)


func _count_in_radius(units: Array, p) -> int:
	var n: int = 0
	for u in units:
		if is_instance_valid(u) and (u as Node2D).global_position.distance_to(p.get_position()) <= p.get_radius():
			n += 1
	return n


## 决策：观察编码（与训练侧 battle_env._encode_obs 逐位一致）→ 前向 → argmax。
## 网络缺失 → 启发式（近战班攻最近旗、全员接敌）。
func _decide() -> Array:
	var intents: Array = [2, 2, 4]
	if _net != null:
		var logits: PackedFloat32Array = _net.forward(_encode_obs())
		var actions: PackedInt32Array = _net.greedy_actions(logits, _active_mask())
		intents = [actions[0], actions[1], actions[2]]
	_last_intents = intents.duplicate()
	return intents


func _active_mask() -> PackedInt32Array:
	var mask := PackedInt32Array()
	mask.resize(3)
	for si in _squads.size():
		mask[si] = 1 if not _alive_of(_squads[si]["units"]).is_empty() else 0
	return mask


func _alive_of(units: Array) -> Array:
	var out: Array = []
	for u in units:
		if is_instance_valid(u):
			var hp_v: Variant = u.get_health() if u.has_method("get_health") else null
			if hp_v != null and is_instance_valid(hp_v) and not hp_v.is_dead():
				out.append(u)
	return out


## 57 维观察（布局与训练侧逐位一致；值域口径同）
func _encode_obs() -> PackedFloat32Array:
	var obs := PackedFloat32Array()
	obs.resize(_net.INPUT_DIM)
	var my_alive: Array = _my_units()
	var foe_alive: Array = _foe_units()
	var my_snap: Array = _snap(my_alive)
	var foe_snap: Array = _snap(foe_alive)
	var my_init: int = 0
	for sq in _squads:
		my_init += int(sq["initial_n"])
	var foe_init: int = maxi(_foe_units().size(), 1)
	obs[0] = _n01(float(my_alive.size()) / float(maxi(my_init, 1)))
	obs[1] = _n01(float(foe_alive.size()) / float(foe_init))
	obs[2] = clampf(float(my_alive.size()) / float(maxi(my_alive.size() + foe_alive.size(), 1)) * 2.0 - 1.0, -1.0, 1.0)
	obs[3] = _n01(_avg_hp(my_snap))
	obs[4] = _n01(_avg_hp(foe_snap))
	var battle_v: Variant = ctx.get("battle")
	var dur: float = float(battle_v.get_duration()) if battle_v != null and is_instance_valid(battle_v) and battle_v.has_method("get_duration") else 0.0
	obs[5] = clampf(1.0 - dur / TIME_LIMIT, 0.0, 1.0)
	# 旗块
	var my_centroid := _centroid_of(my_snap)
	for fi in 3:
		if fi >= _points.size():
			break
		var p = _points[fi]
		var base: int = 6 + fi * 7
		obs[base] = 1.0 if p.get_owner_faction() == _my_faction else 0.0
		obs[base + 1] = 1.0 if p.get_owner_faction() == 3 - _my_faction else 0.0
		obs[base + 2] = 1.0 if p.get_owner_faction() == 0 else 0.0
		obs[base + 3] = _n01(p.get_progress() / 100.0)
		obs[base + 4] = _n01(_count_in_radius_snap(my_snap, p) / float(maxi(my_snap.size(), 1)))
		obs[base + 5] = _n01(_count_in_radius_snap(foe_snap, p) / float(maxi(foe_snap.size(), 1)))
		obs[base + 6] = _n01(my_centroid.distance_to(p.get_position()) / 2500.0)
	# 班块（自视角镜像位置；上拍意图 one-hot）
	for si in _squads.size():
		var sq: Dictionary = _squads[si]
		var base: int = 27 + si * 8
		var alive: Array = _alive_of(sq["units"])
		var snap: Array = _snap(alive)
		var centroid := _centroid_of(snap)
		var mr: float = _mir * (centroid.x - _mid_x()) if not snap.is_empty() else 0.0
		obs[base] = clampf(mr / 2000.0, -1.0, 1.0)
		obs[base + 1] = clampf((centroid.y - _spawn_y()) / 400.0, -1.0, 1.0) if not snap.is_empty() else 0.0
		obs[base + 2] = _n01(float(snap.size()) / float(maxi(int(sq["initial_n"]), 1)))
		obs[base + 3] = _n01(_avg_hp(snap))
		obs[base + 4] = _n01(_nearest_enemy_dist(snap, foe_snap) / 1500.0)
		for a in 5:
			obs[base + 5 + a] = 1.0 if int(_last_intents[si]) == a else 0.0
	return obs


func _mid_x() -> float:
	var battle_v: Variant = ctx.get("battle")
	if battle_v != null and is_instance_valid(battle_v) and battle_v.get("_map") != null:
		var m: Node2D = battle_v.get("_map")
		return (m.map_left + m.map_right) * 0.5
	return 0.0


func _spawn_y() -> float:
	var battle_v: Variant = ctx.get("battle")
	if battle_v != null and is_instance_valid(battle_v) and battle_v.get("_map") != null:
		var m: Node2D = battle_v.get("_map")
		return (m.ground_y + m.ground_bottom) * 0.5
	return 0.0


func _centroid_of(snap: Array) -> Vector2:
	if snap.is_empty():
		return Vector2(_mid_x(), _spawn_y())
	var sum := Vector2.ZERO
	for s_v in snap:
		sum += s_v["pos"]
	return sum / float(snap.size())


func _avg_hp(snap: Array) -> float:
	if snap.is_empty():
		return 1.0
	var s: float = 0.0
	for s_v in snap:
		s += float(s_v["hp_ratio"])
	return s / float(snap.size())


func _nearest_enemy_dist(my_snap: Array, foe_snap: Array) -> float:
	if my_snap.is_empty() or foe_snap.is_empty():
		return 3000.0
	var best: float = INF
	for m_v in my_snap:
		for f_v in foe_snap:
			best = minf(best, (m_v["pos"] as Vector2).distance_to(f_v["pos"]))
	return best


func _count_in_radius_snap(snap: Array, p) -> int:
	var n: int = 0
	for s_v in snap:
		if (s_v["pos"] as Vector2).distance_to(p.get_position()) <= p.get_radius():
			n += 1
	return n


func _n01(v: float) -> float:
	return clampf(v, 0.0, 1.0)


## 意图 → 号令（与训练侧 _apply_intents 同参节流：漂移重发 / 到位 HOLD / 定期刷新）
func _apply_intents(intents: Array) -> void:
	for si in _squads.size():
		var sq: Dictionary = _squads[si]
		var alive: Array = _alive_of(sq["units"])
		if alive.is_empty():
			continue
		var intent: int = int(intents[si])
		var centroid := _centroid_of(_snap(alive))
		var target := Vector2.ZERO
		var use_hold: bool = false
		match intent:
			0, 1, 2:
				target = _flag_pos_selfview(intent)
			3:
				var g := _nearest_owned_flag(centroid)
				if g.x != INF:
					target = g
					if centroid.distance_to(target) <= GARRISON_ARRIVE_DIST:
						use_hold = true
				else:
					target = _flag_pos_selfview(1)
			_:
				target = _nearest_enemy_centroid(centroid)
		var key := str(si)
		var prev: Dictionary = _order_state.get(key, {})
		var last_pos := Vector2(float(prev.get("tx", INF)), float(prev.get("ty", INF)))
		var drifted: bool = last_pos.distance_to(target) > ORDER_EPS_DIST
		var refresh: bool = int(prev.get("beats", ORDER_REFRESH_BEATS)) >= ORDER_REFRESH_BEATS
		var changed: bool = int(prev.get("intent", -1)) != intent
		if use_hold:
			if int(prev.get("holding", 0)) != 1:
				_orders.issue(OrdersScript.OrderType.HOLD_POSITION, String(sq["id"]), Vector2.ZERO, 0)
				_order_state[key] = {"intent": intent, "tx": target.x, "ty": target.y, "beats": 0, "holding": 1}
			else:
				_order_state[key]["beats"] = int(_order_state[key]["beats"]) + 1
			continue
		if changed or drifted or refresh or prev.is_empty():
			_orders.issue(OrdersScript.OrderType.ADVANCE_ALL, String(sq["id"]), target, 0)
			_order_state[key] = {"intent": intent, "tx": target.x, "ty": target.y, "beats": 0, "holding": 0}
		else:
			_order_state[key]["beats"] = int(prev.get("beats", 0)) + 1


## 自视角第 idx 面旗（镜像 x 升序 = 本方左→右）
func _flags_selfview() -> Array:
	var sorted := _points.duplicate()
	sorted.sort_custom(func(a, b):
		return _mir * a.get_position().x < _mir * b.get_position().x)
	return sorted


func _flag_pos_selfview(idx: int) -> Vector2:
	var sorted := _flags_selfview()
	if sorted.is_empty():
		return Vector2(_mid_x(), _spawn_y())
	return (sorted[clampi(idx, 0, sorted.size() - 1)] as Object).get_position()


func _nearest_owned_flag(from: Vector2) -> Vector2:
	var best := Vector2(INF, INF)
	var best_d: float = INF
	for p in _points:
		if p.get_owner_faction() != _my_faction:
			continue
		var d: float = from.distance_to(p.get_position())
		if d < best_d:
			best_d = d
			best = p.get_position()
	return best


func _nearest_enemy_centroid(from: Vector2) -> Vector2:
	var foe_snap: Array = _snap(_foe_units())
	if foe_snap.is_empty():
		return Vector2(_mid_x(), _spawn_y())
	var best: Vector2 = foe_snap[0]["pos"]
	var best_d: float = INF
	for s_v in foe_snap:
		var d: float = from.distance_to(s_v["pos"])
		if d < best_d:
			best_d = d
			best = s_v["pos"]
	return best
