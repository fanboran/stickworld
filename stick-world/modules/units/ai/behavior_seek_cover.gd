class_name BehaviorSeekCover
extends "res://modules/units/ai/behavior_base.gd"
## 找掩体行为 -- 查询最佳掩体，移动过去，停留并还击，完成后回 attack。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2 / §8.2（cover_system）。
## 无掩体时立即 finish（AIController 回退到 attack 或 retreat）。
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# ─────────────────────────────── 常量 ────────────────────────────────
## 到达掩体的阈值（像素）
const ARRIVE_THRESHOLD: float = 16.0
## 在掩体中停留时长（秒）
const STAY_DURATION: float = 2.5

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 掩体目标位置（世界坐标）
var _target_pos: Vector2 = Vector2.ZERO
## 是否已到达掩体
var _arrived: bool = false
## 停留计时器
var _stay_timer: float = 0.0


func _ready() -> void:
	behavior_name = "seek_cover"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_arrived = false
	_stay_timer = 0.0
	_compute_target()


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

	if not _arrived:
		# 移动到掩体
		var dist: float = entity.global_position.distance_to(_target_pos)
		if dist > ARRIVE_THRESHOLD:
			var dir: Vector2 = (_target_pos - entity.global_position).normalized()
			if entity.has_method("ai_move"):
				entity.ai_move(dir)
		else:
			_arrived = true
			_stay_timer = STAY_DURATION
			if entity.has_method("ai_stop"):
				entity.ai_stop()
	else:
		# 在掩体中：停留并尝试还击
		_stay_timer -= delta
		_try_attack_from_cover()
		if _stay_timer <= 0.0:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算掩体目标位置
func _compute_target() -> void:
	if _battle == null or entity == null:
		finish()
		return
	var cover = _battle.get_cover() if _battle.has_method("get_cover") else null
	if cover == null or not cover.has_method("has_covers") or not cover.has_covers():
		# 无掩体：立即结束
		finish()
		return
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	var enemy_pos: Vector2 = enemy.global_position if enemy != null else entity.global_position + Vector2.LEFT * 200.0
	_target_pos = cover.find_best_cover(entity.global_position, enemy_pos)


## 在掩体中尝试还击（若敌人在射程内）
func _try_attack_from_cover() -> void:
	if _battle == null:
		return
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	if enemy == null:
		return
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	if weapon == null or not weapon.has_method("can_attack") or not weapon.can_attack():
		return
	var attack_range: float = weapon.attack_range if "attack_range" in weapon else 100.0
	var dist: float = entity.global_position.distance_to(enemy.global_position)
	if dist <= attack_range:
		weapon.perform_attack(enemy)


## 是否已到达掩体（供测试/调试）
func has_arrived() -> bool:
	return _arrived
