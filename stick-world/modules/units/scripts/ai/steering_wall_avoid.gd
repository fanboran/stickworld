class_name SteeringWallAvoid
extends RefCounted
## 静态障碍局部避障（寻路方案A 核心，调研 `docs/技术/架构/寻路避障调研.md`
## §二A / §三 P0）：切向滑动 + 短时绕行意向 + 卡住升级上报。
##
## 原理（不铺 A*，村落级障碍"绕半步就能过"的几何前提）：
## 1. 切向滑动：读 move_and_slide 的碰撞法线，把移动意图投影到墙面切线——
##    斜碰沿墙滑（监狱建筑师 / RimWorld wall-slide 模型）；
## 2. 短时绕行意向：正对面墙（切向分量趋零）时注入一段沿墙回避方向，期间
##    压制"指向目标"的原始方向；实例奇偶拆半选侧（同让路/绕行族惯例），
##    卡住触发即换侧重织（冷却防左右抽搐）；
## 3. 卡住升级：目标进度停滞 + 持续推墙累计超 GIVE_UP 时限 → 判"目标不可达"
##    上报（行为层 finish 换目标，把不可达从"无限推墙"变成"有限尝试后失败"）。
##
## 作用域红线（战斗语义零破坏）：只处理静态墙（非 CharacterBody2D 碰撞体），
## 不碰敌挡路接战/单位分离推挤——敌方单位挡路归 behavior_move 遇阻接战
##（_handle_path_block），友军归 entity_motion 让路/分离。
##
## 性能：自带 0.2s 节流拍（AI 决策冷却内做，不每帧全量）；碰撞结果读取零
## 成本（move_and_slide 已算好），无 raycast 无邻居扫描。
##
## 纯方向修正组件：不改速度、不 finish 行为（不可达判定只置位 is_unreachable，
## 由消费方行为决定是否放弃——engage_in_range 战斗推进令消费方不放弃）。

const ScriptStuck := preload("res://modules/units/scripts/ai/steering_stuck.gd")

# ─────────────────────── 参数（【提案/待定·待实测校准】，观察场调参）───────────────────────
## 扫描节流间隔（s）：与 behavior_move 接敌拍同频（0.2s 量级）
const SCAN_INTERVAL: float = 0.2
## 推墙判定：意图与墙法线点积低于此（负值，越负越对顶）才算"往墙上怼"
const PUSH_DOT: float = -0.2
## 切向分量下限（归一）：投影切向长度低于此 = 正对面墙（滑动救不了，需绕行）
const TANGENT_MIN: float = 0.25
## 绕行意向持续时长（s，调研带 0.3~1s）：到期重评估，仍对顶则续织
const DETOUR_DURATION: float = 0.8
## 目标进度下限（px/s）：低于此视为"没在接近目标"（滑墙期最差 ~25% 速度 ≈40px/s，
## 12 是走速下的零头阈值——只区分"有进展/停摆"）
const PROGRESS_MIN: float = 12.0
## 持续推墙放弃时限（s）：验收口径"不允许 >5s 的持续推墙"（寻路调研 §三）
const GIVE_UP_TIME: float = 5.0

## 所属实体（读滑动碰撞 + 实例奇偶；构造注入，不参与引用计数）
var _entity: Node = null
## 卡住检测三件套（公共组件，wander 同款）
var _stuck: RefCounted = null
## 扫描节流累计器（未满一拍不扫描）
var _scan_accum: float = 0.0
## 目标进度采样（上拍目标距离；目标变更时复位）
var _goal: Vector2 = Vector2(NAN, NAN)
var _last_goal_dist: float = INF
## 累计推墙时长（有目标进度即衰减，防短暂擦碰累积误杀）
var _push_time: float = 0.0
## 目标不可达（升级终态；arm/目标变更复位）
var _unreachable: bool = false
## 当前切向滑动方向（斜碰时应用；无墙接触清零）
var _tangent: Vector2 = Vector2.ZERO
## 绕行意向状态：方向 + 剩余时长 + 侧别（卡住换侧用）
var _detour_dir: Vector2 = Vector2.ZERO
var _detour_left: float = 0.0
var _detour_side: int = 0


func _init(entity: Node) -> void:
	_entity = entity
	_stuck = ScriptStuck.new()


# ─────────────────────── 生命周期 ───────────────────────

## 行为进入/目标切换时复位（目标变更 update 内自动检测，显式调用用于 enter）。
func arm() -> void:
	_scan_accum = 0.0
	_last_goal_dist = INF
	_push_time = 0.0
	_unreachable = false
	_tangent = Vector2.ZERO
	_detour_dir = Vector2.ZERO
	_detour_left = 0.0
	_detour_side = 0
	if _entity != null and is_instance_valid(_entity):
		_stuck.arm(_entity.global_position)


# ─────────────────────── 主入口 ───────────────────────

## 逐拍推进（自带 0.2s 节流）：维护切向/绕行意向与卡住升级。dir_n = 当前移动
## 意图（归一），goal = 本次移动目标点。行为层每 update 调用即可（内部摊销）。
func update(delta: float, dir_n: Vector2, goal: Vector2) -> void:
	if _entity == null or not is_instance_valid(_entity):
		return
	# 目标切换（搬运两段/换工位）：全部进度类状态复位，绕行意向保留可继续用
	if goal != _goal:
		_goal = goal
		_last_goal_dist = INF
		_push_time = 0.0
		_unreachable = false
	_scan_accum += delta
	if _scan_accum < SCAN_INTERVAL:
		return
	var beat: float = _scan_accum
	_scan_accum = 0.0
	_scan(beat, dir_n, goal)


## 应用避障方向修正（每 update 拍调用）：绕行意向 > 切向滑动 > 原方向。
func steer(delta: float, dir_n: Vector2) -> Vector2:
	if _detour_left > 0.0:
		_detour_left -= delta
		if _detour_dir != Vector2.ZERO:
			return _detour_dir
	if _tangent != Vector2.ZERO:
		return _tangent
	return dir_n


## 目标是否已判定不可达（升级终态；消费方决定放弃与否——engage 推进令不放弃）。
func is_unreachable() -> bool:
	return _unreachable


## 是否正在绕行意向中（观测面：调试 HUD/测试断言）。
func is_detouring() -> bool:
	return _detour_left > 0.0


## 累计推墙时长（观测面）。
func push_time() -> float:
	return _push_time


# ─────────────────────── 内部 ───────────────────────

## 节流拍扫描（全部决策在此拍内做——性能红线：不每帧全量）。
func _scan(beat: float, dir_n: Vector2, goal: Vector2) -> void:
	var pos: Vector2 = _entity.global_position
	var goal_dist: float = pos.distance_to(goal)
	# 目标进度（本拍接近量换算 px/s；INF 首拍只采样）
	var progress: float = INF
	if _last_goal_dist < INF:
		progress = (_last_goal_dist - goal_dist) / beat
	_last_goal_dist = goal_dist

	# 墙接触读取：物理碰撞法线 + 行走带边界虚拟墙（clamp 不产生碰撞，顶边界的
	# 单位同样会无限推——虚拟法线让 clamp 盲区走同一条避障链）
	var normals: Array = fetch_wall_normals()
	var vn: Vector2 = _virtual_edge_normal(dir_n)
	if vn != Vector2.ZERO:
		normals.append(vn)
	var n: Vector2 = Vector2.ZERO
	var best_dot: float = 0.0
	for m in normals:
		var d: float = dir_n.dot(m)
		if d < best_dot:
			best_dot = d
			n = m
	var pushing: bool = n != Vector2.ZERO and best_dot < PUSH_DOT

	if pushing:
		# 切向投影（dir 去掉法向分量 = 沿墙分量）
		var slide: Vector2 = dir_n - n * best_dot
		var slide_len: float = slide.length()
		if slide_len >= TANGENT_MIN:
			# 斜碰：沿墙滑（切向方向应用，不织绕行意向）
			_tangent = slide / slide_len
		else:
			# 正对面墙：切向救不了 → 短时绕行意向（无活跃意向则起一个）
			_tangent = Vector2.ZERO
			if _detour_left <= 0.0:
				_pick_detour(n, dir_n)
	else:
		_tangent = Vector2.ZERO

	# 推墙时长账本：接触墙 + 无目标进度才累计（滑墙有进展不罚）；否则衰减
	var stalled: bool = progress == INF or progress < PROGRESS_MIN
	if pushing and stalled:
		_push_time += beat
	else:
		_push_time = maxf(0.0, _push_time - beat * 2.0)

	# 卡住三件套（公共组件）：完全没动 → 换侧重织绕行（同侧绕不动换反侧再试）
	if _stuck.tick(beat, pos):
		if _detour_left > 0.0 and _detour_dir != Vector2.ZERO:
			_detour_dir = -_detour_dir
			_detour_side = -_detour_side if _detour_side != 0 else _parity_side()
			_detour_left = DETOUR_DURATION
		elif pushing:
			_pick_detour(n, dir_n)

	# 升级终态：推墙停滞累计超限 → 目标不可达（有限尝试后上报，不再无限推）
	if _push_time >= GIVE_UP_TIME:
		_unreachable = true
		_detour_dir = Vector2.ZERO
		_detour_left = 0.0
		_tangent = Vector2.ZERO


## 读取静态墙法线（过滤单位碰撞体——敌我单位归接战/分离系统，本组件只管墙）。
## 测试子类覆写本方法注入虚拟墙面（KinematicCollision2D 无法从脚本构造）。
func fetch_wall_normals() -> Array:
	var out: Array = []
	var count: int = _entity.get_slide_collision_count()
	for i in count:
		var col: Variant = _entity.get_slide_collision(i)
		if col == null:
			continue
		var collider = col.get_collider()
		if collider != null and collider is CharacterBody2D:
			continue  # 单位碰撞（battle 期互撞）：非墙
		var nrm: Vector2 = col.get_normal()
		if nrm != Vector2.ZERO:
			out.append(nrm)
	return out


## 行走带边界虚拟墙法线（clamp 盲区）：实体 Y/X 越界由每帧钳位兜底（无碰撞
## 法线），目标在带外的单位会顶着钳位无限推。贴近边界且意图朝外时返回指向
## 带内的虚拟法线，走同一条切向/绕行/升级链。边界口径与 entity 钳位一致
##（origin space 旗标 defensive 读，缺省按 2D 图内收 foot_offset）。
func _virtual_edge_normal(dir_n: Vector2) -> Vector2:
	if not ("ground_y" in _entity) or not ("ground_bottom" in _entity):
		return Vector2.ZERO
	var origin_space: bool = true
	if "_ground_constraints_origin_space" in _entity:
		origin_space = bool(_entity.get("_ground_constraints_origin_space"))
	var foot: float = float(_entity.get("foot_offset")) if "foot_offset" in _entity else 0.0
	var off: float = 0.0 if origin_space else foot
	var y_min: float = float(_entity.ground_y) - off
	var y_max: float = float(_entity.ground_bottom) - off
	var margin: float = 8.0
	var pos: Vector2 = _entity.global_position
	if pos.y <= y_min + margin and dir_n.y < 0.0:
		return Vector2(0, 1)  # 顶边界（带深处）：虚拟墙法线指向带内
	if pos.y >= y_max - margin and dir_n.y > 0.0:
		return Vector2(0, -1)  # 底边界（前景边）
	if "map_left" in _entity and "map_right" in _entity:
		if pos.x <= float(_entity.map_left) + margin and dir_n.x < 0.0:
			return Vector2(1, 0)
		if pos.x >= float(_entity.map_right) - margin and dir_n.x > 0.0:
			return Vector2(-1, 0)
	return Vector2.ZERO


## 织绕行意向：沿墙切向 ± 侧别（与目标方向同侧优先，正对时实例奇偶拆半——
## 与 entity_motion 让路/遇阻绕行同一拆半惯例，人群自然分流不齐刷刷同侧）。
func _pick_detour(n: Vector2, dir_n: Vector2) -> void:
	var t := Vector2(-n.y, n.x)
	var along: float = t.dot(dir_n)
	if absf(along) > 0.05:
		_detour_side = 1 if along > 0.0 else -1
	else:
		_detour_side = _parity_side()
	_apply_detour_side(n, _detour_side)


func _apply_detour_side(n: Vector2, side: int) -> void:
	if n == Vector2.ZERO or side == 0:
		return
	var t := Vector2(-n.y, n.x)
	_detour_dir = t * float(side)
	_detour_left = DETOUR_DURATION


## 实例奇偶拆半（一半向左一半向右）。
func _parity_side() -> int:
	if _entity == null:
		return 1
	return 1 if _entity.get_instance_id() % 2 == 0 else -1
