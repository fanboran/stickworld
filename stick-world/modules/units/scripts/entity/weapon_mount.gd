class_name WeaponMount
extends Node2D
## 武器挂载点 -- 管理武器数据与攻击执行。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1（WeaponMount）。
## P0 阶段：纯逻辑占位武器（步枪式），数值为占位值（数值层待原型后填，见 §16）。
##
## 攻击流程（由 behavior_attack 调用）：
##   1. can_attack() 检查冷却
##   2. perform_attack(target) 按距离 + 命中率判定，命中则 target.health.take_damage()
##   3. 进入冷却，update_cooldown(delta) 每帧递减
##
## 情绪标签对命中的影响（由 battle_ai_director 设置，§7.4）：
##   HESITANT: 命中率 ×0.7
##   EXCITED:  命中率 ×1.1，冷却 ×0.85
##   PANICKED: 命中率 ×0.5
##   STEADY:   不变

# ─────────────────────────────── 情绪标签 ────────────────────────────────
## 战场导演打的情绪标签（§7.4），影响命中与冷却
enum Mood {
	STEADY,     ## 稳定（默认）
	HESITANT,   ## 犹豫（命中率-30%）
	EXCITED,    ## 亢奋（追击+，冷却缩短）
	PANICKED,   ## 恐慌（命中率-50%）
}

# ─────────────────────────────── @export（P0 占位数值）────────────────────────────────
## 单次命中伤害
@export var damage: float = 12.0
## 攻击射程（像素），超出此范围无法攻击
@export var attack_range: float = 140.0
## 攻击冷却（秒）
@export var cooldown: float = 1.3
## 基础命中率 [0,1]
@export var base_hit_chance: float = 0.65

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前冷却剩余（秒）
var _cooldown_timer: float = 0.0
## 当前情绪标签
var _mood: Mood = Mood.STEADY


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _physics_process(delta: float) -> void:
	update_cooldown(delta)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 是否可以攻击（冷却结束）
func can_attack() -> bool:
	return _cooldown_timer <= 0.0


## 当前冷却剩余时间
func get_cooldown_remaining() -> float:
	return _cooldown_timer


## 执行一次攻击。
## target: 目标 StickmanEntity（必须有 HealthComponent）
## 返回 {hit: bool, damage: float, reason: String}
func perform_attack(target: Node) -> Dictionary:
	var result: Dictionary = {"hit": false, "damage": 0.0, "reason": ""}
	if not can_attack():
		result["reason"] = "cooldown"
		return result
	if target == null or not is_instance_valid(target):
		result["reason"] = "invalid_target"
		return result
	var health: Node = _get_health(target)
	if health == null or health.is_dead():
		result["reason"] = "no_health_or_dead"
		return result
	# 距离检查
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		result["reason"] = "no_owner"
		return result
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range:
		result["reason"] = "out_of_range"
		return result
	# 命中判定
	var hit_chance: float = _get_effective_hit_chance()
	if randf() <= hit_chance:
		var dmg: float = damage
		health.take_damage(dmg, owner_entity)
		result["hit"] = true
		result["damage"] = dmg
	else:
		result["reason"] = "miss"
	# 无论命中与否都进入冷却
	_cooldown_timer = _get_effective_cooldown()
	return result


## 每帧递减冷却（也可由外部调用）
func update_cooldown(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(0.0, _cooldown_timer - delta)


## 设置情绪标签（由 battle_ai_director 调用，§7.4）
func set_mood(mood: Mood) -> void:
	_mood = mood


## 获取当前情绪标签
func get_mood() -> Mood:
	return _mood


## 获取拥有此 WeaponMount 的 StickmanEntity（父节点）。
func get_owner_entity() -> CharacterBody2D:
	var p: Node = get_parent()
	if p is CharacterBody2D:
		return p as CharacterBody2D
	return null


# ─────────────────────────────── 内部 ────────────────────────────────

## 获取目标实体的 HealthComponent
func _get_health(target: Node) -> Node:
	if target == null:
		return null
	return target.get_node_or_null("HealthComponent")


## 根据情绪标签计算实际命中率
func _get_effective_hit_chance() -> float:
	match _mood:
		Mood.HESITANT:
			return base_hit_chance * 0.7
		Mood.EXCITED:
			return minf(1.0, base_hit_chance * 1.1)
		Mood.PANICKED:
			return base_hit_chance * 0.5
		_:
			return base_hit_chance


## 根据情绪标签计算实际冷却
func _get_effective_cooldown() -> float:
	match _mood:
		Mood.EXCITED:
			return cooldown * 0.85
		_:
			return cooldown
