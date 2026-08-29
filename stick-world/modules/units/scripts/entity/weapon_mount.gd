class_name WeaponMount
extends Node2D
## 武器挂载点 -- 管理武器/盾牌挂载、攻击动画触发与攻击执行。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1（WeaponMount）。
## 武器挂到右手骨骼 hand_inner（跟随手臂摆动），盾牌挂左手 hand_outer。
## 武器/盾牌贴图由 tools/baking/extract_weapons.gd 从解包 universal 图集裁剪
## （Swordbasic/Spear/Shield/Bow/Pickaxe/Magicstaff），场景带 GripPoint 对齐握把。
##
## 攻击流程（由 behavior_attack / 玩家附身调用）：
##   1. can_attack() 检查冷却
##   2. perform_attack(target) 按距离 + 命中率判定，命中则 target.apply_hit_reaction()
##   3. 攻击动画（attack.tres 转译自 Swordwrath-Attack1）驱动手臂挥砍，
##      武器挂 hand_inner 自动跟随，无需程序化 Tween。
##   4. 进入冷却，update_cooldown(delta) 每帧递减

# ─────────────────────────────── 武器类型 ────────────────────────────────
enum WeaponType { SWORD, SPEAR, BOW, PICKAXE, STAFF }

## 武器类型 -> 武器场景（贴图由 extract_weapons.gd 从解包图集裁剪）
const WEAPON_SCENE_PATHS: Dictionary = {
	WeaponType.SWORD: "res://modules/units/scenes/components/weapon_sword.tscn",
	WeaponType.SPEAR: "res://modules/units/scenes/components/weapon_spear.tscn",
	WeaponType.BOW: "res://modules/units/scenes/components/weapon_bow.tscn",
	WeaponType.PICKAXE: "res://modules/units/scenes/components/weapon_pickaxe.tscn",
	WeaponType.STAFF: "res://modules/units/scenes/components/weapon_magicstaff.tscn",
}
## 盾牌场景（挂左手）
const SHIELD_SCENE_PATH := "res://modules/units/scenes/components/weapon_shield.tscn"
## 箭矢投影物场景（弓远程攻击发射）
const ARROW_SCENE_PATH := "res://modules/units/scenes/components/arrow.tscn"
## 箭矢飞行速度（与 arrow_projectile.gd SPEED 一致，用于移动预判）
const ARROW_SPEED: float = 640.0
## 箭矢预判系数（瞄移动目标时提前量 × 飞行时间 × 系数）
const ARROW_LEAD_FACTOR: float = 0.7
## 拉弓满弓发射延迟（s）：attack_bow 动画 2.0s 的 ~37% 处放箭
const BOW_FIRE_DELAY: float = 0.75
## 盾牌格挡率（持盾被近战/箭矢命中时减伤概率）
const BLOCK_CHANCE: float = 0.35
## 格挡减伤系数（剩余伤害比例）
const BLOCK_DAMAGE_FACTOR: float = 0.15
## 各武器攻击射程（像素，含手臂长度）
const WEAPON_RANGE: Dictionary = {
	WeaponType.SWORD: 80.0,
	WeaponType.SPEAR: 120.0,
	WeaponType.BOW: 300.0,
	WeaponType.PICKAXE: 70.0,
	WeaponType.STAFF: 90.0,
}
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

# ─────────────────────────────── @export ────────────────────────────────
## 主手武器类型（默认剑）
@export var weapon_type: WeaponType = WeaponType.SWORD:
	set(v):
		weapon_type = v
		if is_inside_tree():
			call_deferred("_reload_weapons")
## 是否装备盾牌（挂左手 hand_outer）
@export var shield_enabled: bool = true:
	set(v):
		shield_enabled = v
		if is_inside_tree():
			call_deferred("_reload_weapons")
## 单次命中伤害
@export var damage: float = 15.0
## 攻击射程（像素），按武器类型初始化（WEAPON_RANGE）
@export var attack_range: float = 80.0
## 攻击冷却（秒）。对齐解包 Spine 攻击动画时长（Swordwrath-Attack1 = 1.33s）：
## 冷却 ≥ 动画时长才能完整播完挥剑（否则下次攻击打断未播完的动画）。
@export var cooldown: float = 1.35
## 基础命中率 [0,1]（近战高命中）
@export var base_hit_chance: float = 0.9

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前冷却剩余（秒）
var _cooldown_timer: float = 0.0
## 主手武器实例（挂 hand_inner 骨骼，跟随手臂）
var _weapon: Node2D = null
## 副手盾牌实例（挂 hand_outer 骨骼）
var _shield: Node2D = null
## 当前情绪标签
var _mood: Mood = Mood.STEADY
## 弓延迟发射：pending 目标与倒计时（拉弓满弓再放箭，视觉对齐 attack_bow 动画）
var _pending_bow_target: Node = null
var _bow_fire_timer: float = 0.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 延迟挂载：WeaponMount 是实体子节点，_ready 先于实体执行，
	# 此时 entity.rig 尚未赋值（实体 _ready 里获取），deferred 保证顺序。
	call_deferred("_mount_weapons")


## 挂载主手武器 + 副手盾牌到手骨骼（跟随手臂摆动）。
## 手骨骼挂在 forearm 末端（见 stickman_test.tscn），攻击/行走动画驱动
## forearm 时武器自动跟随；不再挂 IK marker（marker 静态，物体会飘在固定位置）。
func _mount_weapons() -> void:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		push_warning("[WeaponMount] 无持有实体，无法挂武器")
		return
	var hand: Node2D = _find_hand_bone(owner_entity)
	if hand == null:
		push_warning("[WeaponMount] 未找到主手骨骼（hand_inner），无法挂武器")
		return
	var scene_path: String = WEAPON_SCENE_PATHS.get(weapon_type, "")
	if scene_path.is_empty():
		push_warning("[WeaponMount] 未知武器类型: %d" % weapon_type)
		return
	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_warning("[WeaponMount] 武器场景加载失败: %s" % scene_path)
		return
	_weapon = _mount_one(scene, hand, "Weapon")
	attack_range = WEAPON_RANGE.get(weapon_type, attack_range)
	# 副手盾牌
	if shield_enabled:
		_mount_shield(owner_entity)


func _mount_shield(owner_entity: CharacterBody2D) -> void:
	var off_hand: Node2D = _find_shield_bone(owner_entity)
	if off_hand == null:
		push_warning("[WeaponMount] 未找到副手骨骼（hand_outer），无法挂盾")
		return
	var scene: PackedScene = load(SHIELD_SCENE_PATH)
	if scene == null:
		push_warning("[WeaponMount] 盾牌场景加载失败: %s" % SHIELD_SCENE_PATH)
		return
	_shield = _mount_one(scene, off_hand, "Shield")


## 挂载单个物品到骨骼，GripPoint 对齐握把。
## GripPoint 坐标 = 贴图握把相对贴图中心的像素偏移；对齐时乘 Sprite 缩放，
## 使握把视觉精确落在手骨骼上（否则握把悬空，出现"空气把手"）。
func _mount_one(scene: PackedScene, bone: Node2D, node_name: String) -> Node2D:
	var instance: Node2D = scene.instantiate()
	var grip := instance.get_node_or_null("GripPoint") as Marker2D
	if grip:
		var spr := instance.get_node_or_null("Sprite") as Sprite2D
		var s: float = spr.scale.x if spr else 1.0
		instance.position = -grip.position * s
		instance.rotation = -grip.rotation
	instance.name = node_name
	bone.add_child(instance)
	# SWL 槽序：武器(剑/矛/弓/镐/杖)在躯干/腿之后（slot 8 < torso 9），盾在最前（Arrow1 slot 20）
	instance.z_index = 20 if node_name == "Shield" else -2
	instance.z_as_relative = false
	return instance


## 重挂武器/盾牌（weapon_type / shield_enabled 变化时）
func _reload_weapons() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.get_parent().remove_child(_weapon)
		_weapon.queue_free()
		_weapon = null
	if _shield != null and is_instance_valid(_shield):
		_shield.get_parent().remove_child(_shield)
		_shield.queue_free()
		_shield = null
	_mount_weapons()


## 查找右手骨骼 hand_inner（rig 骨架下，挂在 forearm_inner 末端）。
func _find_hand_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/lower_torso/upper_torso/upper_arm_inner/forearm_inner/hand_inner")


## 查找左手骨骼 hand_outer（rig 骨架下，挂在 forearm_outer 末端）。
func _find_shield_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/lower_torso/upper_torso/upper_arm_outer/forearm_outer/hand_outer")


func _physics_process(delta: float) -> void:
	update_cooldown(delta)
	# 命中帧结算（Saga Strike 模式）
	_try_strike_frame()
	# 弓延迟发射：拉弓满弓时放箭（视觉对齐 attack_bow 动画）
	if _pending_bow_target != null:
		if is_instance_valid(_pending_bow_target):
			_bow_fire_timer -= delta
			if _bow_fire_timer <= 0.0:
				_fire_arrow(_pending_bow_target)
				_pending_bow_target = null
		else:
			_pending_bow_target = null


# ─────────────────────────────── 公共 API ────────────────────────────────

## 是否可以攻击（冷却结束）
func can_attack() -> bool:
	return _cooldown_timer <= 0.0


## 当前冷却剩余时间
func get_cooldown_remaining() -> float:
	return _cooldown_timer


## 执行一次攻击。
## 近战（剑/矛/镐/法杖）：距离 + 命中率判定，命中则目标受击反馈。
## 远程（弓）：发射箭矢投影物，命中由箭矢实际碰撞决定。
## target: 目标 StickmanEntity（必须有 HealthComponent）
## 返回 {hit: bool, damage: float, reason: String}
## 复刻 Saga MeleeAttackSystem：攻击 = 播放动画 + 在命中帧（动画进度 STRIKE_FRAME_RATIO）
## 结算一次伤害。近战命中不再是概率——只要在射程内且动画挥到命中帧就命中
## （原版近战无闪避概念；命中率字段保留给未来的"犹豫/恐慌"情绪系统使用）。
func perform_attack(target: Node) -> Dictionary:
	var result: Dictionary = {"hit": false, "damage": 0.0, "reason": ""}
	if not can_attack():
		result["reason"] = "cooldown"
		return result
	if target == null or not is_instance_valid(target):
		result["reason"] = "invalid_target"
		return result
	# 弓：远程射击（发射箭矢，命中由箭矢决定）
	if weapon_type == WeaponType.BOW:
		return _attack_ranged(target)
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
	# 登记待结算目标：动画播到命中帧时 _strike() 结算（复刻 Saga HitUpdate→Strike）
	_pending_strike_target = target
	_pending_strike_owner = owner_entity
	_strike_fired = false
	# 进入冷却（含情绪修正）
	_cooldown_timer = _get_effective_cooldown()
	result["reason"] = "striking"
	return result


## 命中帧结算（Saga Strike）：攻击动画播到 STRIKE_FRAME_RATIO 时调用一次。
## 由 _physics_process 监听攻击动画进度触发；结算走 DamagePipeline 单入口。
const STRIKE_FRAME_RATIO := 0.45

var _pending_strike_target: Node = null
var _pending_strike_owner: Node = null
var _strike_fired: bool = true

func _try_strike_frame() -> void:
	if _strike_fired or _pending_strike_target == null:
		return
	if not is_instance_valid(_pending_strike_target):
		_pending_strike_target = null
		return
	# 攻击动画进度检测（visual_controller 播 attack 后 rig 报告进度）
	var progress := _get_attack_anim_progress()
	if progress < STRIKE_FRAME_RATIO:
		return
	_strike_fired = true
	var target: Node = _pending_strike_target
	var owner_entity: Node = _pending_strike_owner
	_pending_strike_target = null
	# 挥到命中帧时二次确认距离（目标可能跑出射程：Saga AttackWhileStanding 同语义）
	if owner_entity == null or not is_instance_valid(owner_entity):
		return
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range * 1.25:
		return
	# 情绪修正命中率（犹豫/恐慌时挥空）
	if randf() > _get_effective_hit_chance():
		return
	# ── 伤害走 DamagePipeline 单入口（SWL Unit.Damage 复刻）──
	var p := DamagePipeline.Params.new(damage, owner_entity)
	p.direction = (target.global_position - owner_entity.global_position).normalized()
	p.type = DamagePipeline.DAMAGE_TYPE.MELEE
	p.knockback = damage * KNOCKBACK_PER_DAMAGE
	var dealt: float = DamagePipeline.apply(target, p)
	if owner_entity.has_method("get_battle_instance"):
		var battle: Node = owner_entity.get_battle_instance()
		if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
			battle.register_attacker(target, owner_entity)
	_hitstop()


## 读取当前攻击动画进度（0~1；无动画时返回 1 = 立即结算）
func _get_attack_anim_progress() -> float:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return 1.0
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_progress"):
		return 1.0
	return rig.get_anim_progress("attack")


## 每帧递减冷却（也可由外部调用）
func update_cooldown(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(0.0, _cooldown_timer - delta)


# ─────────────────────────────── 远程攻击（弓）────────────────────────────────

## 弓：发射箭矢朝向目标（命中由箭矢实际飞行碰撞决定，非概率）。
## 延迟发射：记录目标 + 倒计时，拉弓满弓（BOW_FIRE_DELAY）时再放箭，
## 视觉与 attack_bow 拉弓动画对齐。
## 返回 {hit:false, damage:0, reason:"fired"/...}——命中结果由箭头落地后报告。
func _attack_ranged(target: Node) -> Dictionary:
	var result: Dictionary = {"hit": false, "damage": 0.0, "reason": ""}
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		result["reason"] = "no_owner"
		return result
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range:
		result["reason"] = "out_of_range"
		return result
	_pending_bow_target = target
	_bow_fire_timer = BOW_FIRE_DELAY
	result["reason"] = "fired"
	_cooldown_timer = _get_effective_cooldown()
	return result


## 发射箭矢：从射手胸口高度朝目标身体（含移动预判）直线发射。
func _fire_arrow(target: Node) -> void:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		return
	var scene: PackedScene = load(ARROW_SCENE_PATH)
	if scene == null:
		push_warning("[WeaponMount] 箭矢场景加载失败: %s" % ARROW_SCENE_PATH)
		return
	# 射手胸口（Collider 上部）与目标身体中心（Collider 位置）
	var from: Vector2 = _body_pos(owner_entity) + Vector2(0, -70)
	var aim_point: Vector2 = _body_pos(target)
	var aim: Vector2 = aim_point - from
	# 移动预判：目标速度 × 飞行时间 × 系数（瞄准移动目标）
	if target is CharacterBody2D:
		aim += (target as CharacterBody2D).velocity * (aim.length() / ARROW_SPEED) * ARROW_LEAD_FACTOR
	var arrow: Node2D = scene.instantiate()
	var parent: Node = owner_entity.get_parent()
	if parent == null:
		parent = get_tree().current_scene
	parent.add_child(arrow)
	arrow.global_position = from
	# SWL drawPower：拉弓满弓比例（BOW_FIRE_DELAY 计时结束 = 满弓 1.0）
	if arrow.has_method("setup"):
		arrow.call("setup", aim.normalized(), damage, owner_entity, target, 1.0)


## 实体身体位置（Collider 世界坐标，缺省回落 global + 典型偏移）
func _body_pos(entity: Node) -> Vector2:
	var collider: Node = entity.get_node_or_null("Collider")
	if collider != null and collider is Node2D:
		return (collider as Node2D).global_position
	return entity.global_position + Vector2(8.5, 130)


## 获取挂在手部的武器实例（null=未挂载）
func get_weapon_node() -> Node2D:
	return _weapon


## 获取副手盾牌实例（null=未装备盾）
func get_shield_node() -> Node2D:
	return _shield


## 持盾格挡判定（被攻击方调用）：装备了盾 + 概率格挡
func is_shield_blocking() -> bool:
	if _shield == null or not is_instance_valid(_shield):
		return false
	return randf() < BLOCK_CHANCE


## 是否正在挥砍（程序化挥砍已移除，挥砍由攻击动画驱动，恒 false）
func is_swinging() -> bool:
	return false


# ─────────────────────────────── 内部 ────────────────────────────────

## 攻击挥砍：剑挂 hand_inner 骨骼，攻击动画（attack.tres 转译自
## Swordwrath-Attack1）驱动手臂挥砍，剑自动跟随，无需程序化 Tween 旋转。
func _play_swing() -> void:
	pass


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
