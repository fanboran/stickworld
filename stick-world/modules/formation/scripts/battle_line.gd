class_name BattleLine
extends RefCounted
## 战线 —— SWL Team 阵线推进直译（Team.Stance 三开关 + MoveInFormation(goalX)）。
##
## SWL 真相（docs/技术/参考/SWL-单位行为完整翻译.md §Team/§Ai）：
##   - 推进是**整队一刀切**（Attack/Defend/Garrison 三姿态，无逐单位命令）；
##   - MoveInFormation(goalX) 把整个编队阵型**沿 x 连续平移**到 goal——不跳点；
##   - 每个兵在**组编队**（formations:Dictionary<Group,Formation>，近战组/远程组
##     各一个 Formation）里有固定行列槽位：跟线走（掉远跑 UpdateCatchingUpToFormation、
##     到位滞回 FormationPositionIsStable）、接敌就打、打完归位、战线继续。
##
## 本类等价实现（每方一台，FormationSystem 宿主驱动）：
##   - 近战组：全组一个组方阵，前列贴 line_x，ATTACK 下 line_x 以 speed 连续
##     向 goal_x 推进；任一成员主手射程内有敌 = 接战，战线停（后队槽位填上=战线
##     在接火处成形），滞回后无接战续推；
##   - 组方阵**纵向铺满行动带**（02 二-A.3）：列数随人数扩展、上限 = 带宽容列数
##     （group_upc），带满才加深纵深；纵深超 LINE_MAX_DEPTH 排的余部隔
##     RESERVE_GAP 二线驻位（槽位随线走 = 站定面向敌阵待命，不游走）；
##   - 远程组：随行于近战组**全纵深**后 GROUP_GAP（动态层距——SWL
##     GapBetweenFormationGroups() 本是计算方法非常量；固定距在大编制下会让
##     远程线叠进近战方阵后排）；任一成员接战即**冻结**远程线（冻结线 =
##     最前接战投影 + 方阵纵深——末列贴射程线，全组齐射），脱战滞回后解冻随行；
##   - 祭司随远程组（wt=5；SWL 层序 HEALERS 在 ARCHERS 后——治疗者贴后排线）；
##   - 号令面：未接战成员每节拍收到 move 号令（engage_in_range：敌进射程即交还
##     战斗行为；line_order 标记，玩家/上级号令不覆盖）——SWL 阵线跟走的等价通道。
##
## 依赖纪律：纯 RefCounted，宿主（FormationSystem）注入；对单位只做 duck 查询
##（get_weapon/get_faction/get_battle_instance/get_ai_controller/is_user_controlled/is_dead），
## 接战判定复用宿主 _member_enemy_in_range（squad_follow_director 同款回引）。

# ─────────────────────── 常量 ───────────────────────
## 接战检查/号令刷新节拍（s，与宿主跟队/目标决策同量级）
const CONTACT_TICK: float = 0.5
## 战线号令死区（px）：距槽位小于此值不重发号令（FormationPositionIsStable 防抖同源；
## 比跟队死区收紧——战线在动，死区过大会变走走停停的脉冲行军）
const LINE_DEADZONE: float = 24.0
## 距槽位超此值转奔跑追赶（UpdateCatchingUpToFormation 直译）
const RUN_DIST: float = 240.0
## 远程组随行间距（近战组全纵深之后；GapBetweenFormationGroups 量级）。
## static var：出生侧几何可按战场图幅（观察场视野预算）整体压缩——默认 260
## 是开阔产线口径
static var GROUP_GAP: float = 260.0
## 战线方阵纵深上限（排）：0~2 排贴线成块，第 3 排起为二线驻位（02 二-A.3
## 「多到装不下的余部归二线驻位待命」——观感标定档每侧十几二十几人时
## 7 列×3 排 = 21 席全员在块内，纵深上限只在密度压力档吃紧）
const LINE_MAX_DEPTH: int = 3
## 二线驻位与方阵块的间隔（px）：比列距大一截，读得出「第二线」而不是又
## 一排；二线槽位随线走（驻位待命），接战语义与在线成员一致。
## static var：出生侧几何可按战场图幅压缩（同 GROUP_GAP）
static var RESERVE_GAP: float = 140.0
## 接战/脱战滞回拍数（防目标切换瞬时空窗导致停线/解冻抖动）
const ENGAGE_HYSTERESIS: int = 2
# ── 个性 y 漂移（SWL Ai.personalityControlledY / personalityNextYControlShift 直译）──
# 单位在槽位横排（y）上按个体个性缓慢漂移——大军 y 分布不机械（02 二-A.5）。
# 每成员到点换漂移目标（间隔 3~8s），指数趋近；幅度夹 ±min(spread×DRIFT_MAX_RATIO,
# (spread−半径Y)/2)——相向漂移最坏压近仍不出分离椭圆（同列相邻间距 = spread −
# 2×幅值 ≥ 半径Y）。确定性：种子注入（宿主可按 battle_id 派生），同种子同漂移。
const DRIFT_MAX_RATIO: float = 0.25
const DRIFT_SHIFT_MIN: float = 3.0
const DRIFT_SHIFT_MAX: float = 8.0
const DRIFT_RATE: float = 0.6
const DRIFT_SEED_FALLBACK: int = 20261009
const _Spacing := preload("res://modules/formation/scripts/formation_spacing.gd")

enum Stance { ATTACK, DEFEND, GARRISON }

# ─────────────────────── 静态几何（出生侧共用单一真相源） ───────────────────────
## 组列高：纵向铺满行动带——列数随人数扩展，上限 = 带宽容列数（(k-1)×槽距 ≤ 带宽
## ⇒ k ≤ 带宽/槽距 + 1）。观察场出生块用同一式摆人，出生位即槽位。
static func group_upc(n: int, band_half: float, spread: float) -> int:
	return mini(n, floori((maxf(band_half, 100.0) * 2.0) / maxf(spread, 40.0)) + 1)


## 列的纵深退距：0~LINE_MAX_DEPTH-1 排贴线成块（列距线性），其后为二线驻位
## （块尾 + RESERVE_GAP 起继续列距）
static func rank_depth(col: int, row_gap: float) -> float:
	if col < LINE_MAX_DEPTH:
		return float(col) * row_gap
	return float(LINE_MAX_DEPTH - 1) * row_gap + RESERVE_GAP \
			+ float(col - LINE_MAX_DEPTH) * row_gap


## 组方阵全纵深（n 人按 upc 排满后的最深列退距；出生块/指挥官后排推导用）
static func block_depth(n: int, upc: int, row_gap: float) -> float:
	if n <= 0 or upc <= 0:
		return 0.0
	return rank_depth(ceili(float(n) / float(upc)) - 1, row_gap)

# ─────────────────────── 状态 ───────────────────────
var faction: int = 0
var facing: int = 1            ## 推进方向（±1：左军 +1 / 右军 −1）
var goal_x: float = 0.0        ## 推进终点（世界 x，通常敌方阵地深处）
var line_x: float = 0.0        ## 近战组前列线（世界 x）
var stance: int = Stance.ATTACK
var speed: float = 110.0       ## 战线推进速度（px/s；< 步速 160，成员赶得上）
var band_center_y: float = 0.0
var band_half: float = 360.0

var _host: Node = null         ## FormationSystem 宿主（接战判定/间距真值）
var _spread: float = 110.0
var _row_gap: float = 80.0
var _upc_melee: int = 6        ## 近战组列高（随存活数自适应，见 _recompute_slots）
var _upc_ranged: int = 6       ## 远程组列高（同式，各组独立）

var _melee: Array = []
var _ranged: Array = []
var _slots_melee: Dictionary = {}   # iid -> Vector2i(col, row)
var _slots_ranged: Dictionary = {}
var _melee_blocked: bool = false
var _melee_clear_ticks: int = 0   ## 近战连续无接战拍数（停线/复推滞回）
var _ranged_clear_ticks: int = 0  ## 远程连续无接战拍数（冻结/解冻滞回）
var frozen_ranged_x: float = NAN  ## 远程组冻结线（世界 x；冻结期间不随推进移动）
var _contact_timer: float = 0.0

var _rng := RandomNumberGenerator.new()
var _y_drift: Dictionary = {}        # iid -> 当前漂移（px，叠加在槽位横排 y 上）
var _y_drift_target: Dictionary = {} # iid -> 目标漂移
var _y_next_shift: Dictionary = {}   # iid -> 距下次换目标（s）


## 装配（宿主注入当前间距真值——平衡表可覆盖，不缓存快照的宿主纪律同源）
func setup(host: Node, p_faction: int, p_facing: int, p_goal_x: float, p_line_x: float,
		p_band_center_y: float, p_band_half: float, spread: float, row_gap: float) -> void:
	_host = host
	faction = p_faction
	facing = p_facing
	goal_x = p_goal_x
	line_x = p_line_x
	band_center_y = p_band_center_y
	band_half = maxf(p_band_half, 100.0)
	_spread = maxf(spread, 40.0)
	_row_gap = maxf(row_gap, 40.0)
	_rng.seed = DRIFT_SEED_FALLBACK + p_faction


## 漂移种子注入（宿主可选：按 battle_id 派生传入——同战斗可复现、跨战斗不同相；
## 未调用用 setup 的 faction 混合回落种子，仍是确定序列）。须在 add_unit 前调。
func seed_drift(seed_value: int) -> void:
	_rng.seed = seed_value


## 成员入线（按主手武器分组：BOW=2/STAFF=4/MERIC=5 归远程组——SWL 层序
## CASTERS/ARCHERS/HEALERS 皆后置；其余近战；守位/指挥单位由调用方过滤，
## 不入线）。入线即建个性漂移账本（首漂零——短局几何断言稳定，首次换目标
## 最早 DRIFT_SHIFT_MIN 后）。
func add_unit(u: Node) -> void:
	if u == null or not is_instance_valid(u):
		return
	var w: Node = u.get_weapon() if u.has_method("get_weapon") else null
	var wt: int = int(w.weapon_type) if w != null and "weapon_type" in w else -1
	var iid: int = u.get_instance_id()
	if wt == 2 or wt == 4 or wt == 5:
		_ranged.append(u)
	else:
		_melee.append(u)
	_y_drift[iid] = 0.0
	_y_drift_target[iid] = 0.0
	_y_next_shift[iid] = _rng.randf_range(DRIFT_SHIFT_MIN, DRIFT_SHIFT_MAX)


# ─────────────────────── 推进 ───────────────────────

## 每帧驱动：接战节拍（检查/号令）+ 连续推进（ATTACK 且近战组未接战）。
## delta 为帧时长（暂停/减速由宿主 _process 天然联动——不跑就不推）。
func tick(delta: float) -> void:
	_cleanup()
	if _melee.is_empty() and _ranged.is_empty():
		return
	_contact_timer -= delta
	if _contact_timer <= 0.0:
		_contact_timer = CONTACT_TICK
		_recompute_slots()
		_update_contact()
		_issue_march_orders()
	_tick_y_drift(delta)
	if stance == Stance.ATTACK and not _melee_blocked:
		line_x += float(facing) * speed * delta
		if facing > 0:
			line_x = minf(line_x, goal_x)
		else:
			line_x = maxf(line_x, goal_x)


## 远程组前列线：冻结期用冻结线，否则随行近战组全纵深后 GROUP_GAP（动态——
## 近战纵深加长（含二线）时远程线跟着退，不叠进方阵后排）
func ranged_line_x() -> float:
	if not is_nan(frozen_ranged_x):
		return frozen_ranged_x
	return line_x - float(facing) * (melee_formation_depth() + GROUP_GAP)


## 近战组全纵深（含二线驻位；无成员 = 0）——远程随行距与出生几何共用
func melee_formation_depth() -> float:
	var max_col: int = -1
	for s in _slots_melee.values():
		max_col = maxi(max_col, (s as Vector2i).x)
	if max_col < 0:
		return 0.0
	return rank_depth(max_col, _row_gap)


## 单位的战线槽位（世界坐标；非成员/无槽位 = INF）。近战组贴 line_x，
## 远程组贴 ranged_line_x；同列沿带横展、后列沿面向反侧退（超纵深上限的
## 排隔 RESERVE_GAP 退 = 二线驻位）。
func get_unit_slot(u: Node) -> Vector2:
	if u == null or not is_instance_valid(u):
		return Vector2.INF
	var iid: int = u.get_instance_id()
	var slot: Vector2i = Vector2i(-1, -1)
	var base_x: float
	if _slots_melee.has(iid):
		slot = _slots_melee[iid]
		base_x = line_x
		return _slot_world(slot, base_x, iid, _upc_melee)
	elif _slots_ranged.has(iid):
		slot = _slots_ranged[iid]
		base_x = ranged_line_x()
		return _slot_world(slot, base_x, iid, _upc_ranged)
	return Vector2.INF


func get_line_x() -> float:
	return line_x


func is_melee_blocked() -> bool:
	return _melee_blocked


func melee_count() -> int:
	return _melee.size()


func ranged_count() -> int:
	return _ranged.size()


# ─────────────────────── 内部 ───────────────────────

## 个性 y 漂移推进（每帧：到点换目标 + 指数趋近；接战成员不受影响——漂移只
## 改槽位 y，接战者归战斗行为管，未接战者经随线号令自然小步挪过去 = SWL 缓慢
## 漂移的观感）。字典按入线序迭代，掷骰序确定 → 同种子序列可复现。
func _tick_y_drift(delta: float) -> void:
	if delta <= 0.0 or _y_drift.is_empty():
		return
	# 幅值上限：比例值与「椭圆余量半宽」取小，负值（椭球纵半径超出摆放间距，
	# 2026-10-14 起为常态：440 > 150）取 0——碰撞椭球接管排面松紧，个性漂移退场
	var limit: float = maxf(0.0, minf(_spread * DRIFT_MAX_RATIO,
			(_spread - _Spacing.SEPARATION_RADIUS_Y_BATTLE) * 0.5))
	for iid in _y_drift.keys():
		var wait: float = float(_y_next_shift[iid]) - delta
		if wait <= 0.0:
			_y_drift_target[iid] = _rng.randf_range(-limit, limit)
			wait = _rng.randf_range(DRIFT_SHIFT_MIN, DRIFT_SHIFT_MAX)
		_y_next_shift[iid] = wait
		var cur: float = float(_y_drift[iid])
		_y_drift[iid] = cur + (float(_y_drift_target[iid]) - cur) * minf(1.0, DRIFT_RATE * delta)


func _slot_world(slot: Vector2i, base_x: float, iid: int, upc: int) -> Vector2:
	var col: float = float(slot.x)
	var lateral: float = (float(slot.y) - float(upc - 1) * 0.5) * _spread
	return Vector2(base_x - float(facing) * rank_depth(slot.x, _row_gap),
			band_center_y + lateral + float(_y_drift.get(iid, 0.0)))


## 清理死亡/释放成员（槽位随重算回收；漂移账本同步清——防跨战斗泄漏）
func _cleanup() -> void:
	_melee = _melee.filter(func(u) -> bool:
		return is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()))
	_ranged = _ranged.filter(func(u) -> bool:
		return is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()))
	if not _y_drift.is_empty():
		var alive: Dictionary = {}
		for u in _melee + _ranged:
			alive[u.get_instance_id()] = true
		for iid in _y_drift.keys():
			if not alive.has(iid):
				_y_drift.erase(iid)
				_y_drift_target.erase(iid)
				_y_next_shift.erase(iid)


## 槽位重算（入队序 = 行列；组方阵整组一格一格排——SWL Formation 全组一个格）。
## 列高随存活数自适应（纵向铺满行动带：列数 = min(存活数, 带宽容列数)，带满
## 才加深纵深）；死亡重排即列高收缩/前顶补位（SWL FilterDownARandomRow 的
## 压实同源）
func _recompute_slots() -> void:
	_upc_melee = _group_upc(_melee.size())
	_upc_ranged = _group_upc(_ranged.size())
	_slots_melee = _lattice(_melee, _upc_melee)
	_slots_ranged = _lattice(_ranged, _upc_ranged)


func _group_upc(n: int) -> int:
	return mini(n, floori((band_half * 2.0) / _spread) + 1)


func _lattice(units: Array, upc: int) -> Dictionary:
	var slots: Dictionary = {}
	for i in units.size():
		slots[units[i].get_instance_id()] = Vector2i(
				floori(float(i) / float(upc)), i % upc)
	return slots


## 接战检查：近战组接战 = 停线；远程组首接战 = 冻结线（末列贴射程线）；
## 两者都带滞回（连续 ENGAGE_HYSTERESIS 拍无接战才解除）
func _update_contact() -> void:
	var melee_engaged: bool = false
	var ranged_engaged: bool = false
	for u in _melee:
		if _engaged(u):
			melee_engaged = true
			break
	for u in _ranged:
		if _engaged(u):
			ranged_engaged = true
			break
	# 近战线：接战停 / 脱战滞回后复推
	if melee_engaged:
		_melee_blocked = true
		_melee_clear_ticks = 0
	elif _melee_blocked:
		_melee_clear_ticks += 1
		if _melee_clear_ticks >= ENGAGE_HYSTERESIS:
			_melee_blocked = false
	# 远程线：首接战冻结（冻结线 = 最前接战投影 + 方阵纵深）；脱战滞回后解冻随行
	if ranged_engaged:
		_ranged_clear_ticks = 0
		if is_nan(frozen_ranged_x):
			frozen_ranged_x = _frozen_ranged_x()
	elif not is_nan(frozen_ranged_x):
		_ranged_clear_ticks += 1
		if _ranged_clear_ticks >= ENGAGE_HYSTERESIS:
			frozen_ranged_x = NAN


## 远程组冻结线：全组入射程——前列线 = 最前成员投影 + 方阵纵深（末列恰贴
## 首接战成员的射程线，前列更近照样打；与批5 班战斗锚同式，组级放大）。
## 纵深按战线块封顶（超上限的二线排在冻结线后照旧站得住）
func _frozen_ranged_x() -> float:
	var front: float = -1.0e9
	for u in _ranged:
		if "global_position" in u:
			front = maxf(front, u.global_position.x * float(facing))
	if front <= -1.0e8:
		return ranged_line_x()
	var depth: float = 0.0
	for s in _slots_ranged.values():
		depth = maxf(depth, rank_depth(
				mini((s as Vector2i).x, LINE_MAX_DEPTH - 1), _row_gap))
	return (front + depth) * float(facing)


## 成员主手射程内是否有存活敌（宿主接战判定复用——行为同源的单一口径）
func _engaged(u: Node) -> bool:
	if _host != null and _host.has_method("_member_enemy_in_range"):
		return _host._member_enemy_in_range(u)
	return false


## 未接战成员的随线号令（SWL 阵线跟走）：已接战/接管/撤退类/玩家号令跳过；
## 槽位死区内不重发（防 travel 重入抖动）；远距奔跑追赶。
func _issue_march_orders() -> void:
	_march_group(_melee, _slots_melee, line_x, _upc_melee)
	_march_group(_ranged, _slots_ranged, ranged_line_x(), _upc_ranged)


func _march_group(units: Array, slots: Dictionary, base_x: float, upc: int) -> void:
	for u in units:
		if u.has_method("is_user_controlled") and u.is_user_controlled():
			continue
		if _engaged(u):
			continue  # 接战成员：战斗行为接管
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai == null:
			continue
		if ai.has_method("get_current_behavior") \
				and ai.get_current_behavior() in ["retreat", "seek_cover"]:
			continue  # 撤退类行为，不拽回战线
		var slot: Vector2i = slots.get(u.get_instance_id(), Vector2i(-1, -1))
		if slot.x < 0:
			continue
		var dest: Vector2 = _slot_world(slot, base_x, u.get_instance_id(), upc)
		if (u as Node2D).global_position.distance_to(dest) <= LINE_DEADZONE:
			continue  # 阵位稳定（FormationPositionIsStable 同源防抖）
		# 已有他人号令（无 line_order/follow_order 标记 = 玩家/上级号令）→ 不覆盖
		if ai.has_method("has_order") and ai.has_order():
			var params: Dictionary = ai.get_ordered_params() if ai.has_method("get_ordered_params") else {}
			if not (params.get("line_order", false) or params.get("follow_order", false)):
				continue
			if ai.has_method("get_ordered_behavior") and ai.get_ordered_behavior() == "move" \
					and (params.get("target", Vector2.ZERO) as Vector2).distance_to(dest) <= LINE_DEADZONE:
				continue  # 号令在途且目标未漂出死区，防重入
		var dist: float = (u as Node2D).global_position.distance_to(dest)
		ai.set_order("move", {
			"target": dest,
			"engage_in_range": true,
			"run": dist > RUN_DIST,
			"hold_on_arrive": true,
			"line_order": true,
		})
