class_name BehaviorMove
extends BehaviorBase
## 移动行为 -- 向目标点直线移动，到达后完成。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## P0 阶段为简单直线移动，不做 A* 寻路（障碍由 entity 的通行障碍检测处理）。
## params 必填字段：
##   - target: Vector2  目标位置（世界坐标）
## 可选字段：
##   - run: bool  是否奔跑（默认 false）

## 到达目标的距离阈值（像素）
const ARRIVAL_THRESHOLD: float = 20.0
## 列阵到位滞留时长（秒；编队成员到达时播 arrive 动画后停留，AI 完善批次 4）
const ARRIVE_HOLD_DURATION: float = 0.4

## 目标位置（世界坐标）
var _target: Vector2 = Vector2.ZERO
## 是否奔跑
var _running: bool = false
## 列阵到位滞留倒计时（>0 表示已到达正在播 arrive）
var _arrive_hold: float = 0.0


func _ready() -> void:
	behavior_name = "move"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	if params.has("target"):
		_target = params["target"]
	else:
		_target = entity.global_position if entity != null else Vector2.ZERO
	_running = params.get("run", false)


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return

	# 到达后的列阵到位滞留（AI 完善批次 4）：播 arrive 立正动画，播完再 finish
	if _arrive_hold > 0.0:
		_arrive_hold -= delta
		if _arrive_hold <= 0.0:
			finish()
			if entity.has_method("ai_stop"):
				entity.ai_stop()
		return

	var pos: Vector2 = entity.global_position
	var dist: float = pos.distance_to(_target)

	# 到达目标
	if dist <= ARRIVAL_THRESHOLD:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		# 编队成员到达队形位 → 播列阵动画并短暂滞留（对应传奇 ArriveAtFormationAnimationSystem）
		if _is_squad_member():
			if entity.has_method("play_arrive"):
				entity.play_arrive()
			_arrive_hold = ARRIVE_HOLD_DURATION
		else:
			finish()
		return

	# 计算移动方向并驱动 entity
	var dir: Vector2 = (_target - pos).normalized()
	if entity.has_method("ai_move"):
		entity.ai_move(dir, _running)


## 是否编队成员（AI 完善批次 4）：有 formation 且属于某小队 → 到达时播列阵动画。
func _is_squad_member() -> bool:
	if entity == null or not entity.has_method("get_formation_system"):
		return false
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_squad"):
		return false
	return not fs.get_unit_squad(entity).is_empty()
