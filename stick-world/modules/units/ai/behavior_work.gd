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

# ─────────────────────────────── 运行时 ────────────────────────────────

## 当前项目引用（ConstructionProject）
var _project: ScriptConstructionProject = null
## 工作目标点（世界坐标）
var _target_pos: Vector2 = Vector2.ZERO
## 是否已到达
var _arrived: bool = false


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


func update(_delta: float) -> void:
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
	# 已到达：保持位置，等待项目完工（进度由 manager tick 推进）


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算工作目标点。
## 多名工人派到同一项目时，按 slot_index 在 X 方向分散站位，避免挤一起。
func _compute_target_position() -> void:
	if _project == null or entity == null:
		return
	var cell_x: int = _project.cell_x
	var width: int = _project.width
	# 建筑中心 X = cell_x * 32 + width * 16
	var center_x: float = float(cell_x) * CELL_SIZE + float(width) * CELL_SIZE * 0.5
	# slot_index 决定 X 偏移：0→-24, 1→0, 2→+24, 3→+48 ...
	var slot_index: int = _project.get_worker_slot_index(entity)
	var offset_x: float = (float(slot_index) - 1.0) * 24.0
	# Y：建筑下方一点（建筑原点在 ground_y，工作位在 ground_y 下方）
	var ground_y: float = entity.get("ground_y") if "ground_y" in entity else 810.0
	_target_pos = Vector2(center_x + offset_x, ground_y + WORK_OFFSET_Y)


## 获取工作目标点（供测试/调试用）
func get_target_position() -> Vector2:
	return _target_pos


## 是否已到达工作位
func has_arrived() -> bool:
	return _arrived
