class_name ArrowProjectile
extends Area2D
## 箭矢投影物 -- 弓（WeaponType.BOW）远程攻击发射。
##
## 直线飞行，命中实体本体（collision_layer=2 BODY）或达最大射程后消失。
## 命中时对目标造成伤害 + 受击击退，并登记攻击者（防集火重叠）。

# ─────────────────────────────── 常量 ────────────────────────────────
## 飞行速度（px/s）
const SPEED: float = 640.0
## 最大射程（px），超过即消失（miss）
const MAX_RANGE: float = 340.0
## 命中判定半径（px）：箭到目标碰撞体中心的距离小于此值即命中
const HIT_RADIUS: float = 34.0
## 击退力度系数（与近战一致：伤害 × KNOCKBACK_PER_DAMAGE）
const KNOCKBACK_PER_DAMAGE: float = 16.0

# ─────────────────────────────── 运行时 ────────────────────────────────
var _dir: Vector2 = Vector2.RIGHT
var _damage: float = 10.0
var _shooter: Node = null
var _target: Node = null
var _traveled: float = 0.0


## 发射参数：方向、伤害、射手、目标（手动命中检测用，不命中射手自身）
func setup(dir: Vector2, dmg: float, shooter: Node, target: Node = null) -> void:
	_dir = dir.normalized()
	_damage = dmg
	_shooter = shooter
	_target = target
	rotation = _dir.angle()


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	var step := _dir * SPEED * delta
	position += step
	_traveled += step.length()
	# 手动命中检测（近战同款：不依赖物理碰撞）：箭到目标碰撞体距离 < HIT_RADIUS
	if _target != null and is_instance_valid(_target):
		var body_pos: Vector2 = _target_body_pos(_target)
		if global_position.distance_to(body_pos) <= HIT_RADIUS:
			_hit(_target)
			queue_free()
			return
	if _traveled >= MAX_RANGE:
		queue_free()


## 目标身体（碰撞体）世界位置：Collider 节点优先，缺省回落 root + 典型偏移
static func _target_body_pos(target: Node) -> Vector2:
	var collider: Node = target.get_node_or_null("Collider")
	if collider != null and collider is Node2D:
		return (collider as Node2D).global_position
	return (target as Node2D).global_position + Vector2(8.5, 130)


func _on_body_entered(body: Node2D) -> void:
	if body == _shooter:
		return
	# 命中实体本体（CharacterBody2D）：伤害 + 受击反馈 + 攻击者登记
	if body is CharacterBody2D:
		_hit(body)
	queue_free()


func _hit(target: Node) -> void:
	var dmg: float = _damage
	# 目标持盾格挡：减伤 + 格挡动画（盾兵可挡箭）
	var wm: Node = target.get_node_or_null("WeaponMount")
	if wm != null and wm.has_method("is_shield_blocking") and wm.is_shield_blocking():
		var factor: float = 0.15
		if wm.get("BLOCK_DAMAGE_FACTOR") != null:
			factor = wm.get("BLOCK_DAMAGE_FACTOR")
		dmg *= factor
		if target.has_method("play_block"):
			target.play_block()
	var health: Node = target.get_node_or_null("HealthComponent")
	if health != null and health.has_method("take_damage"):
		health.take_damage(dmg, _shooter)
		# 登记攻击者（防集火；与近战一致，经 battle_instance.register_attacker）
		if _shooter != null and _shooter.has_method("get_battle_instance"):
			var battle: Node = _shooter.get_battle_instance()
			if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
				battle.register_attacker(target, _shooter)
	if target.has_method("apply_hit_reaction"):
		target.apply_hit_reaction(_dir, dmg * KNOCKBACK_PER_DAMAGE)