class_name BehaviorFollow
extends BehaviorBase
## 跟随行为 -- 小队启用"跟随玩家"后，成员自动尾随玩家（保持距离，separation 防叠）。
##
## 详见 docs/技术/架构/场景与战斗/战斗与AI.md §7.2。
## 目标：玩家实体（地图上 possessed 的单位）。玩家 70px 内停步，超出则靠近。
## 战斗中由 AIController 决策优先切走（_try_combat 高于跟随）。
##
## 完成条件（finish 后由 AIController 决策切换）：
##   - 玩家不存在/死亡
##   - 小队关闭跟随（决策层检查，不在此判断）

# ─────────────────────────────── 常量 ────────────────────────────────
## 跟随停步距离（px）：进入该范围即站定
const FOLLOW_STOP_RADIUS: float = 70.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前跟随目标（玩家实体）
var _target: Node = null
## 目标刷新计时器
var _target_timer: float = 0.0
## 目标刷新间隔（秒）
const TARGET_REFRESH_INTERVAL: float = 0.5


func _ready() -> void:
	behavior_name = "follow"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_target = null
	_target_timer = 0.0


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	# 刷新目标（玩家实体）
	_target_timer -= delta
	if _target == null or not is_instance_valid(_target) or _target_timer <= 0.0:
		_target = _find_player()
		_target_timer = TARGET_REFRESH_INTERVAL
	if _target == null or not is_instance_valid(_target):
		# 玩家不存在（如未附身）：原地待命
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	if _target.has_method("is_dead") and _target.is_dead():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return
	# 朝玩家移动，进入停步半径即站定
	var to_target: Vector2 = _target.global_position - entity.global_position
	if to_target.length() > FOLLOW_STOP_RADIUS:
		if entity.has_method("ai_move"):
			entity.ai_move(to_target.normalized(), false)
	else:
		if entity.has_method("ai_stop"):
			entity.ai_stop()


## 查找玩家实体（地图上 possessed 的单位）。
func _find_player() -> Node:
	if entity == null:
		return null
	if not entity.has_method("get_map"):
		return null
	var map: Node2D = entity.get_map()
	if map == null or not is_instance_valid(map):
		return null
	if map.has_method("get_possessed_entity"):
		return map.get_possessed_entity()
	return null
