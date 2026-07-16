class_name BehaviorRetreat
extends "res://modules/units/ai/behavior_base.gd"
## 撤退行为 -- 向远离最近敌人的方向移动，拉开距离或恢复士气后 finish。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## 撤退中士气缓慢恢复；士气恢复到安全水平或拉开足够距离后 finish（回 attack）。
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# ─────────────────────────────── 常量 ────────────────────────────────
## 撤退最长持续时间（秒）
const RETREAT_DURATION: float = 4.0
## 安全距离（拉开此距离后可停止撤退）
const SAFE_DISTANCE: float = 320.0
## 撤退中士气恢复速度（每秒）
const MORALE_RECOVER_PER_SEC: float = 8.0
## 士气恢复到此比例后停止撤退
const SAFE_MORALE_RATIO: float = 0.6

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 撤退计时器
var _timer: float = 0.0
## 撤退方向（归一化）
var _retreat_dir: Vector2 = Vector2.LEFT


func _ready() -> void:
	behavior_name = "retreat"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_timer = RETREAT_DURATION
	_compute_retreat_dir()


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("is_active") or not _battle.is_active():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return

	_timer -= delta

	# 撤退中士气恢复
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null and health.has_method("restore_morale"):
		health.restore_morale(MORALE_RECOVER_PER_SEC * delta)
		# 士气恢复到安全水平 -> 停止撤退
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() >= SAFE_MORALE_RATIO:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return

	# 检查安全距离
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	if enemy != null and is_instance_valid(enemy):
		var dist: float = entity.global_position.distance_to(enemy.global_position)
		if dist > SAFE_DISTANCE:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return
		# 重新计算撤退方向（远离敌人）
		var away: Vector2 = entity.global_position - enemy.global_position
		if away.length() > 0.1:
			_retreat_dir = away.normalized()

	# 撤退移动（奔跑）
	if entity.has_method("ai_move"):
		entity.ai_move(_retreat_dir, true)

	if _timer <= 0.0:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算初始撤退方向（远离最近敌人）
func _compute_retreat_dir() -> void:
	if _battle == null or entity == null:
		_retreat_dir = Vector2.LEFT
		return
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	if enemy == null:
		_retreat_dir = Vector2.LEFT
		return
	var away: Vector2 = entity.global_position - enemy.global_position
	_retreat_dir = away.normalized() if away.length() > 0.1 else Vector2.LEFT


## 获取撤退方向（供测试/调试）
func get_retreat_dir() -> Vector2:
	return _retreat_dir
