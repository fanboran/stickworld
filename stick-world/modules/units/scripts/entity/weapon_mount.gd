class_name WeaponMount
extends Node2D
## 武器挂载点 -- 管理近战剑数据、挥砍动画与攻击执行。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1（WeaponMount）。
## P0 阶段：近战剑（占位剑场景挂到右手骨骼），程序化挥砍（无 K 帧，Tween 驱动
## 前摇-100° → 挥出+30° → 收招回正），命中时目标受击反馈（击退+红闪+顿帧）。
##
## 攻击流程（由 behavior_attack / 玩家附身调用）：
##   1. can_attack() 检查冷却
##   2. perform_attack(target) 按距离 + 命中率判定，命中则 target.apply_hit_reaction()
##   3. 命中/挥砍触发 HitStop（短时冻结，headless 下自动禁用）
##   4. 进入冷却，update_cooldown(delta) 每帧递减
##
## 数值为 P0 占位（对齐 stickmen.tres 平原步兵 base_attack=15），后续接入数据驱动。

# ─────────────────────────────── 常量 ────────────────────────────────
## 占位剑场景（GripPoint 对齐握把，临时配剑方案）
const SWORD_SCENE_PATH := "res://modules/units/scenes/components/weapon_sword_placeholder.tscn"
## 挥砍动画参数（度）
const SWING_WINDUP_DEG: float = 100.0  ## 前摇回拉角度
const SWING_SLASH_DEG: float = 30.0    ## 挥出前摆角度
## 挥砍阶段时长（秒）：前摇 → 挥出 → 收招
const SWING_WINDUP_T: float = 0.10
const SWING_SLASH_T: float = 0.07
const SWING_RECOVER_T: float = 0.12
## HitStop 参数（命中顿帧）
const HITSTOP_TIME_SCALE: float = 0.05
const HITSTOP_DURATION: float = 0.06
## 受击击退力度（与伤害正相关）
const KNOCKBACK_PER_DAMAGE: float = 16.0

# ─────────────────────────────── 情绪标签（§7.4，battle_ai_director 设置）────────────────────────────────
## 战场导演打的情绪标签，影响命中与冷却
enum Mood {
	STEADY,     ## 稳定（默认）
	HESITANT,   ## 犹豫（命中率-30%）
	EXCITED,    ## 亢奋（命中率+10%，冷却-15%）
	PANICKED,   ## 恐慌（命中率-50%）
}

# ─────────────────────────────── @export（P0 占位数值）────────────────────────────────
## 单次命中伤害
@export var damage: float = 15.0
## 攻击射程（像素），近战剑 = 剑长 + 手臂（火柴人碰撞半宽约 20 + 剑 96）
@export var attack_range: float = 80.0
## 攻击冷却（秒）
@export var cooldown: float = 0.9
## 基础命中率 [0,1]（近战高命中）
@export var base_hit_chance: float = 0.9

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前冷却剩余（秒）
var _cooldown_timer: float = 0.0
## 挂在右手骨骼上的武器实例（Node2D，挥砍时旋转它）
var _weapon: Node2D = null
## 挥砍 Tween 引用（中断旧挥砍）
var _swing_tween: Tween = null
## 当前情绪标签
var _mood: Mood = Mood.STEADY


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 延迟挂剑：WeaponMount 是实体子节点，_ready 先于实体执行，
	# 此时 entity.rig 尚未赋值（实体 _ready 里获取），deferred 保证顺序。
	call_deferred("_mount_sword")


## 挂载占位剑到右手（模型无 hand 骨骼，挂在 IK 手部 marker innerhand 上）。
## 临时配剑方案：所有火柴人一视同仁，后续背包系统接入后按装备配置。
func _mount_sword() -> void:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		push_warning("[WeaponMount] 无持有实体，无法挂剑")
		return
	var hand: Node2D = _find_hand_marker(owner_entity)
	if hand == null:
		push_warning("[WeaponMount] 未找到手部挂载点（innerhand marker），无法挂剑")
		return
	var scene: PackedScene = load(SWORD_SCENE_PATH)
	if scene == null:
		push_warning("[WeaponMount] 占位剑场景加载失败: %s" % SWORD_SCENE_PATH)
		return
	var instance: Node2D = scene.instantiate()
	# GripPoint 对齐：剑的原点移到握把
	var grip := instance.get_node_or_null("GripPoint") as Marker2D
	if grip:
		instance.position = -grip.position
		instance.rotation = -grip.rotation
	hand.add_child(instance)
	instance.z_index = 1
	instance.z_as_relative = false
	_weapon = instance


## 查找 IK 手部挂载点（实体 markers 父节点下的 innerhand）。
func _find_hand_marker(owner_entity: Node2D) -> Node2D:
	var markers: Node2D = owner_entity.get("_markers_parent") if "_markers_parent" in owner_entity else null
	if markers == null:
		return null
	return markers.get_node_or_null("innerhand")


func _physics_process(delta: float) -> void:
	update_cooldown(delta)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 是否可以攻击（冷却结束）
func can_attack() -> bool:
	return _cooldown_timer <= 0.0


## 当前冷却剩余时间
func get_cooldown_remaining() -> float:
	return _cooldown_timer


## 执行一次攻击（近战挥砍）。
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
	# 距离检查（近战：剑够得着才算）
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		result["reason"] = "no_owner"
		return result
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range:
		result["reason"] = "out_of_range"
		return result
	# 挥砍动画（无论命中与否都有挥砍动作）
	_play_swing()
	# 命中判定（含情绪修正，§7.4）
	if randf() <= _get_effective_hit_chance():
		var dmg: float = damage
		health.take_damage(dmg, owner_entity)
		# 受击反馈：物理击退（指向远离攻击者方向）
		if target.has_method("apply_hit_reaction"):
			var hit_dir: Vector2 = (target.global_position - owner_entity.global_position).normalized()
			target.apply_hit_reaction(hit_dir, dmg * KNOCKBACK_PER_DAMAGE)
		# HitStop 顿帧（命中打击感；headless 下禁用保证测试稳定）
		_hitstop()
		result["hit"] = true
		result["damage"] = dmg
	else:
		result["reason"] = "miss"
	# 无论命中与否都进入冷却（含情绪修正）
	_cooldown_timer = _get_effective_cooldown()
	return result


## 每帧递减冷却（也可由外部调用）
func update_cooldown(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(0.0, _cooldown_timer - delta)


## 获取挂在手部的武器实例（null=未挂载）
func get_weapon_node() -> Node2D:
	return _weapon


## 是否正在挥砍（供测试/调试）
func is_swinging() -> bool:
	return _swing_tween != null and _swing_tween.is_valid() and _swing_tween.is_running()


# ─────────────────────────────── 内部 ────────────────────────────────

## 程序化挥砍：武器绕握把旋转（前摇 → 挥出 → 收招），无需 K 帧。
func _play_swing() -> void:
	if _weapon == null or not is_instance_valid(_weapon):
		return
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	var base_rot: float = _weapon.rotation
	var windup: float = base_rot - deg_to_rad(SWING_WINDUP_DEG)
	var slash: float = base_rot + deg_to_rad(SWING_SLASH_DEG)
	_swing_tween = create_tween()
	_swing_tween.tween_property(_weapon, "rotation", windup, SWING_WINDUP_T).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(_weapon, "rotation", slash, SWING_SLASH_T).set_ease(Tween.EASE_IN)
	_swing_tween.tween_property(_weapon, "rotation", base_rot, SWING_RECOVER_T).set_ease(Tween.EASE_OUT)


## 命中顿帧：短暂冻结时间（打击感核心，参考 Stickman Burst Hit Stop 方案）。
## headless 下禁用（避免拖慢测试计时）。
func _hitstop() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Engine.time_scale = HITSTOP_TIME_SCALE
	var tree := get_tree()
	if tree != null:
		# ignore_time_scale=true：恢复定时器不受冻结影响
		tree.create_timer(HITSTOP_DURATION, true, false, true).timeout.connect(func():
			Engine.time_scale = 1.0
		)


## 获取目标实体的 HealthComponent
func _get_health(target: Node) -> Node:
	if target == null:
		return null
	return target.get_node_or_null("HealthComponent")


## 设置情绪标签（由 battle_ai_director 调用，§7.4）
func set_mood(mood: Mood) -> void:
	_mood = mood


## 获取当前情绪标签
func get_mood() -> Mood:
	return _mood


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


## 获取拥有此 WeaponMount 的 StickmanEntity（父节点）。
func get_owner_entity() -> CharacterBody2D:
	var p: Node = get_parent()
	if p is CharacterBody2D:
		return p as CharacterBody2D
	return null
