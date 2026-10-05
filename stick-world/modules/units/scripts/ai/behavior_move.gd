class_name BehaviorMove
extends BehaviorBase
## 移动行为 -- 向目标点直线移动，到达后完成。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §7.2。
## P0 阶段为简单直线移动，不做 A* 寻路（障碍由 entity 的通行障碍检测处理）。
## params 必填字段：
##   - target: Vector2  目标位置（世界坐标）
## 可选字段：
##   - run: bool  是否奔跑（默认 false）
##   - engage_in_range: bool  接敌即战（敌人进入武器射程即打断移动转战斗）
##   - hold_on_arrive: bool  到位驻留（编队动态跟队锚定用）：到达后行为不完成，
##     站桩待命压制 AI 战斗决策"擅自冲锋"，敌人进射程（engage_in_range）仍打断
##   - catching_up: bool  追赶队形（编队跟队/列阵下发，SWL UpdateCatchingUpToFormation）：
##     落后槽位过远的归位跑——收盾疾跑，落定后恢复行军盾

## 兵种行为档案（formation_block：盾兵行军盾不放下）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 运动助手常量源（遇阻接战复用让路锥面口径：YIELD_AHEAD_DOT / YIELD_LATERAL_FORCE，
## 单一真相源不复制数值；entity_motion 与本类同属 units 模块，无跨模块依赖）
const ScriptEntityMotion := preload("res://modules/units/scripts/entity/entity_motion.gd")

## 到达目标的距离阈值（像素）
const ARRIVAL_THRESHOLD: float = 20.0
## 列阵到位滞留时长（秒；编队成员到达时播 arrive 动画后停留，AI 完善批次 4）
const ARRIVE_HOLD_DURATION: float = 0.4
## 接敌检查节流间隔（秒）
const ENGAGE_CHECK_INTERVAL: float = 0.2

# ── 遇阻接战（创始人口径：前往任务目标的路上被敌人拦住且无法简单绕过，就像一般
#    RTS 一样攻击路径上的敌人；寻路 = 局部绕行 + 遇阻接战组合，不做 A*）──
## 工作类型（与 AIController.WorkTypeCombat 同值，本地常量避免跨类依赖）
const WorkTypeCombat := "WORK_COMBAT"
## 挡路判定距离（px）【提案/待定·待实测校准】：前进锥面内此距离内的敌方单位算"拦路者"
const BLOCKER_SCAN_DIST: float = 180.0
## 绕行空隙判定窗（px）【提案/待定·待实测校准】：侧向探测点与自身的距离
const DETOUR_GAP_WINDOW: float = 120.0
## 绕行侧净空半径（px）【提案/待定·待实测校准】：探测点此范围内有存活单位即该侧被占
##（量级贴单位体宽——双侧都探不到净空 = 密集战线，"无法简单绕过"）
const DETOUR_GAP_CLEAR_RADIUS: float = 40.0
## 敌已接战判定距离（px）【提案/待定·待实测校准】：拦路者贴进此距离即身体接触
##（分离椭圆双轴量级），绕行已无物理空隙 → 直接转入攻击
const BLOCKER_CONTACT_DIST: float = 70.0
## 绕行放弃时限（s）【提案/待定·待实测校准】：连续绕行累计超此时长仍被拦 → 转入
## 攻击（拦路者跟着平移的"绕不上"僵局兜底；绕行成功即清零重计）
const DETOUR_GIVE_UP_TIME: float = 3.0

## 目标位置（世界坐标）
var _target: Vector2 = Vector2.ZERO
## 是否奔跑
var _running: bool = false
## 是否已到达目标（hold_on_arrive 驻留态标记）
var _arrived: bool = false
## 到位驻留（编队动态跟队锚定）：到达后不 finish，原地待命
var _hold_on_arrive: bool = false
## 列阵到位滞留倒计时（>0 表示已到达正在播 arrive）
var _arrive_hold: float = 0.0
## 接敌即战（号令 engage_in_range=true 时启用）：敌人进入武器射程即打断移动
var _engage_in_range: bool = false
## 接敌检查计时器
var _engage_check_timer: float = 0.0
## 行军举盾开关（档案 formation_block：SWL UpdateBlockWhenInFormation）
var _formation_blocking: bool = false
## 追赶队形（SWL UpdateCatchingUpToFormation 直译，11b）：归位跑收盾，落定恢复端盾
var _catching_up: bool = false
## 遇阻接战：当前绕行横向分量（帧间持有，与 entity_motion 让路缓存同语义——
## 扫描与节流拍同频刷新，移动每拍叠加；无绕行 = 零向量）
var _detour_lateral: Vector2 = Vector2.ZERO
## 遇阻接战：连续绕行累计时长（s，"绕行超阈值转接战"的计时源）
var _detour_elapsed: float = 0.0


func _ready() -> void:
	behavior_name = "move"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	if params.has("target"):
		_target = params["target"]
	else:
		_target = entity.global_position if entity != null else Vector2.ZERO
	_running = params.get("run", false)
	_engage_in_range = params.get("engage_in_range", false)
	_hold_on_arrive = params.get("hold_on_arrive", false)
	_catching_up = params.get("catching_up", false)
	_arrived = false
	_engage_check_timer = 0.0
	_detour_lateral = Vector2.ZERO
	_detour_elapsed = 0.0
	_update_formation_block(true)


func exit(next: String) -> void:
	# 退出行军收盾：战斗行为会按姿态聚合重新决策举盾
	_update_formation_block(false)
	super.exit(next)


## 行军举盾（SWL UpdateBlockWhenInFormation 直译）：档案 formation_block=true 的
## 盾兵在行军/待命全程举盾（Spearton 端盾行军姿态），进战斗后由 attack 行为接管。
## 追赶归位跑不举盾（SWL UpdateBlockWhenInFormation(isCatchingUpToFormation)：
## 落后收盾疾跑），落定后由到达分支恢复端盾
func _update_formation_block(on: bool) -> void:
	if on == _formation_blocking:
		return
	if on and _catching_up:
		return  # 追赶中不端盾（落定后到达分支再开）
	var weapon: Node = entity.get_weapon() if entity != null and entity.has_method("get_weapon") else null
	if weapon == null or not weapon.has_method("set_blocking"):
		return
	var wt: int = int(weapon.weapon_type) if "weapon_type" in weapon else -1
	if on and bool(ScriptBehaviorProfiles.get_profile(wt).get("formation_block", false)):
		_formation_blocking = true
		weapon.set_blocking(true)
	else:
		_formation_blocking = false
		weapon.set_blocking(false)


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return

	# 接敌/挡路节流拍（同拍共享 0.2s）：遇阻接战扫描优先于"接敌即战"——路径上
	# 的敌人按 绕行/打通/走射 处置（号令粘性，finish 会清令所以不走）；只有无挡路
	# 时敌人进武器射程才走既有接敌即战 finish。锚定驻留/到位态保留既有"敌进射程
	# 打断"语义（驻留无移动意图，无挡路概念，不走遇阻扫描）
	var moving: bool = not _arrived and _arrive_hold <= 0.0 \
			and entity.global_position.distance_to(_target) > ARRIVAL_THRESHOLD
	_engage_check_timer -= delta
	if _engage_check_timer <= 0.0:
		_engage_check_timer = ENGAGE_CHECK_INTERVAL
		if moving:
			var scan_dir: Vector2 = (_target - entity.global_position).normalized()
			var block: Dictionary = _scan_forward_blockers(scan_dir)
			if float(block.get("mag", 0.0)) > 0.0:
				_handle_path_block(block, scan_dir)
				# 打通请求已切行为（travel attack 同步 exit 本行为）→ 本拍终止
				if not _active or _finished:
					return
			elif _engage_in_range and _enemy_in_weapon_range():
				if entity.has_method("ai_stop"):
					entity.ai_stop()
				finish()
				return
		elif _engage_in_range and _enemy_in_weapon_range():
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return

	# 到达后的列阵到位滞留（AI 完善批次 4）：播 arrive 立正动画，播完再 finish；
	# hold_on_arrive（编队动态跟队）滞留结束不 finish，转入下方驻留分支
	if _arrive_hold > 0.0:
		_arrive_hold -= delta
		if _arrive_hold <= 0.0 and not _hold_on_arrive:
			finish()
			if entity.has_method("ai_stop"):
				entity.ai_stop()
		return

	# 到位驻留（hold_on_arrive，编队动态跟队）：站桩待命、行为不完成——
	# 号令持续占用决策（压制"无令时战斗决策擅自冲锋"），敌人进射程由上方接敌检查打断
	if _arrived:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return

	var pos: Vector2 = entity.global_position
	var dist: float = pos.distance_to(_target)

	# 到达目标
	if dist <= ARRIVAL_THRESHOLD:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_arrived = true
		# 追赶落定（11b）：恢复行军端盾（SWL 落位后 UpdateBlockWhenInFormation 端盾）
		if _catching_up:
			_catching_up = false
			_update_formation_block(true)
		# 编队成员到达队形位 → 播列阵动画并短暂滞留（对应传奇 ArriveAtFormationAnimationSystem）
		if _is_squad_member():
			if entity.has_method("play_arrive"):
				entity.play_arrive()
			_arrive_hold = ARRIVE_HOLD_DURATION
		elif not _hold_on_arrive:
			finish()
		return

	# 计算移动方向并驱动 entity（叠加遇阻绕行横分量——与目标方向点乘恒 0，不减速）
	var dir: Vector2 = (_target - pos).normalized()
	var move_dir: Vector2 = dir
	if _detour_lateral != Vector2.ZERO:
		move_dir = (dir + _detour_lateral).normalized()
	if entity.has_method("ai_move"):
		entity.ai_move(move_dir, _running)


## 是否有活跃敌人进入主手武器射程（进入即停推进，交由战斗行为接管）
func _enemy_in_weapon_range() -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if not entity.has_method("get_battle_instance"):
		return false
	var bi: Node = entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi) \
			or not bi.has_method("is_active") or not bi.is_active():
		return false
	var faction: int = entity.get_faction() if entity.has_method("get_faction") else 0
	if faction == 0 or not bi.has_method("get_enemies_of"):
		return false
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if entity.global_position.distance_to(e.global_position) <= attack_range:
			return true
	return false


## 是否编队成员（AI 完善批次 4）：有 formation 且属于某小队 → 到达时播列阵动画。
func _is_squad_member() -> bool:
	if entity == null or not entity.has_method("get_formation_system"):
		return false
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_squad"):
		return false
	return not fs.get_unit_squad(entity).is_empty()


# ─────────────────────── 遇阻接战（局部绕行 + 打通，不做 A*）───────────────────────

## 遇阻处置（决策序，创始人口径）：敌人挡在前进锥面内时——
##   ③ 远程特例（弓/杖）：拦路者在射程内 → 边走边射不停车（复用 kite 边打边走的
##      同款衔接；不进 attack 行为即不触发后撤风筝/持瞄节奏，两条链路不打架）；
##   ① 侧向有空隙 → 局部绕行（复用 entity_motion 让路的横分量几何，敌挡路版）；
##   ② 无法简单绕过（两侧被占 / 敌已贴身接战 / 绕行超时限）→ 请求 AIController
##      转入攻击拦路者（"打通"态：原号令挂起不清，击杀/脱离后自动续行赶路）。
func _handle_path_block(block: Dictionary, dir: Vector2) -> void:
	var nearest: Node = block.get("nearest")
	# ③ 远程特例：射程内直接还击 → 边走边射，绕行分量照给（有隙绕着走）
	if _ranged_walk_by_shot(nearest):
		_detour_elapsed = 0.0
		_detour_lateral = _detour_component_if_gap(block, dir)
		return
	# ② 前置否决：敌已贴身（身体接触，绕行无物理空隙）或绕行超时限 → 不再绕
	var contact: bool = float(block.get("nearest_dist", INF)) <= BLOCKER_CONTACT_DIST
	var expired: bool = _detour_elapsed >= DETOUR_GIVE_UP_TIME
	var gap_side: float = 0.0
	if not contact and not expired:
		gap_side = _probe_detour_gap(dir, float(block.get("side", 0.0)))
	if gap_side != 0.0:
		# ① 局部绕行（空隙侧横分量偏航；累计时长供"绕行超阈值"兜底转攻击）
		_detour_elapsed += ENGAGE_CHECK_INTERVAL
		_detour_lateral = _lateral_component(dir, float(block.get("mag", 0.0)), gap_side)
		return
	# ② 转入攻击拦路者（打通态）
	_detour_lateral = Vector2.ZERO
	_detour_elapsed = 0.0
	_request_breach(nearest)


## 侧向有空隙时的绕行分量（探测不可绕 = 零向量直进）。
func _detour_component_if_gap(block: Dictionary, dir: Vector2) -> Vector2:
	var gap_side: float = _probe_detour_gap(dir, float(block.get("side", 0.0)))
	if gap_side == 0.0:
		return Vector2.ZERO
	return _lateral_component(dir, float(block.get("mag", 0.0)), gap_side)


## 请求转入打通接战（duck 调 AIController；控制器不可用/拒绝则维持直进——
## 行为退化回既有"顶着走"语义，不硬失败）。
func _request_breach(blocker: Node) -> void:
	if blocker == null or not is_instance_valid(blocker) or not _combat_capable():
		return
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_ai_controller"):
		return
	var ai: Node = entity.get_ai_controller()
	if ai == null or not is_instance_valid(ai) or not ai.has_method("request_breach_engagement"):
		return
	ai.request_breach_engagement(blocker)


## 战斗职责过滤（镜像 AIController._can_work(WorkTypeCombat) 口径）：非战斗职责
##（工人队等）不走射不接战，被拦时只绕行/顶着走。
func _combat_capable() -> bool:
	if entity == null or not entity.has_method("get_formation_system"):
		return true
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("is_work_allowed"):
		return true
	return fs.is_work_allowed(entity, WorkTypeCombat)


## 前进锥面拦路者扫描（锥面口径同 entity_motion 友军让路：前向点积 >
## YIELD_AHEAD_DOT，敌我区分——faction 不同且非中立才算敌）。返回
## {mag, side, nearest, nearest_dist}：mag/side = 挡路强度与左右偏向累计
##（权重 = 距离衰减 × 前向点积，同让路几何），nearest = 最近拦路者；
## 无拦路 mag = 0。
func _scan_forward_blockers(dir_n: Vector2) -> Dictionary:
	var out: Dictionary = {"mag": 0.0, "side": 0.0, "nearest": null, "nearest_dist": INF}
	if entity == null or not is_instance_valid(entity) or dir_n == Vector2.ZERO:
		return out
	var my_pos: Vector2 = entity.global_position
	for e in _enemy_candidates(my_pos, BLOCKER_SCAN_DIST):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var to: Vector2 = e.global_position - my_pos
		var dist: float = to.length()
		if dist <= 0.001:
			continue  # 完全重叠（静态分离正在推开）：锥面方向无定义，交由分离处理
		var ahead: float = to.dot(dir_n) / dist
		if ahead <= ScriptEntityMotion.YIELD_AHEAD_DOT:
			continue
		var w: float = (1.0 - minf(dist / BLOCKER_SCAN_DIST, 1.0)) * ahead
		if w <= 0.0:
			continue
		out["mag"] = float(out["mag"]) + w
		# cross(意图方向, 拦路者相对位) 判偏向（Godot 2D y 向下，同让路口径）
		out["side"] = float(out["side"]) + signf(dir_n.x * to.y - dir_n.y * to.x) * w
		if dist < float(out["nearest_dist"]):
			out["nearest"] = e
			out["nearest_dist"] = dist
	return out


## 敌对单位候选集（性能：地图空间网格邻域查询优先，无地图回落战斗名单全扫——
## 与 ai_controller._count_enemies_near 同构；faction 0 中立不算敌）。
func _enemy_candidates(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	var faction: int = entity.get_faction() if entity.has_method("get_faction") else 0
	if faction == 0:
		return out
	var map: Node = entity.get_map() if entity.has_method("get_map") else null
	if map != null and is_instance_valid(map) and map.has_method("query_neighbors"):
		for e in map.query_neighbors(pos, radius):
			if _is_alive_enemy(e, faction):
				out.append(e)
		return out
	if entity.has_method("get_battle_instance"):
		var bi: Node = entity.get_battle_instance()
		if bi != null and is_instance_valid(bi) and bi.has_method("get_enemies_of"):
			for e in bi.get_enemies_of(faction):
				if _is_alive_enemy(e, faction) \
						and pos.distance_to(e.global_position) <= radius:
					out.append(e)
	return out


## 存活敌对单位判定（有效性 → 活体 → 有阵营 → 异阵营非中立）。
func _is_alive_enemy(e: Variant, faction: int) -> bool:
	if e == null or not is_instance_valid(e) or e == entity:
		return false
	if not (e is Node2D):
		return false
	if e.has_method("is_dead") and e.is_dead():
		return false
	if not e.has_method("get_faction"):
		return false
	var ef: int = e.get_faction()
	return ef != 0 and ef != faction


## 侧向空隙判定（返回可绕侧 ±1；两侧皆被占返回 0）：探测点 = 位置 + 垂直向 ×
## 绕行窗，净空半径内无存活单位 = 该侧可绕。优先挡路者权重反侧（side 投票同
## 让路几何），对称僵局（side≈0）按实例奇偶拆半——一半向左一半向右自然分流。
## 探测通道不可用（无地图且无战斗名单）→ 视为可绕：绕行只是横分量偏航，行不通
## 由放弃时限兜底转攻击，不因探测缺载而顶死。
func _probe_detour_gap(dir: Vector2, blocker_side: float) -> float:
	var perp := Vector2(-dir.y, dir.x)
	var prefer := -signf(blocker_side)
	if prefer == 0.0:
		prefer = 1.0 if entity.get_instance_id() % 2 == 0 else -1.0
	if _gap_free_at(entity.global_position + perp * prefer * DETOUR_GAP_WINDOW):
		return prefer
	if _gap_free_at(entity.global_position - perp * prefer * DETOUR_GAP_WINDOW):
		return -prefer
	return 0.0


## 探测点净空判定：净空半径内有任何存活单位（敌我不分——友军拥挤同样绕不过去）
## 即被占。地图网格查询优先，回落战斗敌我名单全扫，都不可用返回 true（视为空）。
func _gap_free_at(point: Vector2) -> bool:
	if entity == null or not is_instance_valid(entity):
		return true
	var faction: int = entity.get_faction() if entity.has_method("get_faction") else 0
	var map: Node = entity.get_map() if entity.has_method("get_map") else null
	if map != null and is_instance_valid(map) and map.has_method("query_neighbors"):
		for u in map.query_neighbors(point, DETOUR_GAP_CLEAR_RADIUS):
			if _is_alive_unit(u):
				return false
		return true
	if entity.has_method("get_battle_instance"):
		var bi: Node = entity.get_battle_instance()
		if bi != null and is_instance_valid(bi) and faction != 0:
			if bi.has_method("get_enemies_of"):
				for u in bi.get_enemies_of(faction):
					if _is_alive_unit(u) \
							and u.global_position.distance_to(point) <= DETOUR_GAP_CLEAR_RADIUS:
						return false
			if bi.has_method("get_allies_of"):
				for u in bi.get_allies_of(faction):
					if _is_alive_unit(u) \
							and u.global_position.distance_to(point) <= DETOUR_GAP_CLEAR_RADIUS:
						return false
	return true


## 存活单位判定（净空用：有效性 → 活体；不问阵营）。
func _is_alive_unit(u: Variant) -> bool:
	if u == null or not is_instance_valid(u) or u == entity:
		return false
	if not (u is Node2D):
		return false
	return not (u.has_method("is_dead") and u.is_dead())


## 绕行横分量（复用 entity_motion._ally_yield_lateral 几何，敌挡路版）：
## 方向 = 移动意图的垂直向（与目标方向点乘恒 0，不减速不顶牛），权重 =
## 挡路强度（距离 × 前向点积，同让路衰减）× YIELD_LATERAL_FORCE，侧别取空隙侧。
func _lateral_component(dir: Vector2, mag: float, gap_side: float) -> Vector2:
	var perp := Vector2(-dir.y, dir.x)
	var s := signf(gap_side)
	if s == 0.0:
		s = 1.0 if entity.get_instance_id() % 2 == 0 else -1.0
	if s < 0.0:
		perp = -perp
	return perp * (minf(mag, 1.0) * ScriptEntityMotion.YIELD_LATERAL_FORCE)


## ③ 远程走射特例（弓/杖）：拦路者在射程内 → 边走边射不停车。复用 kite 边撤边打
## 的同款衔接（前摇/弹道与移动解耦，冷却好即面向拦路者出手），不进 attack 行为就
## 不会触发风筝后撤/持瞄节奏，两条链路不打架。返回 true = 本拦路情形由走射处置
##（不再做绕行放弃判定/不转打通）。
func _ranged_walk_by_shot(blocker: Node) -> bool:
	if blocker == null or not is_instance_valid(blocker) or not _combat_capable():
		return false
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	if weapon == null or not is_instance_valid(weapon) or not ("weapon_type" in weapon):
		return false
	var wt: int = int(weapon.weapon_type)
	if wt != ScriptBehaviorProfiles.BOW and wt != ScriptBehaviorProfiles.STAFF:
		return false
	var attack_range: float = weapon.attack_range if "attack_range" in weapon else 0.0
	if entity.global_position.distance_to(blocker.global_position) > attack_range:
		return false
	# 冷却好就回头放一击（移动不停——velocity 由本拍 ai_move 意图驱动）
	if weapon.has_method("can_attack") and weapon.can_attack() and weapon.has_method("perform_attack"):
		face_target(blocker)
		weapon.perform_attack(blocker)
	return true
