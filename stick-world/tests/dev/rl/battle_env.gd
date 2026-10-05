extends Node
## 自博弈战斗环境 —— RL 训练的战场侧（观察场 AI 训练设施 v1）。
##
## 职责：随机对阵生成 → 编程造战（不走 battle_arena 场景，无 TeamAi / 无意图规划器，
## 网络是唯一指挥官）→ 观察编码（全特征"己方视角"镜像化）→ 动作翻译下发 →
## 夺点结算 tick → 终局奖励素材收集。造战模式参照 tests/integration/test_battle_retreat.gd
## 的 _setup_battle（map.spawn_entity + start_test_battle）。
##
## 训练协议（创始人 2026-09-30 修正版）：每轮迭代随机抽一个对阵（双方兵种比例与
## 占位独立随机、可不对称），打正反两局（第二局交换双方编制与点位），四份指挥视角
## 一起进同一个梯度批——从制度上防过拟合对称战斗/特定一侧。
##
## 动作词汇（每班 5 意图，与 squad_intent_planner 的宏观词汇同构）：
##   0 攻左旗（自视角）/ 1 攻中旗 / 2 攻右旗 / 3 驻防己方最近旗 / 4 接敌推进
## 自视角 = 镜像坐标：本方永远"从左往右打"（faction 1 天然如此，faction 2 取负镜像），
## 同一网络不区分攻守两侧。
##
## Agent 协议（鸭子，trainer 注入）：
##   beat(dt, view) -> PackedInt32Array   每决策节拍一次；返回 3 班意图（空数组 = 不下令，
##                                        评估侧军师规划器自行经 TacticalOrders 下令）
##   view = {faction, obs, active_mask, squad_ids}（planner 不消费 obs）
##
## 观察编码（57 维，全部 [−1,1] 附近的归一值）：
##   [0..5]   全局：己存活比 / 敌存活比 / 兵力比 / 己均血 / 敌均血 / 剩余时间
##   [6..26]  每旗 ×3（自视角左中右）：归属 one-hot(3) + 进度 + 己近旗人数比 +
##            敌近旗人数比 + 己方质心距
##   [27..56] 每班 ×3（编制序）：镜像位置(2) + 存活比 + 均血 + 最近敌距 + 上拍意图 one-hot(5)
##
## 热路径纪律：每物理帧只累加浮点；Dictionary/Array 分配只发生在 0.5s 决策节拍与
## 开局/收尾（低频），符合"战斗 tick 内不分配"的口径。

const TacticsAPI: GDScript = preload("res://modules/tactics/api.gd")
const OrdersScript: GDScript = preload("res://modules/tactics/scripts/tactical_orders.gd")
const GAME_ROOT_SCENE: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

# ─────────────────────────────── 环境常量 ────────────────────────────────
## 物理帧步长（游戏秒；battle_instance 同口径累加，硬超时/节拍全用它）
const DT: float = 1.0 / 60.0
## 决策/结算节拍（游戏秒，与 SquadIntentPlanner.BEAT_INTERVAL 同拍）
const BEAT: float = 0.5
## 战斗硬超时（游戏秒；duration_limit 到点 battle 自行按剩余兵力判胜）
const BATTLE_TIME_LIMIT: float = 125.0
## 观察向量维度（与 policy_net.INPUT_DIM 一致：6 + 7×3 + 10×3）
const OBS_DIM: int = 57
## 班数（先锋/中坚/火力）
const N_SQUADS: int = 3
## 每班意图数
const N_ACTIONS: int = 5
## 兵种池（对齐 WeaponMount.WeaponType：0 剑 1 矛 2 弓 4 杖 5 祭司；镐 3 不参战）
const WEAPON_POOL: PackedInt32Array = [1, 0, 2, 4, 5]
## 班语义（编制序 = 先锋/中坚/火力；每兵种按此比例拆班）
const SQUAD_NAMES: Array = ["先锋班", "中坚班", "火力班"]
const SQUAD_SPLIT: PackedFloat32Array = [0.45, 0.35, 0.20]
## 兵力档（整十口径）与不对称幅度
const ARMY_TIERS: PackedInt32Array = [16, 32, 48]
const SIDE_SPLIT_MIN: float = 0.35
const SIDE_SPLIT_MAX: float = 0.65
## 旗点几何（对称三旗：中线 ±500，y 错开 ±200；半径同 battle_arena 口径）
const FLAG_RADIUS: float = 180.0
const FLAG_X_SPREAD: float = 500.0
const FLAG_Y_OFFSET: float = 200.0
## 出生带（相对中线；攻守镜像）与班内散布
const BAND_X_MIN: float = 900.0
const BAND_X_MAX: float = 1500.0
const SIDE_Y_JITTER: float = 350.0
const SQUAD_X_JITTER: float = 250.0
const SQUAD_Y_JITTER: float = 250.0
const UNIT_X_GAP: float = 110.0
const UNIT_Y_GAP: float = 90.0
const PER_ROW: int = 8
## 行走带上下安全边距（出生 y 夹紧）
const BAND_MARGIN: float = 80.0
## 驻防到位判定距离（px；到位后转 HOLD_POSITION 原地坚守）
const GARRISON_ARRIVE_DIST: float = 60.0
## 号令重发阈值（px：目标点漂移超此值才重发，防号令风暴）
const ORDER_EPS_DIST: float = 80.0
## 号令定期刷新（节拍数：约 3s 重发一次，接战脱战后能重新领令）
const ORDER_REFRESH_BEATS: int = 6

# ─────────────────────────────── 运行时 ────────────────────────────────
## game_root 宿主（本 env 持有，一次装配反复用）
var _game_root: Node = null
## 当前地图
var _map: Node2D = null
## battle_settled 捕获（最新一场的结算摘要；env 自连 EventBus）
var _last_summary: Dictionary = {}
## 本场状态（play_battle 期间有效）
var _battle: Node = null
var _mid_x: float = 0.0
var _spawn_y: float = 0.0
var _band_top: float = 0.0
var _band_bottom: float = 0.0
## faction(1/2) -> {"squads": Array[{id, units, initial_n}], "units": Array}
var _side: Dictionary = {}
## 旗点实例（CapturePoint；每场重建）
var _flags: Array = []
## 游戏时间（秒）与节拍累积器
var _t: float = 0.0
var _beat_acc: float = 0.0
## 号令节流状态：faction -> squad_idx -> {intent, tx, ty, beats}
var _order_state: Dictionary = {}


func _ready() -> void:
	if EventBus != null and EventBus.has_signal("battle_settled"):
		EventBus.battle_settled.connect(_on_battle_settled)


func _on_battle_settled(_battle_id: String, summary: Dictionary) -> void:
	_last_summary = summary


# ─────────────────────────────── 装配（一次）────────────────────────────────

## 装配 game_root + 等 battlefield 开机 + 清场。必须先 await 完成才能开打。
func setup_async() -> bool:
	_game_root = GAME_ROOT_SCENE.instantiate()
	_game_root.set("boot_map_id_override", "battlefield")
	add_child(_game_root)
	# 等世界开机（battle_arena 同款探测：_boot_world_phase 落 false 且地图就绪）
	for i in 3600:
		await get_tree().process_frame
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			break
	_map = _game_root.get_current_map()
	if _map == null:
		push_error("[BattleEnv] 战场图开机失败（3600 帧内无地图）")
		return false
	# 清掉地图自带单位（开图即刷的玩家实体等），保证战场只有 env 自己刷的兵
	for e in _map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 5:
		await get_tree().process_frame
	_mid_x = (_map.map_left + _map.map_right) * 0.5
	_spawn_y = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	_band_top = _map.ground_y + BAND_MARGIN
	_band_bottom = _map.ground_bottom - BAND_MARGIN
	print("[BattleEnv] 战场就绪：mid_x=%.0f spawn_y=%.0f band=[%.0f, %.0f]" % [
		_mid_x, _spawn_y, _band_top, _band_bottom])
	return true


## 本方班号列表（编班后有效；评估侧规划器构造用）
func get_squad_ids(faction: int) -> Array:
	var out: Array = []
	for sq_v in _side.get(faction, {}).get("squads", []):
		out.append(String(sq_v["id"]))
	return out


## TacticalOrders 节点（评估侧军师规划器构造用）
func get_orders_node() -> Node:
	return _game_root.get_tactical_orders() if _game_root != null else null


## 单位快照 provider（评估侧军师规划器构造用；值拷贝 {pos, faction, squad_id}）
func make_unit_snapshot_provider() -> Callable:
	return Callable(self, "_unit_snapshot")


func _unit_snapshot() -> Array:
	var snap: Array = []
	for f in [1, 2]:
		var side: Dictionary = _side.get(f, {})
		for sq_v in side.get("squads", []):
			var sq: Dictionary = sq_v
			for u in sq["units"]:
				if _is_fighting(u):
					snap.append({"pos": (u as Node2D).global_position, "faction": f,
						"squad_id": String(sq["id"])})
	return snap


## 构造一台接入本 env 的军师意图规划器（评估协议对手；drives 恒 false——
## 占领结算权恒归 env 自己，规划器只决策下令）
func make_intent_planner(faction: int, squad_ids: Array) -> Object:
	var planner: Object = TacticsAPI.IntentPlanner.new()
	planner.setup(faction, _flags, squad_ids, get_orders_node(),
			make_unit_snapshot_provider(), false)
	return planner


# ─────────────────────────────── 随机对阵生成 ────────────────────────────────

## 随机抽一个对阵（双方兵种比例与占位独立随机、可不对称）。
## 返回 {total, side_a, side_b}；正局 a 攻西 / b 守东，反局整体交换（调用方传 swap）。
func gen_matchup(rng: RandomNumberGenerator) -> Dictionary:
	var total: int = ARMY_TIERS[rng.randi_range(0, ARMY_TIERS.size() - 1)]
	var split: float = rng.randf_range(SIDE_SPLIT_MIN, SIDE_SPLIT_MAX)
	var n_a: int = clampi(int(round(float(total) * split)), 6, total - 6)
	var n_b: int = total - n_a
	return {
		"total": total,
		"side_a": _gen_side_comp(rng, n_a),
		"side_b": _gen_side_comp(rng, n_b),
	}


## 一方编制：兵种 Dirichlet 风格配比（权重 randf()² 归一）→ 最大余数法摊人数 →
## 按 SQUAD_SPLIT 拆 3 班（空班允许，观察/梯度按 active mask 掉）→ 占位带与
## 班间错位一次抽定（正反局共用同一份，swap 时整体换边 = 制度性交换编制与点位）。
func _gen_side_comp(rng: RandomNumberGenerator, n_total: int) -> Dictionary:
	var weights: Array = []
	var wsum: float = 0.0
	for i in WEAPON_POOL.size():
		var w: float = pow(rng.randf(), 2.0)
		weights.append(w)
		wsum += w
	if wsum <= 0.0:
		wsum = 1.0
		weights[0] = 1.0
	# 最大余数法摊兵种人数（保总和 = n_total）
	var counts: Array = []
	var remainders: Array = []
	var allocated: int = 0
	for i in WEAPON_POOL.size():
		var exact: float = float(n_total) * float(weights[i]) / wsum
		var fl: int = int(floor(exact))
		counts.append(fl)
		remainders.append({"i": i, "r": exact - float(fl)})
		allocated += fl
	remainders.sort_custom(func(a, b): return a["r"] > b["r"])
	var extra: int = n_total - allocated
	for r_v in remainders:
		if extra <= 0:
			break
		counts[int(r_v["i"])] += 1
		extra -= 1
	# 拆 3 班（每兵种按比例下放，余数从头补；班内武器交错排，散兵线混编更自然）
	var squads: Array = []
	for si in N_SQUADS:
		squads.append({"name": SQUAD_NAMES[si], "weapons": []})
	for wi in WEAPON_POOL.size():
		var n_w: int = int(counts[wi])
		var sq_alloc: Array = []
		var sq_alloc_sum: int = 0
		for si in N_SQUADS:
			var e: int = int(floor(float(n_w) * float(SQUAD_SPLIT[si])))
			sq_alloc.append(e)
			sq_alloc_sum += e
		var left: int = n_w - sq_alloc_sum
		var si2: int = 0
		while left > 0:
			sq_alloc[si2 % N_SQUADS] += 1
			left -= 1
			si2 += 1
		for si in N_SQUADS:
			for k in int(sq_alloc[si]):
				squads[si]["weapons"].append(WEAPON_POOL[wi])
	# 占位（一次抽定）
	var comp: Dictionary = {
		"n_total": n_total,
		"band_x": rng.randf_range(BAND_X_MIN, BAND_X_MAX),
		"side_y": rng.randf_range(-SIDE_Y_JITTER, SIDE_Y_JITTER),
		"squads": squads,
	}
	for si in N_SQUADS:
		comp["squad_%d_x" % si] = rng.randf_range(-SQUAD_X_JITTER, SQUAD_X_JITTER)
		comp["squad_%d_y" % si] = rng.randf_range(-SQUAD_Y_JITTER, SQUAD_Y_JITTER)
	return comp


# ─────────────────────────────── 一场战斗 ────────────────────────────────

## 打一场。swap=false 正局（a 攻西/b 守东），swap=true 反局（编制与点位整体交换：
## b 攻西/a 守东）。agent1/agent2 = faction 1/2 的指挥官（协议见文件头）。
## 返回 {winner, alive, initial, flags_owned, duration, reason}——奖励素材，
## 视角换算（己/敌）由调用方按 faction 做。
func play_battle(matchup: Dictionary, swap: bool, agent1: Object, agent2: Object) -> Dictionary:
	var comp_att: Dictionary = matchup["side_b"] if swap else matchup["side_a"]
	var comp_def: Dictionary = matchup["side_a"] if swap else matchup["side_b"]
	var agents: Dictionary = {1: agent1, 2: agent2}
	_t = 0.0
	_beat_acc = 0.0
	_last_summary = {}
	_clear_battlefield()
	# 出生（攻方西/守方东镜像）+ 编班 + 布旗
	var attackers: Array = _spawn_side(comp_att, 1, false)
	var defenders: Array = _spawn_side(comp_def, 2, true)
	_make_squads(1, comp_att)
	_make_squads(2, comp_def)
	_setup_flags()
	for i in 2:
		await get_tree().process_frame
	# 开战（player_faction=1 仅影响 victory 语义，env 自己按 winner 结算）
	_battle = _game_root.start_test_battle(attackers, defenders, 1)
	if _battle == null:
		push_error("[BattleEnv] 战斗创建失败（iteration 战局作废）")
		_cleanup_battle()
		return {"winner": 0, "alive": {1: 0, 2: 0}, "initial": {1: 1, 2: 1},
			"flags_owned": {1: 0, 2: 0}, "duration": 0.0, "reason": "error"}
	# 开战自动暂停豁免 + 相持硬超时（到点 battle 自行按剩余兵力判胜）
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	_battle.set("duration_limit", BATTLE_TIME_LIMIT)
	_order_state = {1: {}, 2: {}}
	# 挂接 agent（评估侧规划器须在旗点/编班就绪后才能装配；鸭子可选实现）
	for f in [1, 2]:
		var agent: Object = agents.get(f)
		if agent != null and agent.has_method("attach"):
			agent.attach(self, f)
	# 主循环：以 battle.get_duration()（权威游戏时，battle 自己按 sim_delta 累加）
	# 驱动节拍——time_scale 下每渲染帧跑多个物理子步，await physics_frame 每帧
	# 只恢复一次，按帧数累加会少记 game 秒（实测 ~5×），按时长差分则精确
	while true:
		await get_tree().physics_frame
		if not is_instance_valid(_battle) or not _battle.is_active():
			break
		var dur: float = float(_battle.get_duration())
		_beat_acc += dur - _t
		_t = dur
		while _beat_acc >= BEAT:
			_beat_acc -= BEAT
			_run_beat(agents)
		if _t > BATTLE_TIME_LIMIT + 5.0:
			break  # 兜底（duration_limit 正常会先到）
	var result := _collect_result()
	_cleanup_battle()
	return result


## 一个决策节拍：夺点结算 → 逐方构造观察 → agent 决策 → 意图翻译下发。
func _run_beat(agents: Dictionary) -> void:
	# 1) 夺点结算（半径内双方人数喂点；每拍恰一次，无规划器替 env 驱动）
	for p in _flags:
		var counts: Dictionary = {}
		for f in [1, 2]:
			var n: int = 0
			for sq_v in _side[f]["squads"]:
				for u in sq_v["units"]:
					if _is_fighting(u) \
							and (u as Node2D).global_position.distance_to(p.get_position()) <= p.get_radius():
						n += 1
			counts[f] = n
		p.tick(BEAT, counts)
	# 2) 双方各自决策（两份独立观察——同一网络自博弈即两份前向）
	for f in [1, 2]:
		var agent: Object = agents.get(f)
		if agent == null:
			continue
		var side: Dictionary = _side[f]
		var squads: Array = side["squads"]
		var mask := PackedInt32Array()
		mask.resize(N_SQUADS)
		var squad_ids: Array = []
		for si in squads.size():
			var sq: Dictionary = squads[si]
			squad_ids.append(sq["id"])
			mask[si] = 1 if _squad_alive_count(sq) > 0 else 0
		if mask[0] + mask[1] + mask[2] == 0:
			continue  # 全军覆没：不决策不下令
		var view: Dictionary = {
			"faction": f,
			"obs": _encode_obs(f),
			"active_mask": mask,
			"squad_ids": squad_ids,
		}
		var intents_v: Variant = agent.beat(BEAT, view)
		if not (intents_v is PackedInt32Array) or (intents_v as PackedInt32Array).is_empty():
			continue  # planner 等自下令型 agent：号令已自行走 TacticalOrders
		_apply_intents(f, intents_v, mask)


## 意图 → TacticalOrders 翻译（带节流：意图变/目标漂移/定期刷新才重发）。
func _apply_intents(faction: int, intents: PackedInt32Array, mask: PackedInt32Array) -> void:
	var orders: Node = get_orders_node()
	if orders == null:
		return
	var squads: Array = _side[faction]["squads"]
	var st: Dictionary = _order_state[faction]
	for si in squads.size():
		if mask[si] == 0:
			continue
		var intent: int = intents[si] if si < intents.size() else 4
		var sq: Dictionary = squads[si]
		var centroid := _squad_centroid(sq)
		var target := Vector2.ZERO
		var use_hold: bool = false
		match intent:
			0, 1, 2:
				target = _flag_pos_selfview(faction, intent)
			3:
				var g := _nearest_owned_flag(faction, centroid)
				if not g.is_empty():
					target = g["pos"]
					# 到位转原地坚守（号令层 HOLD，占住点位）
					if centroid.distance_to(target) <= GARRISON_ARRIVE_DIST:
						use_hold = true
				else:
					target = _flag_pos_selfview(faction, 1)  # 无己方旗：退化为攻中旗
			_:
				target = _nearest_enemy_centroid(faction, centroid)
		var key := str(si)
		var prev: Dictionary = st.get(key, {})
		var last_pos := Vector2(float(prev.get("tx", INF)), float(prev.get("ty", INF)))
		var drifted: bool = last_pos.distance_to(target) > ORDER_EPS_DIST
		var refresh: bool = int(prev.get("beats", ORDER_REFRESH_BEATS)) >= ORDER_REFRESH_BEATS
		var changed: bool = int(prev.get("intent", -1)) != intent
		if use_hold:
			if int(prev.get("holding", 0)) != 1:
				orders.issue(OrdersScript.OrderType.HOLD_POSITION, String(sq["id"]),
						Vector2.ZERO, 0)
				st[key] = {"intent": intent, "tx": target.x, "ty": target.y,
					"beats": 0, "holding": 1}
			else:
				st[key]["beats"] = int(st[key]["beats"]) + 1
			continue
		if changed or drifted or refresh or prev.is_empty():
			orders.issue(OrdersScript.OrderType.ADVANCE_ALL, String(sq["id"]), target, 0)
			st[key] = {"intent": intent, "tx": target.x, "ty": target.y, "beats": 0, "holding": 0}
		else:
			st[key]["beats"] = int(prev.get("beats", 0)) + 1


# ─────────────────────────────── 观察编码（己方视角镜像）────────────────────────────────

## 镜像符号：faction 1 天然从西往东打（+1）；faction 2 取负——两份观察同构，
## 同一网络执掌两边。
func _mirror_sign(faction: int) -> float:
	return 1.0 if faction == 1 else -1.0


## 57 维自视角观察（布局见文件头；长循环无容器分配，只有 obs 一个输出包）
func _encode_obs(faction: int) -> PackedFloat32Array:
	var obs := PackedFloat32Array()
	obs.resize(OBS_DIM)
	var foe: int = 3 - faction
	var mir: float = _mirror_sign(faction)
	# 全局块
	var my_alive: int = 0
	var foe_alive: int = 0
	var my_hp: float = 0.0
	var foe_hp: float = 0.0
	for f in [faction, foe]:
		for sq_v in _side[f]["squads"]:
			for u in sq_v["units"]:
				if not _is_fighting(u):
					continue
				# 已释放的 HealthComponent 防炸：Variant 接 + is_instance_valid
				var hp_v: Variant = u.get_health()
				var ratio: float = hp_v.get_health_ratio() if hp_v != null and is_instance_valid(hp_v) and hp_v.has_method("get_health_ratio") else 1.0
				if f == faction:
					my_alive += 1
					my_hp += ratio
				else:
					foe_alive += 1
					foe_hp += ratio
	var my_init: int = _side[faction]["initial_n"]
	var foe_init: int = _side[foe]["initial_n"]
	obs[0] = _norm01(float(my_alive) / float(maxi(my_init, 1)))
	obs[1] = _norm01(float(foe_alive) / float(maxi(foe_init, 1)))
	obs[2] = clampf(float(my_alive) / float(maxi(my_alive + foe_alive, 1)) * 2.0 - 1.0, -1.0, 1.0)
	obs[3] = _norm01(my_hp / float(maxi(my_alive, 1)))
	obs[4] = _norm01(foe_hp / float(maxi(foe_alive, 1)))
	obs[5] = clampf(1.0 - _t / BATTLE_TIME_LIMIT, 0.0, 1.0)
	# 旗块（自视角左中右）
	var my_centroid := _faction_centroid(faction)
	var my_total: float = float(maxi(my_alive, 1))
	var foe_total: float = float(maxi(foe_alive, 1))
	var selfview := _flags_selfview(faction)
	for fi in N_SQUADS:
		var p = selfview[fi]
		var base: int = 6 + fi * 7
		obs[base] = 1.0 if p.get_owner_faction() == faction else 0.0
		obs[base + 1] = 1.0 if p.get_owner_faction() == foe else 0.0
		obs[base + 2] = 1.0 if p.get_owner_faction() == 0 else 0.0
		obs[base + 3] = _norm01(p.get_progress() / 100.0)
		var my_near: int = 0
		var foe_near: int = 0
		for sq_v in _side[faction]["squads"]:
			for u in sq_v["units"]:
				if not _is_fighting(u):
					continue
				var d: float = (u as Node2D).global_position.distance_to(p.get_position())
				if d <= p.get_radius():
					my_near += 1
		for sq_v in _side[foe]["squads"]:
			for u in sq_v["units"]:
				if not _is_fighting(u):
					continue
				var d: float = (u as Node2D).global_position.distance_to(p.get_position())
				if d <= p.get_radius():
					foe_near += 1
		obs[base + 4] = _norm01(float(my_near) / my_total)
		obs[base + 5] = _norm01(float(foe_near) / foe_total)
		obs[base + 6] = _norm01(my_centroid.distance_to(p.get_position()) / 2500.0)
	# 班块（编制序；镜像位置 = sign×(x−mid_x)，本方永远负半场往正半场打）
	var st: Dictionary = _order_state.get(faction, {})
	for si in _side[faction]["squads"].size():
		var sq: Dictionary = _side[faction]["squads"][si]
		var base: int = 27 + si * 8
		var alive_n: int = _squad_alive_count(sq)
		var centroid := _squad_centroid(sq)
		var mr: float = mir * (centroid.x - _mid_x) if alive_n > 0 else 0.0
		obs[base] = clampf(mr / 2000.0, -1.0, 1.0)
		obs[base + 1] = clampf((centroid.y - _spawn_y) / 400.0, -1.0, 1.0) if alive_n > 0 else 0.0
		obs[base + 2] = _norm01(float(alive_n) / float(maxi(int(sq["initial_n"]), 1)))
		obs[base + 3] = _norm01(_squad_avg_hp(sq))
		obs[base + 4] = _norm01(_nearest_enemy_dist(faction, centroid) / 1500.0)
		var prev: Dictionary = st.get(str(si), {})
		var last_intent: int = int(prev.get("intent", -1))
		for a in N_ACTIONS:
			obs[base + 5 + a] = 1.0 if last_intent == a else 0.0
	return obs


func _norm01(v: float) -> float:
	return clampf(v, 0.0, 1.0)


## 自视角旗序：左 = 本方出发侧最近（镜像 x 最小）
func _flags_selfview(faction: int) -> Array:
	var sorted := _flags.duplicate()
	var mir: float = _mirror_sign(faction)
	sorted.sort_custom(func(a, b):
		return mir * a.get_position().x < mir * b.get_position().x)
	return sorted


## 自视角第 idx 面旗的世界坐标（0 左 / 1 中 / 2 右）
func _flag_pos_selfview(faction: int, idx: int) -> Vector2:
	var sorted := _flags_selfview(faction)
	if sorted.is_empty():
		return Vector2(_mid_x, _spawn_y)
	return (sorted[clampi(idx, 0, sorted.size() - 1)] as Object).get_position()


func _nearest_owned_flag(faction: int, from: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = INF
	for p in _flags:
		if p.get_owner_faction() != faction:
			continue
		var d: float = from.distance_to(p.get_position())
		if d < best_d:
			best_d = d
			best = {"pos": p.get_position()}
	return best


func _nearest_enemy_centroid(faction: int, from: Vector2) -> Vector2:
	var foe: int = 3 - faction
	var best: Vector2 = Vector2(_mid_x, _spawn_y)
	var best_d: float = INF
	for sq_v in _side[foe]["squads"]:
		var c := _squad_centroid(sq_v)
		var d: float = from.distance_to(c)
		if d < best_d:
			best_d = d
			best = c
	return best


func _nearest_enemy_dist(faction: int, from: Vector2) -> float:
	var foe: int = 3 - faction
	var best: float = 3000.0
	for sq_v in _side[foe]["squads"]:
		var d: float = from.distance_to(_squad_centroid(sq_v))
		if d < best:
			best = d
	return best


## 阵营全员质心（无人时回落出生中点）
func _faction_centroid(faction: int) -> Vector2:
	var sum := Vector2.ZERO
	var n: int = 0
	for sq_v in _side[faction]["squads"]:
		for u in sq_v["units"]:
			if _is_fighting(u):
				sum += (u as Node2D).global_position
				n += 1
	if n == 0:
		return Vector2(_mid_x, _spawn_y)
	return sum / float(n)


func _squad_centroid(sq: Dictionary) -> Vector2:
	var sum := Vector2.ZERO
	var n: int = 0
	for u in sq["units"]:
		if _is_fighting(u):
			sum += (u as Node2D).global_position
			n += 1
	if n == 0:
		return Vector2(_mid_x, _spawn_y)
	return sum / float(n)


func _squad_alive_count(sq: Dictionary) -> int:
	var n: int = 0
	for u in sq["units"]:
		if _is_fighting(u):
			n += 1
	return n


func _squad_avg_hp(sq: Dictionary) -> float:
	var s: float = 0.0
	var n: int = 0
	for u in sq["units"]:
		if not _is_fighting(u):
			continue
		var hp_v: Variant = u.get_health()
		s += hp_v.get_health_ratio() if hp_v != null and is_instance_valid(hp_v) and hp_v.has_method("get_health_ratio") else 1.0
		n += 1
	return s / float(maxi(n, 1))


## 战斗在编判定：活着、未离场（溃逃布尔态已退役——避战是行为态，避战者没死
## 就算存活/合法目标；与 battle_instance 的存活/有效战力判定同口径）
func _is_fighting(u) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	if u.has_method("is_dead") and u.is_dead():
		return false
	if bool(u.get("departed")):
		return false
	return true


# ─────────────────────────────── 造战基建 ────────────────────────────────

## 一方出生 + 班记录。attacker=false = 守方（东缘镜像）。
## 返回该方全部单位（start_test_battle 用）。
func _spawn_side(comp: Dictionary, faction: int, is_defender: bool) -> Array:
	var side_sign: float = -1.0 if not is_defender else 1.0  # 出生侧：攻西(−) 守东(+)
	var units: Array = []
	var squad_units: Array = []
	for si in N_SQUADS:
		squad_units.append([])
	var weapons_per_squad: Array = []
	for si in N_SQUADS:
		weapons_per_squad.append(comp["squads"][si]["weapons"])
	# 班基准位：出生带 + 侧向 y 抖动 + 班间错位（班纵深：先锋最前，中坚/火力
	# 依次沿本方后退方向撤——后退方向 = side_sign：攻方(−1)向 −x 撤，守方(+1)向 +x 撤）
	for si in N_SQUADS:
		var band_x: float = float(comp["band_x"])
		var depth: float = float(si) * 260.0 * side_sign
		var sx: float = _mid_x + side_sign * (band_x + float(comp["squad_%d_x" % si])) + depth
		var sy: float = clampf(_spawn_y + float(comp["side_y"]) + float(comp["squad_%d_y" % si]),
				_band_top, _band_bottom)
		var weapons: Array = weapons_per_squad[si]
		for k in weapons.size():
			var row: int = floori(float(k) / float(PER_ROW))
			var col: int = k % PER_ROW
			# 横排展开（y 方向），后排沿本方后退方向退 UNIT_X_GAP
			var uy: float = sy + (float(col) - 3.5) * UNIT_Y_GAP
			var ux: float = sx + float(row) * UNIT_X_GAP * side_sign
			uy = clampf(uy, _band_top, _band_bottom)
			var e: Node2D = _map.spawn_entity(STICKMAN_SCENE, Vector2(ux, uy))
			if e == null:
				continue
			# HD-2D 图 origin 即视觉脚线，无需脚部校正（口径同 battle_arena）
			if e.has_method("set_possessed"):
				e.set_possessed(false)
			var wm: Node = e.get_node_or_null("WeaponMount")
			if wm != null:
				wm.set("weapon_type", int(weapons[k]))
			# 防初始化竞态：hp 未就绪（<=0 拖累胜负判定）则自愈满血
			var hc = e.get("health_component")
			if hc != null and float(hc.get("hp")) <= 0.0:
				hc.set("hp", hc.get("max_hp"))
			units.append(e)
			squad_units[si].append(e)
	# 记录（squads 结构 play_battle 全程消费）
	var squads: Array = []
	for si in N_SQUADS:
		squads.append({"id": "", "units": squad_units[si], "initial_n": squad_units[si].size()})
	_side[faction] = {"squads": squads, "units": units,
		"initial_n": units.size(), "comp": comp, "is_defender": is_defender}
	return units


## 建制（FormationSystem.create_squad；空班跳过——create_squad 拒收空数组）
func _make_squads(faction: int, comp: Dictionary) -> void:
	var fs: Node = _game_root.get_formation_system()
	if fs == null or not fs.has_method("create_squad"):
		push_error("[BattleEnv] FormationSystem 不可用，无法编班")
		return
	var squads: Array = _side[faction]["squads"]
	for si in squads.size():
		var sq: Dictionary = squads[si]
		if (sq["units"] as Array).is_empty():
			continue
		var sid: String = String(fs.create_squad(sq["units"], "%s·F%d" % [comp["squads"][si]["name"], faction], "fp_combat_squad"))
		sq["id"] = sid


## 布三面旗（对称：中线 ±500，y 错开；全无主开局）
func _setup_flags() -> void:
	_flags.clear()
	var defs: Array = [
		{"id": "capture_left", "pos": Vector2(_mid_x - FLAG_X_SPREAD, _spawn_y - FLAG_Y_OFFSET)},
		{"id": "capture_center", "pos": Vector2(_mid_x, _spawn_y)},
		{"id": "capture_right", "pos": Vector2(_mid_x + FLAG_X_SPREAD, _spawn_y + FLAG_Y_OFFSET)},
	]
	for d in defs:
		var pos: Vector2 = d["pos"]
		pos.y = snappedf(clampf(pos.y, _band_top, _band_bottom), 10.0)
		pos.x = snappedf(pos.x, 10.0)
		# CapturePoint 是 RefCounted（非 Node）：无类型注解承接，防赋值类型炸（口径同 battle_arena）
		var point = TacticsAPI.CapturePoint.new()
		point.setup(String(d["id"]), pos, FLAG_RADIUS, 0)
		_flags.append(point)


## 结算素材收集（battle _end 后 roster 已清，存活数用 env 自己的口径重数——
## 与 battle_instance 的判定一致：死亡/departed 均计非存活）
func _collect_result() -> Dictionary:
	var alive := {1: 0, 2: 0}
	for f in [1, 2]:
		for sq_v in _side.get(f, {}).get("squads", []):
			for u in sq_v["units"]:
				if u != null and is_instance_valid(u) \
						and not (u.has_method("is_dead") and u.is_dead()) \
						and not bool(u.get("departed")):
					alive[f] += 1
	var flags_owned := {1: 0, 2: 0}
	for p in _flags:
		var o: int = p.get_owner_faction()
		if flags_owned.has(o):
			flags_owned[o] += 1
	var winner: int = 0
	var reason: String = "timeout"
	if not _last_summary.is_empty():
		reason = String(_last_summary.get("reason", ""))
		winner = _winner_from_summary()
	else:
		# 兜底：按存活判（与 battle duration_limit 超时口径一致）
		winner = 1 if alive[1] > alive[2] else (2 if alive[2] > alive[1] else 0)
	return {"winner": winner, "alive": alive,
		"initial": {1: int(_side[1]["initial_n"]), 2: int(_side[2]["initial_n"])},
		"flags_owned": flags_owned, "duration": _t, "reason": reason}


## 从结算摘要取胜方（0=平局；BattleInstance.State：ATTACKER_WIN=2 DEFENDER_WIN=3）
func _winner_from_summary() -> int:
	var result: int = int(_last_summary.get("result", 0))
	if result == 2:
		return 1
	if result == 3:
		return 2
	return 0


## 清场：解散本场小队 + 释放单位（防残留污染下一场目标选择/胜负判定）
func _cleanup_battle() -> void:
	var fs: Node = _game_root.get_formation_system() if _game_root != null else null
	for f in [1, 2]:
		if not _side.has(f):
			continue
		for sq_v in _side[f]["squads"]:
			var sid: String = String(sq_v["id"])
			if not sid.is_empty() and fs != null and fs.has_method("disband_squad"):
				fs.disband_squad(sid)
		for u in _side[f]["units"]:
			if u != null and is_instance_valid(u):
				u.queue_free()
	_side.clear()
	_flags.clear()
	_battle = null


## 防上一场残留（queue_free 到实际释放有延迟；开新场前再清一遍地图野单位）
func _clear_battlefield() -> void:
	if _map == null or not is_instance_valid(_map):
		return
	for e in _map.get_entities():
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			# 只清无主单位：上场的兵已在 _cleanup_battle 处理，这里兜底开图自带实体
			e.queue_free()
