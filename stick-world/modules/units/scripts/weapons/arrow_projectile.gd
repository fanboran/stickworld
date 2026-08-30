class_name ArrowProjectile
extends Area2D
## 箭矢投影物 -- 弓（WeaponType.BOW）远程攻击发射。
##
## 复刻 SWL Arrow 类特性：
## - 直线飞行，命中实体（BODY 层）或达最大射程
## - 爆头判定 causesHeadShotAnimation：命中点在目标上部 1/4 → 爆头（管线加值+爆头死亡动画）
## - 插身 doesStickIn：命中后箭钉在受击者身上，随其移动，停留一段时间后淡出
##   （原版"插身上"与 InGroundArrows"插地"是两条路径；我们射程尽头就地淡出，等价简化）
## - 对雕像减伤 0.3 / 对巨人减伤 0.66（DamagePipeline 内处理）
## - 伤害走 DamagePipeline 单入口（复刻 Unit.Damage 语义）
## - 拉弓力度 drawPower 决定伤害（WeaponMount 传入）

# ─────────────────────────────── 常量 ────────────────────────────────
## 飞行速度（px/s）
const SPEED: float = 640.0
## 最大射程（px），超过即插地
const MAX_RANGE: float = 340.0
## 命中判定半径（px）：箭到目标碰撞体中心的距离小于此值即命中
const HIT_RADIUS: float = 34.0
## 击退力度系数（与近战一致：伤害 × KNOCKBACK_PER_DAMAGE）
const KNOCKBACK_PER_DAMAGE: float = 16.0
## 爆头判定：命中点相对目标碰撞体中心向上超过此比例 × 身高 → 爆头
const HEADSHOT_Y_RATIO := 0.22
## 箭插地留存时间（s），之后淡出（复刻 fadeOutOver）
const STUCK_LIFETIME: float = 4.0
## 爆头判定身高（目标碰撞体典型高度，px）
const BODY_HEIGHT := 130.0

# ─────────────────────────────── 运行时 ────────────────────────────────
var _dir: Vector2 = Vector2.RIGHT
var _damage: float = 10.0
var _shooter: Node = null
var _target: Node = null
var _traveled: float = 0.0
## 拉弓力度 0~1（SWL drawPower：满弓伤害更高）
var _draw_power: float = 1.0
## 已插地/插身（停止飞行，等待淡出）
var _stuck: bool = false
## 插地淡出计时
var _stuck_timer: float = 0.0
## 命中后是否插在受击者身上（原版 Arrow.doesStickIn 字段：插身上的箭 ≠
## InGroundArrows 插地的箭，两条路径）。true = 命中后钉在目标身上随其移动。
@export var does_stick_in: bool = true


## 发射参数：方向、伤害、射手、目标、拉弓力度（0~1）
func setup(dir: Vector2, dmg: float, shooter: Node, target: Node = null, draw_power: float = 1.0) -> void:
	_dir = dir.normalized()
	_damage = dmg
	_shooter = shooter
	_target = target
	_draw_power = clampf(draw_power, 0.0, 1.0)
	rotation = _dir.angle()


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if _stuck:
		# 插地淡出（SWL fadeOutOver）
		_stuck_timer += delta
		if _stuck_timer >= STUCK_LIFETIME:
			queue_free()
		elif _stuck_timer >= STUCK_LIFETIME - 1.0:
			modulate.a = (STUCK_LIFETIME - _stuck_timer) / 1.0
		return
	var step := _dir * SPEED * delta
	position += step
	_traveled += step.length()
	# 手动命中检测（近战同款：不依赖物理碰撞）：箭到目标碰撞体距离 < HIT_RADIUS
	if _target != null and is_instance_valid(_target):
		var body_pos: Vector2 = _target_body_pos(_target)
		if global_position.distance_to(body_pos) <= HIT_RADIUS:
			_hit(_target)
			return
	# 射程尽头：插地（复刻 doesStickIn）
	if _traveled >= MAX_RANGE:
		_stick_ground()


## 目标身体（碰撞体）世界位置：Collider 节点优先，缺省回落 root + 典型偏移
static func _target_body_pos(target: Node) -> Vector2:
	var collider: Node = target.get_node_or_null("Collider")
	if collider != null and collider is Node2D:
		return (collider as Node2D).global_position
	return (target as Node2D).global_position + Vector2(8.5, 130)


func _on_body_entered(body: Node2D) -> void:
	if _stuck:
		return
	if body == _shooter:
		return
	# 命中实体本体（CharacterBody2D）
	if body is CharacterBody2D:
		_hit(body)


## 爆头判定：命中点高于目标身体中心 HEADSHOT_Y_RATIO × BODY_HEIGHT
func _is_headshot(target: Node, hit_pos: Vector2) -> bool:
	var body_pos := _target_body_pos(target)
	return hit_pos.y < body_pos.y - BODY_HEIGHT * HEADSHOT_Y_RATIO


func _hit(target: Node) -> void:
	# ── 伤害走 DamagePipeline 单入口（SWL Unit.Damage 复刻）──
	var p := DamagePipeline.Params.new(_damage * (0.6 + 0.4 * _draw_power), _shooter)
	p.direction = _dir
	p.type = DamagePipeline.DAMAGE_TYPE.RANGED
	# 爆头：箭命中点在目标上部（causesHeadShotAnimation 语义）
	p.is_head_shot = _is_headshot(target, global_position)
	# 爆头加值/暴击参数取自射手的武器配置（原版 Unit.headShotBonusDamage 等字段
	# 是**每单位**配置的，不在管线里写死）
	var wm: Node = _shooter.get_node_or_null("WeaponMount") if _shooter != null else null
	if wm != null:
		p.head_shot_bonus_damage = _num(wm, "head_shot_bonus_damage", p.head_shot_bonus_damage)
		p.crit_damage_multiplier = _num(wm, "crit_damage_multiplier", p.crit_damage_multiplier)
		p.crit_self_damage = _num(wm, "crit_bonus_damage_inflicted_to_self", p.crit_self_damage)
		if _num(wm, "crit_chance", 0.0) > 0.0 and randf() < _num(wm, "crit_chance", 0.0):
			p.is_crit = true
	var dealt: float = DamagePipeline.apply(target, p)
	# 登记攻击者（防集火；与近战一致）
	if _shooter != null and _shooter.has_method("get_battle_instance"):
		var battle: Node = _shooter.get_battle_instance()
		if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
			battle.register_attacker(target, _shooter)
	if dealt > 0.0 and target.has_method("apply_hit_reaction"):
		target.apply_hit_reaction(_dir, dealt * KNOCKBACK_PER_DAMAGE)
	# doesStickIn：箭钉在受击者身上随其移动，停留后淡出；否则就地消失
	if does_stick_in and is_instance_valid(target):
		_stick_into(target)
	else:
		queue_free()


## 插在受击者身上：停用碰撞，换父到目标节点（保持世界位姿——箭钉在命中点，
## 跟随单位移动），复用插地淡出计时。目标被释放时箭随场景树一并消失。
## 调用链在物理回调内（_on_body_entered）：碰撞开关与换父必须 call_deferred，
## 否则报 "Removing a CollisionObject node during a physics callback"。
func _stick_into(target: Node) -> void:
	_stuck = true
	_stuck_timer = 0.0
	set_deferred("monitoring", false)
	_stick_into_deferred.call_deferred(target)


func _stick_into_deferred(target: Node) -> void:
	if not is_instance_valid(target):
		queue_free()
		return
	var xf: Transform2D = global_transform
	var parent: Node = get_parent()
	if parent != null:
		parent.remove_child(self)
	target.add_child(self)
	global_transform = xf


## 读取节点上的数值属性（属性不存在或类型不符时返回缺省值）。
static func _num(node: Node, prop: String, fallback: float) -> float:
	if node == null or not prop in node:
		return fallback
	var v: Variant = node.get(prop)
	return float(v) if v != null else fallback


## 插地：箭停在原地并倾斜，等待淡出（复刻 SetSpriteRendererForInGround + fadeOutOver）
func _stick_ground() -> void:
	_stuck = true
	_stuck_timer = 0.0
	# 监测引用失效（目标死后箭还在飞 → 立即插地）
	if _target != null and not is_instance_valid(_target):
		_target = null
	# 视觉：插地角度微微下倾
	rotation = _dir.angle() + 0.15
