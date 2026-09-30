class_name SquadIntentPlanner
extends RefCounted
## 班级意图规划器 —— 夺点驱动的班级宏观大脑（小兵步枪编班意图路线的 L2 落点）。
##
## 总路线（小兵步枪 Ravenfield，机制参照见 docs/项目/审计/小兵步枪AI逆向_2026-09-11.md
## 与英雄连AI逆向_2026-09-11.md）：编班 + 班长 + 夺点驱动宏观意图 + 到旗边先观察再进场，
## 无经济层。本类每 0.5s 一拍（CoH TimeRule_AddInterval 0.5 真值），给每班打分选意图：
##   攻点 CAPTURE   —— 未占/敌占点，分值随距离衰减 × 我敌兵力比（ aggression 风格倍率）；
##   驻防 GARRISON  —— 己方已占点留班看家，已有人看的点降权劝退叠班（不禁止增援）；
##   接火 INTERCEPT —— 敌班逼近己方要点时优先拦截（urgency 放大压得过驻防惯性）；
##   惯性 INERTIA   —— 意图留任加值（CoH score_inertia 同职能），换意图须高出此值才换，防抖。
## 选定意图后翻译成 TacticalOrders 号令下发：推进类 = ADVANCE_ALL（自带 engage_in_range，
## 途中遇敌即停接战）；驻足 = HOLD_POSITION。
##
## 到旗边先看再进（Ravenfield 观察纪律，参数化）：攻点三相位
##   APPROACH 退到旗边观察位（点半径外 standoff 处）→ OBSERVE 驻足观察 observe_time 秒
##   → SETTLE 越旗入场。驻防两相位：走到点 → 原地坚守。接火：追敌质心，漂移超阈值才重发。
##
## 依赖纪律（L2 零出向）：不依赖 combat / formation / units——
##   - 单位数据经调用方注入的 unit_snapshot_provider 回传（值拷贝 {pos, faction, squad_id}）；
##   - 夺点对象由调用方构造注入（本模块 CapturePoint，双方共享）；
##   - 号令经注入的 TacticalOrders 节点下发（AI 口径 source_tier=1）。
## 驱动形态：外部宿主每帧调 tick(delta)（内部 0.5s 节拍累积 + 暂停守卫），亦可由
## Benchmark 选手脚本按 0.5s 直调——不与任何宿主场景死耦合。
## 结算权纪律：双方共享同一批夺点，占领结算（积分/易主）每拍只准发生一次——
## **同局两台规划器恰好一台 setup(drives_settlement = true)**（惯例 = 攻方/先建那台），
## 另一台只决策不结算；双开会导致积分翻倍。
##
## avoid_clumps 红线（创始人 2026-09-30）：本类的 DUPLICATE_PENALTY 只作用在**意图分配层**
## （两班不挤同一个旗点/同一个敌班——决定"往哪走"），绝不作用于已接战单位的落点选择；
## 单位级接战行为（behavior 层）零触碰，接战中部队不会被本规划器从战线推开。
##
## RL 钩子（创始人 2026-09-30）：下方打分常量表与 STYLE_TABLES 就是日后离线
## RL/黑盒搜索的变量集——公式结构不动，改表即可当搜索维度。

## 同模块兄弟脚本（tactics 模块内显式 preload 惯例）
const ScriptOrders: GDScript = preload("res://modules/tactics/scripts/tactical_orders.gd")

# ─────────────────────────────── 枚举 ────────────────────────────────
## 班级意图（NONE = 未决策）
enum Intent { NONE, CAPTURE, GARRISON, INTERCEPT }
## 意图内相位（攻点三段 / 驻防两段共用）
enum Phase { APPROACH, OBSERVE, SETTLE }

# ─────────────────────────────── 常量（打分基座）────────────────────────────────
## 以下为打分公式全部权重——RL/黑盒搜索变量集【全部待实测校准】。
## 基座对齐英雄连 TGROUP 固定优先级表（CaptureHigh 85 / DefenceSecure 65 /
## Attack 60 / Defend 50，逆向笔记英雄连AI逆向_2026-09-11.md §3.1）与四因子权重
## （avoid_clumps=10 最高 → DUPLICATE_PENALTY；inertia=1.4 → INERTIA_BONUS）。
## 攻点基础分（CoH CaptureHigh 85）
const SCORE_CAPTURE_BASE: float = 85.0
## 接火基础分（须高于攻点：拦截优先于开阔推进；配 urgency 放大见 _choose_intent）
const SCORE_INTERCEPT_BASE: float = 90.0
## 驻防基础分（CoH Defend 50）
const SCORE_GARRISON_BASE: float = 50.0
## 惯性留任加值（防抖：新意图打分须高出当前意图此值才值得换）
const SCORE_INERTIA_BONUS: float = 30.0
## 同拍同目标叠加惩罚（CoH avoid_clumps 同职能——**意图分配层专用**，见文件头红线注释）
const SCORE_DUPLICATE_PENALTY: float = 40.0
## 距离衰减全程（px：距离因子从 1.0 线性降到此距离处触底；观察场全图约 ±2000px）
const SCORE_DISTANCE_DECAY_RANGE: float = 3000.0
## 接火触发半径（px：敌班质心逼近己方要点小于此值才生成拦截候选）
const SCORE_INTERCEPT_TRIGGER_DIST: float = 600.0
## 我敌兵力比下限/上限（夹紧防单边归零/爆炸）
const SCORE_RATIO_FLOOR: float = 0.1
const SCORE_RATIO_CEIL: float = 2.0
## 距离因子下限（不为 0：远点仍可达，只是优先级低，避免候选集空转）
const SCORE_DIST_FACTOR_FLOOR: float = 0.05
## 驻防叠班因子（点已有人看时驻防分乘此值——劝退叠班不禁止增援）
const SCORE_GARRISON_STACK_FACTOR: float = 0.3

# ─────────────────────────────── 常量（节拍与机动）────────────────────────────────
## 决策节拍（秒，CoH TimeRule_AddInterval 0.5 真值）
const BEAT_INTERVAL: float = 0.5
## 到位判定距离（px：班质心距目标位小于此值视为到位）
const ARRIVE_DIST: float = 60.0
## 旗边观察退距（px：观察位 = 点半径外推此值，站旗边外不误触占领）
const OBSERVE_STANDOFF: float = 40.0
## 推进号令重发阈值（px：目标位几乎没变就不重发，防号令风暴）
const ORDER_EPS_DIST: float = 1.0
## 接火追击重发距离（px：敌质心漂移超此值才重下号令）
const INTERCEPT_REISSUE_DIST: float = 200.0
## 自动号令发令层级（与 combat TeamAi.SOURCE_TIER_AI 同口径 = 1；
## tactics 不反向引 combat，本地常量镜像）
const SOURCE_TIER_AI: int = 1

# ─────────────────────── 常量（风格参数表，AI 人格钩子）───────────────────────
## 每方一份的风格参数表——后续 AI 人格的挂点，也是 RL 搜索变量集【待实测校准】：
##   aggression    攻点分倍率（进攻性：高 = 更愿压点）
##   garrison_need 驻防分倍率（看家需求：高 = 更愿留守）
##   observe_time  旗边观察时长（秒，Ravenfield"先看再进"的观察纪律）
const STYLE_TABLES: Dictionary = {
	1: { "aggression": 1.0, "garrison_need": 1.0, "observe_time": 0.8 },
	2: { "aggression": 1.0, "garrison_need": 1.0, "observe_time": 0.8 },
}

# ─────────────────────────────── 状态 ────────────────────────────────
## 本方阵营（1 = 进攻方 / 2 = 防守方）
var _faction: int = 0
## 夺点列表（本模块 CapturePoint，双方规划器共享；结算由先拍的规划器驱动）
var _points: Array = []
## 本方班号列表（编制序 = 打分分配序；空串已滤）
var _own_squad_ids: Array = []
## TacticalOrders 节点（duck 注入；同模块类型，允许 null = 只决策不下令）
var _orders: Node = null
## 单位快照 provider（调用方注入；每拍回调查询，值拷贝零悬挂）
var _provider: Callable = Callable()
## 本方风格参数（STYLE_TABLES 行引用，只读）
var _style: Dictionary = {}
## 结算权标记（true = 本台规划器驱动夺点占领结算；同局恰好一台为 true，见文件头）
var _drives_settlement: bool = false
## 节拍累积器（while 兼容 delta 尖峰不丢拍）
var _beat_acc: float = 0.0
## 班意图状态机：squad_id -> {"intent", "target_id", "phase", "observe_left",
##                          "last_order_pos", "holding"}
var _squad_states: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配（宿主/benchmark 选手创建后调用一次）。
## faction ∈ {1,2}；points = CapturePoint 数组（双方共享同一批实例）；
## own_squad_ids = 本方班号（编制序）；orders = TacticalOrders 节点（duck，允许 null）；
## unit_snapshot_provider = 无参 Callable，返回 Array[{pos: Vector2, faction: int,
## squad_id: String}]（双方全部存活单位，值拷贝）；
## drives_settlement = 是否由本台驱动夺点占领结算（同局两台恰好一台 true，惯例攻方）。
func setup(faction: int, points: Array, own_squad_ids: Array, orders: Node,
		unit_snapshot_provider: Callable, drives_settlement: bool = false) -> void:
	_faction = faction
	_points = points
	_style = STYLE_TABLES.get(faction, STYLE_TABLES[1])
	for sid_v in own_squad_ids:
		var sid := str(sid_v)
		if not sid.is_empty():
			_own_squad_ids.append(sid)
	_orders = orders
	_provider = unit_snapshot_provider
	_drives_settlement = drives_settlement


## 节拍驱动入口（外部每帧喂 delta；内部按 BEAT_INTERVAL 累积出拍）。
## 暂停冻结（与 combat TeamAi 同口径）：TimeManager 暂停时不累积不决策。
func tick(delta: float) -> void:
	if TimeManager != null and TimeManager.is_paused():
		return
	_beat_acc += delta
	while _beat_acc >= BEAT_INTERVAL:
		_beat_acc -= BEAT_INTERVAL
		_run_beat()


# ─────────────────────────────── 只读查询 ────────────────────────────────

## 本方阵营
func get_faction() -> int:
	return _faction


## 班当前意图（观测/调试/选手快照用；无状态返回 Intent.NONE）
func get_squad_intent(squad_id: String) -> int:
	var st: Dictionary = _squad_states.get(squad_id, {})
	return int(st.get("intent", Intent.NONE))


# ─────────────────────────────── 一拍决策 ────────────────────────────────

## 执行一拍：夺点结算 → 班级聚合 → 逐班打分选意图 → 号令翻译下发。
func _run_beat() -> void:
	if not _provider.is_valid():
		return
	var snap_v: Variant = _provider.call()
	if not (snap_v is Array):
		return
	var snapshot: Array = snap_v
	# 1) 夺点结算（半径内双方人数喂给每个点：积分 / 冻结互消 / 易主）——
	#    仅持结算权的规划器执行（同局恰好一台，防双台同拍双份积分）
	if _drives_settlement:
		for p in _points:
			var counts: Dictionary = {}
			for u_v in snapshot:
				var u: Dictionary = u_v
				if (u["pos"] as Vector2).distance_to(p.get_position()) <= p.get_radius():
					var f: int = int(u["faction"])
					counts[f] = int(counts.get(f, 0)) + 1
			p.tick(BEAT_INTERVAL, counts)
	# 2) 班级聚合（本方/敌方：存活数 + 质心；无班散兵不参与宏观意图）
	var own: Dictionary = {}
	var enemy: Dictionary = {}
	for u_v in snapshot:
		var u: Dictionary = u_v
		var sid: String = String(u["squad_id"])
		if sid.is_empty():
			continue
		var bucket: Dictionary = own if int(u["faction"]) == _faction else enemy
		var agg: Dictionary = bucket.get(sid, {})
		if agg.is_empty():
			agg = { "count": 0, "sum": Vector2.ZERO }
			bucket[sid] = agg
		agg["count"] = int(agg["count"]) + 1
		agg["sum"] = (agg["sum"] as Vector2) + (u["pos"] as Vector2)
	for bucket_v in [own, enemy]:
		var bucket: Dictionary = bucket_v
		for sid in bucket:
			var agg: Dictionary = bucket[sid]
			agg["centroid"] = (agg["sum"] as Vector2) / float(agg["count"])
	var own_total: int = 0
	for sid in own:
		own_total += int(own[sid]["count"])
	if own_total <= 0:
		return  # 全军覆没：不再决策不再发令
	var enemy_total: int = 0
	for sid in enemy:
		enemy_total += int(enemy[sid]["count"])
	# 3) 逐班打分选意图（编制序分配；本拍内叠班惩罚防两班挤同一目标）
	var assigned_points: Dictionary = {}    # point_id -> 本拍已派班数
	var assigned_enemies: Dictionary = {}   # 敌班 squad_id -> 本拍已派班数
	for sid_v in _own_squad_ids:
		var sid: String = str(sid_v)
		if not own.has(sid):
			continue  # 全灭班：跳过（不向空班发令）
		var agg: Dictionary = own[sid]
		var choice: Dictionary = _choose_intent(
				sid, agg["centroid"], own_total, enemy_total, enemy,
				assigned_points, assigned_enemies)
		if choice.is_empty():
			continue
		_record_assignment(choice, assigned_points, assigned_enemies)
		_advance_squad(sid, choice, agg["centroid"], enemy)


## 打分选意图（返回 {intent, target_id, score[, point]}；全负返回 {} = 本拍不动）。
## 打分公式（全文）：
##   兵力比  ratio = clamp(我方存活 / max(敌方存活, 1), 0.1, 2.0)
##   距离因子 dist_factor = clamp(1 - 距离/3000, 0.05, 1.0)          （分值随距离衰减）
##   攻点    = aggression × 85 × dist_factor × ratio                 （未占/敌占点）
##             − 40（本拍已有别的班盯同一点）+ 30（惯性：意图与目标均未变）
##   驻防    = garrison_need × 50 × deficit × dist_factor            （己方已占点；
##             deficit = 1.0 无人看 / 0.3 已有人看）+ 30（惯性同上）
##   接火    = 90 × urgency × dist_factor × ratio                    （敌班逼近己方要点
##             < 600px 才生成；urgency = 1 + (1 − 威胁距离/600) ∈ [1,2]，威胁越近分越高，
##             放大段使其压得过渡了惯性分（驻防留任 ≈ 50+30），兑现"优先拦截"）
##   惯性    = 意图与目标均与当前一致时 +30（换意图有代价，防抖）
##   选意    = argmax（严格大于，同分保持先到候选 → 逐拍确定性）
func _choose_intent(squad_id: String, centroid: Vector2, own_total: int, enemy_total: int,
		enemy: Dictionary, assigned_points: Dictionary, assigned_enemies: Dictionary) -> Dictionary:
	var ratio: float = clampf(float(own_total) / maxf(float(enemy_total), 1.0),
			SCORE_RATIO_FLOOR, SCORE_RATIO_CEIL)
	var cands: Array = []
	# 攻点（未占/敌占）与驻防（己方已占）：一点一候选
	for p in _points:
		var dist_factor: float = _distance_factor(centroid, p.get_position())
		if p.get_owner_faction() != _faction:
			var score: float = float(_style["aggression"]) * SCORE_CAPTURE_BASE * dist_factor * ratio
			if int(assigned_points.get(p.get_point_id(), 0)) > 0:
				score -= SCORE_DUPLICATE_PENALTY
			cands.append({ "intent": Intent.CAPTURE, "target_id": p.get_point_id(),
					"score": score, "point": p })
		else:
			var deficit: float = SCORE_GARRISON_STACK_FACTOR \
					if int(assigned_points.get(p.get_point_id(), 0)) > 0 else 1.0
			var g_score: float = float(_style["garrison_need"]) * SCORE_GARRISON_BASE \
					* deficit * dist_factor
			cands.append({ "intent": Intent.GARRISON, "target_id": p.get_point_id(),
					"score": g_score, "point": p })
	# 接火（敌班逼近己方要点）：己方无要点则无家可守，不生成拦截候选
	var has_home: bool = false
	for p in _points:
		if p.get_owner_faction() == _faction:
			has_home = true
			break
	if has_home:
		for esid_v in enemy.keys():
			var esid: String = str(esid_v)
			var e: Dictionary = enemy[esid_v]
			var threat_dist: float = INF
			for p in _points:
				if p.get_owner_faction() == _faction:
					threat_dist = minf(threat_dist,
							(e["centroid"] as Vector2).distance_to(p.get_position()))
			if threat_dist >= SCORE_INTERCEPT_TRIGGER_DIST:
				continue
			var urgency: float = 1.0 + (1.0 - threat_dist / SCORE_INTERCEPT_TRIGGER_DIST)
			var i_score: float = SCORE_INTERCEPT_BASE * urgency \
					* _distance_factor(centroid, e["centroid"]) * ratio
			if int(assigned_enemies.get(esid, 0)) > 0:
				i_score -= SCORE_DUPLICATE_PENALTY
			cands.append({ "intent": Intent.INTERCEPT, "target_id": esid, "score": i_score })
	# 惯性留任 + argmax（严格大于：同分保持先到候选，逐拍确定性不抖）
	var cur: Dictionary = _squad_states.get(squad_id, {})
	var cur_intent: int = int(cur.get("intent", Intent.NONE))
	var cur_target: String = String(cur.get("target_id", ""))
	var best: Dictionary = {}
	var best_score: float = 0.0
	for cand_v in cands:
		var cand: Dictionary = cand_v
		var score: float = float(cand["score"])
		if int(cand["intent"]) == cur_intent and String(cand["target_id"]) == cur_target:
			score += SCORE_INERTIA_BONUS
		if score > best_score:
			best_score = score
			best = cand
	return best


## 意图分配记账（同拍内第二班盯同一目标吃叠加惩罚——avoid_clumps 红线：
## 只在意图层生效，与单位接战落点无关）
func _record_assignment(choice: Dictionary, assigned_points: Dictionary,
		assigned_enemies: Dictionary) -> void:
	match int(choice["intent"]):
		Intent.CAPTURE, Intent.GARRISON:
			var pid: String = String(choice["target_id"])
			assigned_points[pid] = int(assigned_points.get(pid, 0)) + 1
		Intent.INTERCEPT:
			var eid: String = String(choice["target_id"])
			assigned_enemies[eid] = int(assigned_enemies.get(eid, 0)) + 1


## 距离衰减因子（线性降至下限；下限 > 0 保远点仍可达）
func _distance_factor(from: Vector2, to: Vector2) -> float:
	return clampf(1.0 - from.distance_to(to) / SCORE_DISTANCE_DECAY_RANGE,
			SCORE_DIST_FACTOR_FLOOR, 1.0)


# ─────────────────────────────── 意图 → 号令翻译 ────────────────────────────────

## 状态机推进（换意图/换目标重置相位；号令只在换相位/目标漂移时下发，维持期零号令）。
func _advance_squad(squad_id: String, choice: Dictionary, centroid: Vector2,
		enemy: Dictionary) -> void:
	var st: Dictionary = _squad_states.get(squad_id, {})
	if st.is_empty():
		st = {
			"intent": Intent.NONE, "target_id": "", "phase": Phase.APPROACH,
			"observe_left": 0.0, "last_order_pos": Vector2.INF, "holding": false,
		}
		_squad_states[squad_id] = st
	var new_intent: int = int(choice["intent"])
	var new_target: String = String(choice["target_id"])
	if new_intent != int(st["intent"]) or new_target != String(st["target_id"]):
		st["intent"] = new_intent
		st["target_id"] = new_target
		st["phase"] = Phase.APPROACH
	match new_intent:
		Intent.CAPTURE:
			_tick_capture(squad_id, st, choice["point"], centroid)
		Intent.GARRISON:
			_tick_garrison(squad_id, st, choice["point"], centroid)
		Intent.INTERCEPT:
			var e: Dictionary = enemy.get(new_target, {})
			if not e.is_empty():
				_tick_intercept(squad_id, st, e["centroid"])


## 攻点三相位（Ravenfield"先看再进"）：APPROACH 旗边观察位 → OBSERVE 驻足观察
## observe_time 秒（风格参数）→ SETTLE 越旗入场。
## point 为本模块 CapturePoint（鸭子调用：不注解类型——新类名的全局类缓存在
## 无头/测试环境不保证已注册，依赖它解析会炸 parse）。
func _tick_capture(squad_id: String, st: Dictionary, point, centroid: Vector2) -> void:
	var away: Vector2 = centroid - point.get_position()
	var outward: Vector2 = away.normalized() if away.length_squared() > 1.0 else Vector2.ZERO
	var observe_pos: Vector2 = point.get_position() \
			+ outward * (point.get_radius() + OBSERVE_STANDOFF)
	match int(st["phase"]):
		Phase.APPROACH:
			_issue_move_once(squad_id, st, observe_pos)
			if centroid.distance_to(observe_pos) <= ARRIVE_DIST:
				st["phase"] = Phase.OBSERVE
				st["observe_left"] = float(_style["observe_time"])
				_issue_hold(squad_id, st)
		Phase.OBSERVE:
			st["observe_left"] = float(st["observe_left"]) - BEAT_INTERVAL
			if float(st["observe_left"]) <= 0.0:
				st["phase"] = Phase.SETTLE
				_issue_move(squad_id, st, point.get_position())
		Phase.SETTLE:
			pass  # 入场推进中：号令已在途，接战归单位层


## 驻防两相位：APPROACH 走到点 → SETTLE 原地坚守。（point 鸭子调用，口径同 _tick_capture）
func _tick_garrison(squad_id: String, st: Dictionary, point, centroid: Vector2) -> void:
	if int(st["phase"]) != Phase.APPROACH:
		return
	_issue_move_once(squad_id, st, point.get_position())
	if centroid.distance_to(point.get_position()) <= ARRIVE_DIST:
		st["phase"] = Phase.SETTLE
		_issue_hold(squad_id, st)


## 接火追击：敌质心漂移超阈值才重发（敌在动，号令不全频跟）。
func _tick_intercept(squad_id: String, st: Dictionary, enemy_centroid: Vector2) -> void:
	if (st["last_order_pos"] as Vector2).distance_to(enemy_centroid) > INTERCEPT_REISSUE_DIST:
		_issue_move(squad_id, st, enemy_centroid)


# ─────────────────────────────── 号令下发 ────────────────────────────────

## 推进号令（同点不重发；ADVANCE_ALL 自带 engage_in_range——途中遇敌即停接战）
func _issue_move_once(squad_id: String, st: Dictionary, pos: Vector2) -> void:
	if (st["last_order_pos"] as Vector2).distance_to(pos) <= ORDER_EPS_DIST:
		return
	_issue_move(squad_id, st, pos)


func _issue_move(squad_id: String, st: Dictionary, pos: Vector2) -> void:
	if _issue(ScriptOrders.OrderType.ADVANCE_ALL, squad_id, pos):
		st["last_order_pos"] = pos
		st["holding"] = false


## 驻足号令（已在坚守不重发）
func _issue_hold(squad_id: String, st: Dictionary) -> void:
	if bool(st.get("holding", false)):
		return
	if _issue(ScriptOrders.OrderType.HOLD_POSITION, squad_id, Vector2.ZERO):
		st["holding"] = true


## 下发出口（AI 口径 source_tier=1；orders 未注入/失效时静默跳过——只决策不下令）
func _issue(order_type: int, squad_id: String, pos: Vector2) -> bool:
	if _orders == null or not is_instance_valid(_orders) or not _orders.has_method("issue"):
		return false
	return bool(_orders.issue(order_type, squad_id, pos, SOURCE_TIER_AI))
