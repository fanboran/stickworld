extends "res://tests/dev/benchmark_brains/bench_brain_base.gd"
## NN 指挥官选手 —— 把自博弈 RL checkpoint 装成 Benchmark 选手（v2 契约）。
##
## 原理：观察走 bench_brain_base 协议（观察面全开：单位/血量/旗点只读），决策走
## policy_net 前向（argmax 贪心，零采样），号令走 TacticalOrders 既有通道——观察
## 编码/动作词汇与 rl_core C++ 训练核 v2 定稿**逐位同构**：
##   - 观察 125 维（全局 6 + 旗 3×7 + 班 8×10 + 排 4×4 + 指挥官 2），布局表
##     = addons/rl_core/README.md / rl_env.h 头注释；回落语义照 C++ observe() 源码：
##       空班/全灭班位置·计数·均血置 0、意图 one-hot 全 0（li=−1），近敌距照算且
##       空班/空敌班质心回落 (mid_x, spawn_y)，距离超 3000 夹 3000；
##       空排全 0；排长阵亡位置置 0 只留存活标志 0；指挥官阵亡血量比 → 0。
##   - 动作 8 班 × 5 意图（攻左/中/右旗·自视角 / 驻防最近己旗 / 接敌推进），
##     空班跳过不下令；真实战场班数可能少于 8（16/48 档），空槽照 C++ 回落编码。
##   - 指挥官块 [123..124] 按 **side 下标** 写入（[123]=faction1 指挥官、
##     [124]=faction2 指挥官）——与过门的 C++ observe() / gdscript_mirror 对拍
##     实现同口径（README 表内"己方/敌方"措辞是笔误，代码即真相）。
## 对手 = 场上另一侧的内嵌军师规划器 / 旧指挥。
##
## 接线细节（battle_arena 场景内）：
##   - 本方规划器除名（arena._planners.erase，同 incumbent_teamai_brain 手法）——
##     号令权归网络，防双脑互覆；
##   - 若本方恰是被除名的"结算权规划器"（惯例 = 攻方那台 drives_settlement=true），
##     本选手接手夺点占领结算 tick（每拍喂半径人数）——结算每拍只准一次的纪律不变；
##   - 无 checkpoint / 维度非 v2 → 退化启发式（前两班攻右旗、其余接敌），保证对打不出错。
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
## v2 契约维度（布局表 = rl_env.h observe()；与 addons/rl_core/README.md 同源）
const OBS_DIM: int = 125
const N_SQUADS: int = 8
const N_PLATOONS: int = 4
const N_INTENTS: int = 5
## 旗块/班块/排层在观察向量中的段偏移
const FLAG_BASE: int = 6
const SQUAD_BASE: int = 27
const PLATOON_BASE: int = 107
const COMMANDER_BASE: int = 123
## checkpoint 路径（rl_core C++ 训练循环落档处，训练中持续更新）
const CHECKPOINT_PATH: String = "user://rl/checkpoint_cpp.json"

## 网络（checkpoint 加载失败 / 非 v2 维度 = null → 启发式退化）
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
## 我方班（编制槽序 0..7）：[{id, units, initial_n}]
var _squads: Array = []
## 敌方班（编制槽序 0..7）：[{id, units, initial_n}]（观察编码用）
var _foe_squads: Array = []
## 我方排（槽序 0..3）：[{pid, squad_slots: Array[int]}]（squad_slots = 班槽下标）
var _platoons: Array = []
## 双方指挥官（faction 1/2 → 单位；观察 [123..124] 用）
var _commanders: Dictionary = {}
## 每拍状态：节拍累积 / 上拍意图（8 槽，−1 = 未下令 = one-hot 全 0）/ 号令节流
var _beat_acc: float = 0.0
var _last_intents: Array = []
var _order_state: Dictionary = {}


func _init() -> void:
	_last_intents.resize(N_SQUADS)
	_last_intents.fill(-1)


func brain_name() -> String:
	return "NN指挥官v2" + ("(checkpoint)" if _net != null else "(启发式退化)")


func setup() -> void:
	_my_faction = int(ctx.faction) + 1
	_mir = 1.0 if _my_faction == 1 else -1.0
	# 网络：v2 checkpoint 装载（缺失/维度非 125→64→40 → null，beat 走启发式）
	_net = null
	if FileAccess.file_exists(CHECKPOINT_PATH):
		var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				var net: RefCounted = PolicyNetScript.new()
				if net.from_dict(parsed.get("net", {})) \
						and int(net.input_dim) == OBS_DIM and int(net.out_dim) == N_SQUADS * N_INTENTS:
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
	# 指挥官（观察 [123..124] 用）：直读 arena 登记表
	if arena != null and "_arena_commanders" in arena:
		var cmds: Dictionary = arena.get("_arena_commanders")
		if cmds != null:
			_commanders = cmds
	_resolve_squads()


## 双方班解析（编制槽序 = 创建序，与训练侧一致；initial_n 用 setup 时点兵数）。
## 真实战场班数可能少于 8（16/48 档 = 2/4 班）——空槽不占 _squads，
## 观察编码时按槽序补零（照 C++ 空班回落语义）。
func _resolve_squads() -> void:
	_squads = []
	_foe_squads = []
	_platoons = []
	if _formation == null or not _formation.has_method("get_all_squads"):
		return
	for sid_v in _formation.get_all_squads():
		var sid: String = str(sid_v)
		var mine: Array = []
		var foe: Array = []
		for u in _formation.get_squad_units(sid):
			if not is_instance_valid(u) or not u.has_method("get_faction"):
				continue
			var fac: int = int(u.get_faction())
			if fac == _my_faction:
				mine.append(u)
			elif fac == 3 - _my_faction:
				foe.append(u)
		if not mine.is_empty():
			_squads.append({"id": sid, "units": mine, "initial_n": mine.size()})
		if not foe.is_empty():
			_foe_squads.append({"id": sid, "units": foe, "initial_n": foe.size()})
	# 班槽上限守卫（编制定稿最多 8 班；超出忽略防越界）
	if _squads.size() > N_SQUADS:
		_squads.resize(N_SQUADS)
	if _foe_squads.size() > N_SQUADS:
		_foe_squads.resize(N_SQUADS)
	# 我方排解析（formation 排序 = 创建序；排内班映射回我方班槽下标）
	if not _formation.has_method("get_all_platoons"):
		return
	var slot_of: Dictionary = {}
	for si in _squads.size():
		slot_of[str(_squads[si]["id"])] = si
	for pid_v in _formation.get_all_platoons():
		var pid: String = str(pid_v)
		var slots: Array = []
		for sid_v in _formation.get_platoon_squads(pid):
			var sid := str(sid_v)
			if slot_of.has(sid):
				slots.append(int(slot_of[sid]))
		if not slots.is_empty():
			_platoons.append({"pid": pid, "squad_slots": slots})
			if _platoons.size() >= N_PLATOONS:
				break


## 本地快照（自持防死：不走基类，过滤口径 = 未死即算，避战者算存活）。
## 值域：node / pos / hp_ratio；rank（军衔，缺省 0——指挥官过滤用）。
func _snap(units: Array, soldiers_only: bool = false) -> Array:
	var out: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		var hp_v: Variant = u.get_health() if u.has_method("get_health") else null
		# 阵亡单位的 HealthComponent 可能已释放：Variant 接 + is_instance_valid 防炸
		if hp_v == null or not is_instance_valid(hp_v) or hp_v.is_dead():
			continue
		if soldiers_only and _rank_of(u) >= 3:
			continue  # 指挥官（rank3）不进士兵统计——与 C++ observe() 同口径
		out.append({
			"node": u,
			"pos": (u as Node2D).global_position,
			"hp_ratio": hp_v.get_health_ratio() if hp_v.has_method("get_health_ratio") else 1.0,
		})
	return out


## 单位军衔（stickman_entity.rank 字段；桩无字段走 meta 兜底，同 formation 口径）
func _rank_of(u: Node) -> int:
	var v: Variant = u.get("rank")
	if v == null and u.has_meta("rank"):
		v = u.get_meta("rank")
	return int(v) if v != null else 0


## 本地名册（不走基类 my_units/enemy_units/effective_strength——基类 _alive_units
## 运行时错误会杀死整条 await 协程）。
## 返回指定阵营存活单位（含指挥官——结算计数用；士兵统计走 _snap(soldiers_only)）。
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


## 决策：观察编码（v2 125 维，与 rl_core observe() 逐位同构）→ 前向 → argmax。
## 网络缺失 → 启发式（前两班攻右旗、其余接敌）。
## 意图登记照 C++ step() 口径：只对存活班更新 _last_intents——全灭班冻结在
## 阵亡前的值、从未存在的槽保持 −1（观察 one-hot 全 0，无假信号）。
func _decide() -> Array:
	var intents: Array = []
	intents.resize(N_SQUADS)
	intents.fill(-1)
	var mask := _active_mask()
	if _net != null:
		var logits: PackedFloat32Array = _net.forward(_encode_obs())
		var actions: PackedInt32Array = _net.greedy_actions(logits, mask)
		for si in N_SQUADS:
			intents[si] = int(actions[si])
	else:
		for si in _squads.size():
			intents[si] = 2 if si < 2 else 4
	for si in N_SQUADS:
		if si < mask.size() and int(mask[si]) == 1:
			_last_intents[si] = int(intents[si])
	return intents


## 活动掩码（8 槽；空班/全灭班 = 0——采样/greedy 跳过，不吃号令）
func _active_mask() -> PackedInt32Array:
	var mask := PackedInt32Array()
	mask.resize(N_SQUADS)
	for si in _squads.size():
		mask[si] = 1 if not _snap(_squads[si]["units"], true).is_empty() else 0
	return mask


## 槽位班快照（越槽/全灭 → 空数组）
func _slot_snap(squads: Array, si: int) -> Array:
	if si >= squads.size():
		return []
	return _snap(squads[si]["units"], true)


## v2 125 维观察（布局与 rl_core observe() 逐位同构；值域口径同；
## 存活统计 = 士兵（rank<3）不含指挥官）
func _encode_obs() -> PackedFloat32Array:
	var obs := PackedFloat32Array()
	obs.resize(OBS_DIM)
	var my_sold: Array = _snap(_my_units(), true)
	var foe_sold: Array = _snap(_foe_units(), true)
	var my_init: int = 0
	var foe_init: int = 0
	for sq in _squads:
		my_init += int(sq["initial_n"])
	for sq in _foe_squads:
		foe_init += int(sq["initial_n"])
	# ── 全局块 [0..5]（存活统计不含指挥官；空军均血 = 0，照 C++）──
	obs[0] = _n01(float(my_sold.size()) / float(maxi(my_init, 1)))
	obs[1] = _n01(float(foe_sold.size()) / float(maxi(foe_init, 1)))
	obs[2] = clampf(float(my_sold.size()) / float(maxi(my_sold.size() + foe_sold.size(), 1)) * 2.0 - 1.0, -1.0, 1.0)
	obs[3] = _n01(_avg_hp(my_sold))
	obs[4] = _n01(_avg_hp(foe_sold))
	var battle_v: Variant = ctx.get("battle")
	var dur: float = float(battle_v.get_duration()) if battle_v != null and is_instance_valid(battle_v) and battle_v.has_method("get_duration") else 0.0
	obs[5] = clampf(1.0 - dur / TIME_LIMIT, 0.0, 1.0)
	# 己方全军质心（士兵；空军回落 (mid_x, spawn_y) 照 C++/镜像编码器）
	var mid_x := _mid_x()
	var spawn_y := _spawn_y()
	var my_centroid := _centroid_of(my_sold, mid_x, spawn_y)
	# ── 旗块 [6..26]：自视角左中右 = 镜像 x 升序，stride 7 ──
	var flags_sorted := _flags_selfview()
	for fi in 3:
		if fi >= flags_sorted.size():
			break  # 旗点缺失（夺点未接线）：余段保持 0
		var p = flags_sorted[fi]
		var base: int = FLAG_BASE + fi * 7
		var owner_f: int = int(p.get_owner_faction())
		obs[base] = 1.0 if owner_f == _my_faction else 0.0
		obs[base + 1] = 1.0 if owner_f == 3 - _my_faction else 0.0
		obs[base + 2] = 1.0 if owner_f == 0 else 0.0
		obs[base + 3] = _n01(p.get_progress() / 100.0)
		obs[base + 4] = _n01(_count_near_snap(my_sold, p) / float(maxi(my_sold.size(), 1)))
		obs[base + 5] = _n01(_count_near_snap(foe_sold, p) / float(maxi(foe_sold.size(), 1)))
		obs[base + 6] = _n01(my_centroid.distance_to(p.get_position()) / 2500.0)
	# ── 班块 [27..106]：8 槽编制序 stride 10；空班/空敌班质心回落 (mid_x, spawn_y)，
	#    近敌距照算、超 3000 夹 3000（照 C++ observe()）──
	var my_cx: Array = []
	var my_cy: Array = []
	var my_alive_n: Array = []
	var my_hp_avg: Array = []
	for si in N_SQUADS:
		var snap := _slot_snap(_squads, si)
		if snap.is_empty():
			my_cx.append(mid_x)
			my_cy.append(spawn_y)
		else:
			var c := _centroid_of(snap, mid_x, spawn_y)
			my_cx.append(c.x)
			my_cy.append(c.y)
		my_alive_n.append(snap.size())
		my_hp_avg.append(_avg_hp(snap))
	var foe_cx: Array = []
	var foe_cy: Array = []
	for si in N_SQUADS:
		var snap2 := _slot_snap(_foe_squads, si)
		if snap2.is_empty():
			foe_cx.append(mid_x)
			foe_cy.append(spawn_y)
		else:
			var c2 := _centroid_of(snap2, mid_x, spawn_y)
			foe_cx.append(c2.x)
			foe_cy.append(c2.y)
	for si in N_SQUADS:
		var base: int = SQUAD_BASE + si * 10
		var init_n: int = int(_squads[si]["initial_n"]) if si < _squads.size() else 0
		if my_alive_n[si] > 0:
			obs[base] = clampf(_mir * (my_cx[si] - mid_x) / 2000.0, -1.0, 1.0)
			obs[base + 1] = clampf((my_cy[si] - spawn_y) / 400.0, -1.0, 1.0)
		obs[base + 2] = _n01(float(my_alive_n[si]) / float(maxi(init_n, 1)))
		obs[base + 3] = _n01(my_hp_avg[si])
		var best: float = 3000.0
		for fs in N_SQUADS:
			var d: float = Vector2(my_cx[si], my_cy[si]).distance_to(Vector2(foe_cx[fs], foe_cy[fs]))
			if d < best:
				best = d
		obs[base + 4] = _n01(minf(best, 3000.0) / 1500.0)
		var li: int = int(_last_intents[si])
		if li >= 0 and li < N_INTENTS:
			obs[base + 5 + li] = 1.0
	# ── 排层 [107..122]：4 槽 stride 4；空排全 0；排长阵亡位置置 0 只留存活标志 0 ──
	for p in _platoons.size():
		if p >= N_PLATOONS:
			break
		var pl: Dictionary = _platoons[p]
		var base: int = PLATOON_BASE + p * 4
		var officer: Node = _formation.get_platoon_leader(str(pl["pid"])) \
				if _formation.has_method("get_platoon_leader") else null
		if officer != null and is_instance_valid(officer):
			var hp_v: Variant = officer.get_health() if officer.has_method("get_health") else null
			if hp_v != null and is_instance_valid(hp_v) and not hp_v.is_dead():
				obs[base] = 1.0
				obs[base + 1] = clampf(_mir * ((officer as Node2D).global_position.x - mid_x) / 2000.0, -1.0, 1.0)
				obs[base + 2] = clampf(((officer as Node2D).global_position.y - spawn_y) / 400.0, -1.0, 1.0)
		# 排存活比 = 排内班存活和 / 初始和（照 C++：排长阵亡仍照算）
		var ini: int = 0
		var alv: int = 0
		for slot_v in pl["squad_slots"]:
			var slot: int = int(slot_v)
			ini += int(_squads[slot]["initial_n"]) if slot < _squads.size() else 0
			alv += int(my_alive_n[slot])
		obs[base + 3] = _n01(float(alv) / float(maxi(ini, 1)))
	# ── 指挥官 [123..124]：按 side 下标（[123]=faction1 / [124]=faction2），
	#    过门实现口径；阵亡 → 0（斩首即终局）──
	for f in [1, 2]:
		var cmd: Variant = _commanders.get(f)
		if cmd == null or not is_instance_valid(cmd):
			continue
		var hp2: Variant = cmd.get_health() if cmd.has_method("get_health") else null
		if hp2 == null or not is_instance_valid(hp2) or hp2.is_dead():
			continue
		obs[COMMANDER_BASE + f - 1] = _n01(hp2.get_health_ratio() if hp2.has_method("get_health_ratio") else 1.0)
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


## 质心（空快照回落 (fallback_x, fallback_y)——照 C++ 空班回落语义）
func _centroid_of(snap: Array, fallback_x: float, fallback_y: float) -> Vector2:
	if snap.is_empty():
		return Vector2(fallback_x, fallback_y)
	var sum := Vector2.ZERO
	for s_v in snap:
		sum += s_v["pos"]
	return sum / float(snap.size())


## 均血（空快照 = 0，照 C++ `my_alive > 0 ? my_hp/my_alive : 0.0`——旧版 1.0 已废弃）
func _avg_hp(snap: Array) -> float:
	if snap.is_empty():
		return 0.0
	var s: float = 0.0
	for s_v in snap:
		s += float(s_v["hp_ratio"])
	return s / float(snap.size())


func _count_near_snap(snap: Array, p) -> int:
	var n: int = 0
	for s_v in snap:
		if (s_v["pos"] as Vector2).distance_to(p.get_position()) <= p.get_radius():
			n += 1
	return n


func _n01(v: float) -> float:
	return clampf(v, 0.0, 1.0)


## 意图 → 号令（与训练侧 _apply_intents 同参节流：漂移重发 / 到位 HOLD / 定期刷新）。
## 8 班 × 5 意图逐槽解包；空班/全灭班跳过不下令（同 active_mask=0）。
func _apply_intents(intents: Array) -> void:
	for si in _squads.size():
		var sq: Dictionary = _squads[si]
		var alive: Array = _snap(sq["units"], true)
		if alive.is_empty():
			continue
		var intent: int = int(intents[si])
		var centroid := _centroid_of(alive, _mid_x(), _spawn_y())
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
	var foe_snap: Array = _snap(_foe_units(), true)
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
