class_name BehaviorHaul
extends BehaviorBase
## 搬运行为 -- 工人从仓库取建材运往工地。
##
## 工人持 Job 板的 haul 任务（项目缺料时由 WorkCrewAssigner 派发）时进入此行为：
##   1. 走向最近的仓库（TO_WAREHOUSE）
##   2. 取货后走向工地（TO_SITE）
##   3. 到达工地交付建材（project.deliver_material）
##   4. 若仍需材料则继续往返，否则 finish
##
## params 必需字段：
##   - project: 建造项目对象（由 construction 模块经 AIController 注入；本行为只做鸭子类型调用，
##     不引用 construction 内部类，保持 units→construction 无编译期依赖）
##
## 多工人各自往返（不限制搬运工数量）；搬运时切换为 carry 动画。
## 移动接入静态障碍避障（寻路方案A，steering_wall_avoid）：直线驱动叠加切向
## 滑动/绕行意向；持续受阻（推墙/被占位绕圈）超限判不可达 finish（决策层
## 重派），不再无限推墙。


# ─────────────────────────────── 常量 ────────────────────────────────
const CELL_SIZE: float = PlacementMetrics.CELL_PX
const ARRIVE_THRESHOLD: float = 28.0
const WORK_OFFSET_Y: float = 40.0

const ScriptWallAvoid := preload("res://modules/units/scripts/ai/steering_wall_avoid.gd")

# ─────────────────────────────── 状态 ────────────────────────────────
enum Phase { TO_WAREHOUSE, PICKING, TO_SITE, DELIVERING }

## 取货停留时间（秒）
const PICK_DURATION: float = 0.5
## 交付停留时间（秒）
const DELIVER_DURATION: float = 0.5

# ─────────────────────────────── 运行时 ────────────────────────────────
var _project: Variant = null
var _warehouse: Node2D = null
var _phase: int = Phase.TO_WAREHOUSE
var _warehouse_pos: Vector2 = Vector2.ZERO
var _site_pos: Vector2 = Vector2.ZERO
var _action_timer: float = 0.0
## 静态障碍避障组件（enter 懒初始化——直构造不进树的测试路径同样可用）
var _wall_avoid: RefCounted = null


func _ready() -> void:
	behavior_name = "haul"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_project = params.get("project", null)
	if _project == null:
		finish()
		return
	_warehouse = _find_warehouse()
	if _warehouse == null:
		# 无仓库，无法搬运，结束（AIController 会转 work）
		finish()
		return
	_warehouse_pos = _compute_warehouse_pos()
	_site_pos = _compute_site_pos()
	_phase = Phase.TO_WAREHOUSE
	if _wall_avoid == null:
		_wall_avoid = ScriptWallAvoid.new(entity)
	_wall_avoid.arm()
	# 进入搬运状态（播放 carry 动画）
	if entity != null and entity.has_method("set_carrying"):
		entity.set_carrying(true)


func update(delta: float) -> void:
	# 已完成但状态机尚未切换时，不再执行任何动作（防止 finish 后仍重复交付）
	if is_finished():
		if entity != null and entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	if _project == null:
		finish()
		return
	# 项目完工或取消：结束
	if _project.is_operational() or not _project.is_accepting_workers():
		finish()
		return
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	match _phase:
		Phase.TO_WAREHOUSE:
			_warehouse_pos = _compute_warehouse_pos()
			_move_to(delta, _warehouse_pos)
		Phase.PICKING:
			# 取货停留
			if entity != null and entity.has_method("ai_stop"):
				entity.ai_stop()
			_action_timer += delta
			if entity != null and entity.has_method("set_action_progress"):
				entity.set_action_progress(_action_timer / PICK_DURATION)
			if _action_timer >= PICK_DURATION:
				_action_timer = 0.0
				if entity != null and entity.has_method("hide_action_progress"):
					entity.hide_action_progress()
				if entity != null and entity.has_method("set_carrying"):
					entity.set_carrying(true)
				_phase = Phase.TO_SITE
		Phase.TO_SITE:
			_site_pos = _compute_site_pos()
			_move_to(delta, _site_pos)
		Phase.DELIVERING:
			# 交付停留
			if entity != null and entity.has_method("ai_stop"):
				entity.ai_stop()
			_action_timer += delta
			if entity != null and entity.has_method("set_action_progress"):
				entity.set_action_progress(_action_timer / DELIVER_DURATION)
			if _action_timer >= DELIVER_DURATION:
				_action_timer = 0.0
				if entity != null and entity.has_method("hide_action_progress"):
					entity.hide_action_progress()
				if entity != null and entity.has_method("set_carrying"):
					entity.set_carrying(false)
				_project.deliver_material()
				if _project.needs_material():
					_phase = Phase.TO_WAREHOUSE
				else:
					finish()


func exit(next: String) -> void:
	super.exit(next)
	# 退出搬运状态（多工人模式无认领，无需释放）
	if entity != null:
		if entity.has_method("set_carrying"):
			entity.set_carrying(false)
		if entity.has_method("hide_action_progress"):
			entity.hide_action_progress()


# ─────────────────────────────── 内部 ────────────────────────────────

## 走向目标点，到达后触发对应阶段完成逻辑。直线方向叠加静态障碍避障
##（方案A）：切向滑动/绕行意向修正；持续受阻（推墙/被占位绕圈）超限 → 判
## 不可达 finish 放弃本行为（决策层重派/换向），不再无限推墙卡死。
func _move_to(delta: float, target: Vector2) -> void:
	var dist: float = entity.global_position.distance_to(target)
	if dist > ARRIVE_THRESHOLD:
		var dir: Vector2 = (target - entity.global_position).normalized()
		_wall_avoid.update(delta, dir, target)
		if _wall_avoid.is_unreachable():
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			print("[BehaviorHaul] 搬运目标不可达（受阻 %.1fs 放弃，决策层重派）: pos=%v target=%v"
					% [float(_wall_avoid.push_time()), entity.global_position, target])
			finish()
			return
		dir = _wall_avoid.steer(delta, dir)
		if entity.has_method("ai_move"):
			entity.ai_move(dir)
	else:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_on_arrive()


func _on_arrive() -> void:
	match _phase:
		Phase.TO_WAREHOUSE:
			# 到达仓库，开始取货停留
			_phase = Phase.PICKING
			_action_timer = 0.0
		Phase.TO_SITE:
			# 到达工地，开始交付停留
			_phase = Phase.DELIVERING
			_action_timer = 0.0


## 查找最近仓库（通过 ConstructionManager）。
func _find_warehouse() -> Node2D:
	if entity == null or not entity.has_method("get_construction_manager"):
		return null
	var manager: Node = entity.get_construction_manager()
	if manager == null or not manager.has_method("get_nearest_warehouse"):
		return null
	return manager.get_nearest_warehouse(entity.global_position)


## 仓库取货点：站在仓库横向中间 (width-2) 格区域内（与玩家交互判定一致）。
func _compute_warehouse_pos() -> Vector2:
	if _warehouse == null or entity == null:
		return entity.global_position if entity != null else Vector2.ZERO
	var w: int = int(_warehouse.get("width")) if "width" in _warehouse else 16
	var left_x: float = _warehouse.global_position.x
	var right_x: float = left_x + float(w) * CELL_SIZE
	var zone_left: float = left_x + CELL_SIZE
	var zone_right: float = right_x - CELL_SIZE
	if zone_right <= zone_left:
		zone_left = left_x
		zone_right = right_x
	var ground_y: float = PlacementMetrics.ground_y_of(entity)
	# 取货点 = 中间区中心（或偏自己一侧）
	var center_x: float = (left_x + right_x) * 0.5
	var target_x: float = zone_left + (zone_right - zone_left) * 0.5
	if entity.global_position.x < center_x:
		target_x = zone_left + 12.0
	else:
		target_x = zone_right - 12.0
	return Vector2(target_x, ground_y + WORK_OFFSET_Y)


## 工地交付点：站在工地横向中间 (width-2) 格区域内（与玩家交互判定一致）。
func _compute_site_pos() -> Vector2:
	if _project == null or entity == null:
		return entity.global_position if entity != null else Vector2.ZERO
	var cell_x: int = _project.cell_x
	var width: int = _project.width
	var left_x: float = float(cell_x) * CELL_SIZE
	var right_x: float = left_x + float(width) * CELL_SIZE
	var zone_left: float = left_x + CELL_SIZE
	var zone_right: float = right_x - CELL_SIZE
	if zone_right <= zone_left:
		zone_left = left_x
		zone_right = right_x
	var ground_y: float = PlacementMetrics.ground_y_of(entity)
	var center_x: float = (left_x + right_x) * 0.5
	var target_x: float = zone_left + (zone_right - zone_left) * 0.5
	if entity.global_position.x < center_x:
		target_x = zone_left + 12.0
	else:
		target_x = zone_right - 12.0
	return Vector2(target_x, ground_y + WORK_OFFSET_Y)
