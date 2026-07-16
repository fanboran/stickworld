class_name BehaviorAttack
extends "res://modules/units/ai/behavior_base.gd"
## 攻击行为 -- 找最近敌人 -> 接近到射程内 -> 攻击（命中帧->伤害事件）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2 / §7.4 / §8。
## 包含概率钩子（§7.4 第一层）：擅自冲锋、犹豫。
##
## 完成条件（finish 后由 AIController 决策切换）：
##   - 无敌人 / 战斗结束
##   - 自身溃逃（士气低于阈值）-> AIController 切 retreat
##   - 自身重伤且附近有掩体 -> AIController 切 seek_cover
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# ─────────────────────────────── 常量 ────────────────────────────────
## 目标刷新间隔（秒）
const ACQUIRE_INTERVAL: float = 0.5
## 犹豫检查间隔（秒）
const HESITATE_CHECK_INTERVAL: float = 0.5
## 低士气阈值（低于此值触发撤退决策）
const LOW_MORALE_THRESHOLD: float = 0.3
## 低 HP 阈值（低于此值且附近有掩体触发找掩体）
const LOW_HP_THRESHOLD: float = 0.3
## 掩体查询范围（附近多少像素内有掩体算"附近"）
const COVER_NEARBY_RANGE: float = 200.0

# ─────────────────────────────── @export（概率钩子，§7.4）────────────────────────────────
## 擅自冲锋概率（每次接近时）
@export var prob_aggressive_push: float = 0.05
## 犹豫概率（每次检查时）
@export var prob_hesitate: float = 0.03

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 当前目标敌人
var _target: Node = null
## 目标刷新计时器
var _acquire_timer: float = 0.0
## 犹豫检查计时器
var _hesitate_check_timer: float = 0.0
## 犹豫持续计时器（>0 时停滞）
var _hesitate_timer: float = 0.0


func _ready() -> void:
	behavior_name = "attack"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_target = null
	_acquire_timer = 0.0
	_hesitate_check_timer = 0.0
	_hesitate_timer = 0.0


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

	# 刷新目标
	_acquire_timer -= delta
	if _target == null or not is_instance_valid(_target) or (_target.has_method("is_dead") and _target.is_dead()) or _acquire_timer <= 0.0:
		_target = _battle.get_nearest_enemy(entity)
		_acquire_timer = ACQUIRE_INTERVAL
		if _target == null:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return

	# 自身状态检查：士气/HP 过低 -> finish 让 AIController 决策
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			finish()
			return
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() < LOW_MORALE_THRESHOLD:
			finish()
			return
		if health.has_method("get_hp_ratio") and health.get_hp_ratio() < LOW_HP_THRESHOLD and _has_cover_nearby():
			finish()
			return

	# 犹豫概率钩子（§7.4 第一层）
	if _hesitate_timer > 0.0:
		_hesitate_timer -= delta
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	_hesitate_check_timer -= delta
	if _hesitate_check_timer <= 0.0:
		_hesitate_check_timer = HESITATE_CHECK_INTERVAL
		if randf() < prob_hesitate:
			_hesitate_timer = randf_range(0.3, 0.8)
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			return

	# 攻击 / 接近逻辑
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	var dist: float = entity.global_position.distance_to(_target.global_position)

	if dist <= attack_range:
		# 在射程内：停止移动并攻击
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		if weapon != null and weapon.has_method("can_attack") and weapon.can_attack():
			weapon.perform_attack(_target)
	else:
		# 不在射程：移动接近，概率擅自冲锋（奔跑）
		var dir: Vector2 = (_target.global_position - entity.global_position).normalized()
		var run: bool = randf() < prob_aggressive_push
		if entity.has_method("ai_move"):
			entity.ai_move(dir, run)


# ─────────────────────────────── 内部 ────────────────────────────────

## 检查附近是否有掩体（用于"重伤找掩体"决策）
func _has_cover_nearby() -> bool:
	if _battle == null or not _battle.has_method("get_cover"):
		return false
	var cover = _battle.get_cover()
	if cover == null or not cover.has_method("has_covers") or not cover.has_covers():
		return false
	if cover.has_method("is_in_cover") and cover.is_in_cover(entity.global_position):
		return true
	if cover.has_method("find_nearest_cover"):
		var nearest: Vector2 = cover.find_nearest_cover(entity.global_position)
		return entity.global_position.distance_to(nearest) < COVER_NEARBY_RANGE
	return false


## 获取当前目标（供测试/调试）
func get_target() -> Node:
	return _target
