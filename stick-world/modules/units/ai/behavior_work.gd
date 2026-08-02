class_name BehaviorWork
extends "res://modules/units/ai/behavior_base.gd"
## 工作行为 —— §15 阶段 0.4。
##
## 工人被派工到 ConstructionProject 后进入此行为：
##   1. enter：从 params 读取 project 引用，计算工作目标点（项目选址附近）
##   2. update：每帧走向目标点；到达后保持位置（项目进度由 manager tick 推进）
##   3. 项目完工或被取消时 finish()，AIController 决策下一步（回 idle）
##
## params 必需字段：
##   - project: ConstructionProject  工人被派工的项目（由 AIController 在 travel 时注入）
##
## 设计原则：
##   - BehaviorWork 不直接推进 project 进度（ConstructionManager._physics_process 已 tick 所有项目）
##   - BehaviorWork 只负责"工人到位"和"项目状态查询"

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

# ─────────────────────────────── 常量 ────────────────────────────────

## 网格单元大小（与 PlacementGrid.CELL_SIZE 一致）
const CELL_SIZE: float = 32.0
## 到达阈值（距目标小于此值视为已到达，避免抖动）
const ARRIVE_THRESHOLD: float = 24.0
## 单格高度（工作位相对地面线下方一点，避免遮住建筑）
const WORK_OFFSET_Y: float = 40.0
## 站在工地临时障碍外的水平距离（避免工人走进通行障碍）。
## 实体脚部碰撞箱半宽约 41.5px，取 44 让工人贴近建筑边缘而不触发回退
const STANDOFF_X: float = 44.0
## build 动画一次循环时长（秒，与 build.tres length 一致）
const BUILD_ANIM_DURATION: float = 1.8
## 完工所需敲击次数（每次 build 动画循环推进 total_work / BUILD_HITS）
const BUILD_HITS: int = 8

# ─────────────────────────────── 运行时 ────────────────────────────────

## 当前项目引用（ConstructionProject）
var _project: ScriptConstructionProject = null
## 工作目标点（世界坐标）
var _target_pos: Vector2 = Vector2.ZERO
## 是否已到达
var _arrived: bool = false
## build 动画计时器（累积到 BUILD_ANIM_DURATION 推进一次进度）
var _build_timer: float = 0.0


func _ready() -> void:
	behavior_name = "work"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_arrived = false
	_project = params.get("project", null) as ScriptConstructionProject
	if _project == null:
		# 没有项目引用，立即结束
		finish()
		return
	_compute_target_position()


func update(delta: float) -> void:
	if _project == null:
		finish()
		return
	# 项目完工或被取消：finish 回 idle
	if _project.is_operational() or not _project.is_accepting_workers():
		finish()
		if entity != null and entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	# 实体失效：finish
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	# 走向目标
	if not _arrived:
		var dist: float = entity.global_position.distance_to(_target_pos)
		if dist > ARRIVE_THRESHOLD:
			var dir: Vector2 = (_target_pos - entity.global_position).normalized()
			if entity.has_method("ai_move"):
				entity.ai_move(dir)
		else:
			_arrived = true
			if entity.has_method("ai_stop"):
				entity.ai_stop()
	# 已到达：检查材料是否耗尽
	if _project.needs_material():
		# 材料耗尽：解除动作动画，finish 转 haul（多工人都会去搬）
		if entity.has_method("clear_action"):
			entity.clear_action()
		finish()
		return
	# 有材料：播放 build 动画，每次循环完成推进建造进度
	if entity.has_method("set_action_anim"):
		entity.set_action_anim("build")
	if entity.has_method("ai_stop"):
		entity.ai_stop()
	_build_timer += delta
	if entity.has_method("set_action_progress"):
		entity.set_action_progress(_build_timer / BUILD_ANIM_DURATION)
	if _build_timer >= BUILD_ANIM_DURATION:
		_build_timer = 0.0
		if entity.has_method("hide_action_progress"):
			entity.hide_action_progress()
		var per_hit: float = _project.total_work / float(BUILD_HITS)
		_project.add_build_progress(per_hit)


## 退出时解除动作动画锁定。
func exit(_next: String) -> void:
	super.exit(_next)
	if entity != null:
		if entity.has_method("clear_action"):
			entity.clear_action()
		if entity.has_method("hide_action_progress"):
			entity.hide_action_progress()


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算工作目标点。
## 多名工人派到同一项目时，按 slot_index 在 X 方向分散站位，避免挤一起。
func _compute_target_position() -> void:
	if _project == null or entity == null:
		return
	var cell_x: int = _project.cell_x
	var width: int = _project.width
	var left_x: float = float(cell_x) * CELL_SIZE
	var right_x: float = left_x + float(width) * CELL_SIZE
	var center_x: float = (left_x + right_x) * 0.5
	var slot_index: int = _project.get_worker_slot_index(entity)
	if slot_index < 0:
		slot_index = 0
	# 每名工人站在离自己最近一侧的障碍外，避免挤进临时障碍
	var offset_along: float = float(slot_index) * 24.0
	var target_x: float
	if entity.global_position.x < center_x:
		target_x = left_x - STANDOFF_X - offset_along
	else:
		target_x = right_x + STANDOFF_X + offset_along
	# Y：建筑下方一点（建筑原点在 ground_y，工作位在 ground_y 下方）
	var ground_y: float = entity.get("ground_y") if "ground_y" in entity else 810.0
	_target_pos = Vector2(target_x, ground_y + WORK_OFFSET_Y)


## 获取工作目标点（供测试/调试用）
func get_target_position() -> Vector2:
	return _target_pos


## 是否已到达工作位
func has_arrived() -> bool:
	return _arrived
