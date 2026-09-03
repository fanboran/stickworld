class_name ArrowProjectile
extends Area2D
## 箭矢投影物 -- 弓（WeaponType.BOW）远程攻击发射。
##
## 复刻 SWL Arrow 类特性：
## - **抛物线弹道**（SWL Arrow.launchY/AimAngle）：固定重力积分，近距离平射、
##   远距高弧越顶——弓手站后排抛射不被友军前排挡箭
## - 爆头判定 causesHeadShotAnimation：命中点在目标上部 1/4 → 爆头（管线加值+爆头死亡动画）
## - 插身 doesStickIn：命中后箭钉在受击者身上，随其移动，停留一段时间后淡出
## - 对雕像减伤 0.3 / 对巨人减伤 0.66（DamagePipeline 内处理）
## - 伤害走 DamagePipeline 单入口（复刻 Unit.Damage 语义）
## - 拉弓力度 drawPower 决定伤害（WeaponMount 传入）

# ─────────────────────────────── 常量 ────────────────────────────────
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
## 落地判定：下落段相对出射点下降超过此值 → 插地（SWL InGroundArrows）
const GROUND_DROP: float = 500.0
## 兜底寿命（s）：超时强制插地（防极端弹道永生）
const MAX_FLIGHT_TIME: float = 6.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 飞行速度矢量（px/s；vel.y 每帧 += gravity×delta = 抛物线）
var _vel: Vector2 = Vector2.RIGHT * 640.0
## 重力（px/s²；0 = 直线弹道，兼容旧调用）
var _gravity: float = 0.0
var _damage: float = 10.0
var _shooter: Node = null
var _target: Node = null
## 已飞行距离（保留给调试/可能的射程判定）
var _traveled: float = 0.0
## 出射高度（落地判定基准）
var _launch_y: float = 0.0
## 已飞行时间（s；抛物线解算模式下与 _solve_time 比较判落地）
var _flight_time: float = 0.0
## 解算飞行时间（s，>0 = 抛物线解算模式）：飞满后继续沿弹道下落到瞄准点地面线
## （_solve_ground_y）才插地——落点≈目标脚下，散布 miss 自然越过插在敌阵里；
## 0 = 未传（旧调用），退回 GROUND_DROP 深度判定
var _solve_time: float = 0.0
## 瞄准点地面线（y；solve_time 模式下插地判定线）
var _solve_ground_y: float = 0.0
## 拉弓力度 0~1（SWL drawPower：满弓伤害更高）
var _draw_power: float = 1.0
## 已插地/插身（停止飞行，等待淡出）
var _stuck: bool = false
## 插地淡出计时
var _stuck_timer: float = 0.0
## 命中后是否插在受击者身上（原版 Arrow.doesStickIn 字段：插身上的箭 ≠
## InGroundArrows 插地的箭，两条路径）。true = 命中后钉在目标身上随其移动。
@export var does_stick_in: bool = true
## 在飞伤害登记目标（11d MissingArrowsTolerance 估计口径）：发射时锁定，
## 箭矢终态（命中任意敌人/插地）扣减其 incoming_arrow_damage
var _registered_target: Node = null


## 发射参数：初速度矢量、伤害、射手、目标、拉弓力度（0~1）、重力（缺省 0=直线，兼容旧调用）、
## 解算飞行时间（>0 = 抛物线解算模式）、瞄准点地面线（solve_time 模式下插地判定线，
## 0 = 飞满 solve_time 即插）。
## 抛物线模式下 vel 含竖直初速（WeaponMount 按目标距离解算）。
func setup(vel: Vector2, dmg: float, shooter: Node, target: Node = null, draw_power: float = 1.0, gravity: float = 0.0, solve_time: float = 0.0, solve_ground_y: float = 0.0) -> void:
	_vel = vel
	_gravity = gravity
	_damage = dmg
	_shooter = shooter
	_target = target
	_draw_power = clampf(draw_power, 0.0, 1.0)
	_solve_time = maxf(0.0, solve_time)
	_solve_ground_y = solve_ground_y
	rotation = _vel.angle()
	# 11d 在飞伤害登记目标（终态扣减，见 _clear_incoming）
	if target != null and is_instance_valid(target) and "incoming_arrow_damage" in target:
		_registered_target = target


func _ready() -> void:
	# 箭在空中飞行：挂绝对高层（高于 y 排序单位 z≈0~140），落点不被单位身体盖住
	z_as_relative = false
	z_index = 900
	body_entered.connect(_on_body_entered)
	_launch_y = global_position.y


func _physics_process(delta: float) -> void:
	# TimeManager 暂停门禁：与实体同一"暂停"语义（暂停时箭矢悬停，不继续飞）
	if TimeManager != null and TimeManager.is_paused():
		return
	if _stuck:
		# 插地淡出（SWL fadeOutOver）
		_stuck_timer += delta
		if _stuck_timer >= STUCK_LIFETIME:
			queue_free()
		elif _stuck_timer >= STUCK_LIFETIME - 1.0:
			modulate.a = (STUCK_LIFETIME - _stuck_timer) / 1.0
		return
	# 抛物线积分：vel.y += g·dt（重力 y 向下为正）
	_vel.y += _gravity * delta
	var step := _vel * delta
	position += step
	_traveled += step.length()
	_flight_time += delta
	rotation = _vel.angle()
	# 手动命中检测（近战同款：不依赖物理碰撞）：箭到目标碰撞体距离 < HIT_RADIUS。
	# _target 是发射时锁定的敌方目标，无需阵营复查
	if _target != null and is_instance_valid(_target):
		var body_pos: Vector2 = _target_body_pos(_target)
		if global_position.distance_to(body_pos) <= HIT_RADIUS:
			_hit(_target)
			return
	# 落地判定（两条路径）：
	# ① 抛物线解算模式（solve_time>0）：飞满解算时间后沿弹道继续下落，越过
	#    瞄准点地面线即插——落点≈目标脚下，miss 自然插在敌阵（修复"低于出射点
	#    500px 才插地=贴地小半圆插前线"观感 bug，2026-09-01 观察场反馈 9c）
	# ② 旧调用（solve_time=0）：下落段低于出射点 GROUND_DROP，或兜底寿命到
	var landed: bool = false
	if _solve_time > 0.0:
		landed = _flight_time >= _solve_time \
				and (_solve_ground_y <= 0.0 or global_position.y >= _solve_ground_y)
		if _solve_time > 0.0 and _flight_time >= _solve_time + MAX_FLIGHT_TIME:
			landed = true  # 解算模式兜底（防极端弹道永生）
	else:
		landed = (_vel.y > 0.0 and global_position.y >= _launch_y + GROUND_DROP) \
				or _flight_time >= MAX_FLIGHT_TIME
	if landed:
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
	# 阵营过滤（SWL Arrow 碰撞只检敌方）：友军不挡箭不被打——
	# 抛物线下落段穿过己方人群时，误伤前排背后是"攻击友军"观感的根因
	if not _is_enemy(body):
		return
	# 命中实体本体（CharacterBody2D）
	if body is CharacterBody2D:
		_hit(body)


## 命中阵营判定：同阵营必不命中；任一方未参战（0）或射手信息缺失时保持可命中
## （兼容无阵营的测试桩/中立目标）
func _is_enemy(body: Node) -> bool:
	if _shooter == null or not is_instance_valid(_shooter):
		return true
	if not body.has_method("get_faction") or not _shooter.has_method("get_faction"):
		return true
	var f_shooter: int = _shooter.get_faction()
	var f_body: int = body.get_faction()
	if f_shooter == 0 or f_body == 0:
		return true
	return f_shooter != f_body


## 爆头判定：命中点高于目标身体中心 HEADSHOT_Y_RATIO × BODY_HEIGHT
func _is_headshot(target: Node, hit_pos: Vector2) -> bool:
	var body_pos := _target_body_pos(target)
	return hit_pos.y < body_pos.y - BODY_HEIGHT * HEADSHOT_Y_RATIO


func _hit(target: Node) -> void:
	# 箭矢终态：扣减在飞伤害估计（无论实际命中者是否登记目标——估计口径允许偏差）
	_clear_incoming()
	# ── 伤害走 DamagePipeline 单入口（SWL Unit.Damage 复刻）──
	var p := DamagePipeline.Params.new(_damage * (0.6 + 0.4 * _draw_power), _shooter)
	p.direction = _vel.normalized()
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
		target.apply_hit_reaction(_vel.normalized(), dealt * KNOCKBACK_PER_DAMAGE)
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
	# 箭矢终态：扣减在飞伤害估计（这箭没打中任何人，登记作废）
	_clear_incoming()
	# 监测引用失效（目标死后箭还在飞 → 立即插地）
	if _target != null and not is_instance_valid(_target):
		_target = null
	# 视觉：插地角度微微下倾
	rotation = _vel.angle() + 0.15


## 扣减登记目标头上的在飞伤害估计（11d MissingArrowsTolerance 估计口径；
## 箭矢所有终态调用一次，幂等：_registered_target 置空防重复扣减）
func _clear_incoming() -> void:
	if _registered_target == null:
		return
	if is_instance_valid(_registered_target) and "incoming_arrow_damage" in _registered_target:
		_registered_target.incoming_arrow_damage = maxf(
				0.0, _registered_target.incoming_arrow_damage - _damage)
	_registered_target = null
