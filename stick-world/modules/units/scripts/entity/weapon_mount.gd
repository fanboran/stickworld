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
##   3. 攻击动画（按武器类型选，见 StickmanAnims.WEAPON_ATTACK_ANIM）驱动手臂挥砍，
##      武器挂 hand_inner 自动跟随，无需程序化 Tween。
##   4. 进入冷却，update_cooldown(delta) 每帧递减
##
## 命中帧（Saga MeleeAttackSystem.Strike 语义）：
##   **读动画内嵌事件的真值**，不写死比例。解包 Spine 数据里每个攻击动画都带
##   Hit 事件（Swordwrath-Attack1 Hit@1.0s / 全长 1.3333s = 75%；
##   Spearton-Attack1 Hit@0.8667s；Archidon-Draw Hit@0.5333s；Miner-Attack1 Hit@0.6667s；
##   Magikill-Spell1 Hit@1.0s），由 tools/baking/spine_import.gd 导出为动画元数据，
##   运行期经 StickmanRig.get_anim_event_time() 读取。
##   仅当动画确实没有事件数据（如程序化动画/测试桩）时才回退到 STRIKE_FRAME_RATIO_FALLBACK。

const Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")
## 兵种行为档案（aim_scatter 等按武器类型读取）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 状态效果（法术击晕 STUN 类型引用；显式 preload 防 headless class_name 未注册）
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")

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
## 抛物线箭矢水平分速（px/s；竖直初速按距离解算，重力 ARROW_GRAVITY）
const ARROW_VX: float = 850.0
## 抛物线箭矢重力（px/s²）：900px 远射弧顶 ≈ 230px（越友军头顶），150px 内近似平射
const ARROW_GRAVITY: float = 2000.0
## 箭矢预判系数（瞄移动目标时提前量 × 飞行时间 × 系数）
const ARROW_LEAD_FACTOR: float = 0.7
## 放箭延迟兜底（s）：仅当 attack_bow 动画**没有** Hit 事件元数据时使用。
## 有事件时以事件真值为准（Archidon-Draw Drawn@0.5s / Hit@0.5333s，全长 2.0s）——
## 拉弓动画在 0.5s 拉满（Drawn），0.5333s 放箭（Hit），而不是拍脑袋的 0.75s。
const BOW_FIRE_DELAY_FALLBACK: float = 0.5333
## 盾牌格挡率（持盾被近战/箭矢命中时减伤概率；原版 blockChance 同为概率掷骰）
const BLOCK_CHANCE: float = 0.35
## 格挡减伤系数（剩余伤害比例）
const BLOCK_DAMAGE_FACTOR: float = 0.15
## 格挡重置间隔（s）：一次成功格挡后，这段时间内不能再格挡。
## 复刻原版 blockResetInterval——无此节流时高攻速单位会被盾牌无限吃掉伤害。
const BLOCK_RESET_INTERVAL: float = 0.6
## 正面格挡判定：来袭方向与朝向夹角余弦大于此值才算"正面"（≈ ±75° 扇区）。
const BLOCK_FRONT_DOT: float = 0.25
## 各武器攻击射程（像素，含手臂长度）
## STAFF 600 = SWL Magikill 施法距离（半屏级；原 90 是"法杖敲击"值，会造成
## kite_range > 射程死锁：敌人一进保距圈就永远后撤永不还手）
## BOW 1400 = SWL 弓手观感射程（约全屏宽）——抛物线弹道下站后排越顶抛射
const WEAPON_RANGE: Dictionary = {
	WeaponType.SWORD: 80.0,
	WeaponType.SPEAR: 200.0,
	WeaponType.BOW: 1400.0,
	WeaponType.PICKAXE: 70.0,
	WeaponType.STAFF: 600.0,
}
## HitStop 参数（命中顿帧）
const HITSTOP_TIME_SCALE: float = 0.05
const HITSTOP_DURATION: float = 0.06
## HitStop 全局最小触发间隔（s）：多单位混战节流，0.3s 内至多冻结一次（审计 P0-2）
const HITSTOP_MIN_INTERVAL: float = 0.3
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
		# 换武器 = 换攻击动画 = 命中帧事件时间要重新解析
		_hit_time_resolved = false
		_hit_event_time = -1.0
		if is_inside_tree():
			call_deferred("_reload_weapons")
			# 持械站姿随武器分型（剑/矛/弓/镐/杖各一套 Stand），立即换姿
			call_deferred("_refresh_owner_stance")
## 是否装备盾牌（挂左手 hand_outer）
@export var shield_enabled: bool = true:
	set(v):
		shield_enabled = v
		if is_inside_tree():
			call_deferred("_reload_weapons")
			call_deferred("_refresh_owner_stance")
## 单次命中伤害
@export var damage: float = 15.0
## 攻击射程（像素），按武器类型初始化（WEAPON_RANGE）
@export var attack_range: float = 80.0
## 攻击冷却（秒）。对齐解包 Spine 攻击动画时长（Swordwrath-Attack1 = 1.33s）：
## 冷却 ≥ 动画时长才能完整播完挥剑（否则下次攻击打断未播完的动画）。
@export var cooldown: float = 1.35
## 基础命中率 [0,1]（近战高命中）
@export var base_hit_chance: float = 0.9

# ── 以下字段复刻原版 MeleeAttack_Prototype / Unit 的配置项，逐个单位可调 ──
## 一次挥击能打中的最大人数（原版 NumberOfUnitsThatCanHit）。
## 语义是 **AOE 挥击**：身前扇形内最多几个敌人吃满伤，不是"围攻上限"。
## 1 = 单体；矛/镐这类横扫武器可给 2~3。
@export var number_of_units_that_can_hit: int = 1
## 溅射可波及的额外人数（原版 NumberOfUnitsThatCanHitWithSplash）
@export var number_of_units_that_can_hit_with_splash: int = 0
## 溅射伤害系数（原版 SplashModifier，对超出 number_of_units_that_can_hit 的目标）
@export var splash_modifier: float = 0.5
## 爆头加伤（原版 Unit.headShotBonusDamage，**加值**不是倍率；箭矢爆头时叠加）
@export var head_shot_bonus_damage: float = 10.0
## 暴击率 [0,1]（原版 isCrit 掷骰）
@export var crit_chance: float = 0.0
## 暴击伤害倍率
@export var crit_damage_multiplier: float = 2.0
## 暴击自伤（原版 critBonusDamageInflictedToSelf——暴击的代价：
## 如 Swordwrath 暴击会崩断自己的剑并受伤）。0 = 无代价。
@export var crit_bonus_damage_inflicted_to_self: float = 0.0
## 挥击扇形半角（度）：AOE 挥击的判定范围
@export var strike_arc_half_angle: float = 55.0
## 命中后动画可打断比例（原版 AnimationCancelFractionOfAnimationAfterAttackHit）：
## 挥砍**命中帧已过**后，命中段剩余部分 × 此比例的尾段可被打断——下次攻击
## 不必等整条挥砍播完（冷却虽未走完也可提前出手）。0 = 关闭（等完整冷却）。
@export var animation_cancel_fraction: float = 0.5
## 反伤（原版 ApplyDamageReflect 链）：被近战/箭矢命中时把这点伤害反弹给攻击者
## （攻击者免疫与否由其 can_receive_reflect_damage 决定）。0 = 无反伤（默认）。
@export var reflect_damage: float = 0.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前冷却剩余（秒）
var _cooldown_timer: float = 0.0
## 主手武器实例（挂 hand_inner 骨骼，跟随手臂）
var _weapon: Node2D = null
## 副手盾牌实例（挂 hand_outer 骨骼）
var _shield: Node2D = null
## 当前情绪标签
var _mood: Mood = Mood.STEADY
## 延迟结算：pending 目标与倒计时（弓=拉弓满弓放箭 / 杖=施法前摇到点结算，
## 视觉对齐各自攻击动画）
var _pending_ranged_target: Node = null
var _bow_fire_timer: float = 0.0
## 举盾姿态（原版 IsBlocking()）：true 时该单位处于防御姿态，才可能格挡。
## 由 AI（守备/被压制）或玩家输入切换；仅持盾单位有效。
var _blocking: bool = false
## 格挡重置计时：>0 表示刚格挡过，期间不能再挡（blockResetInterval）
var _block_reset_timer: float = 0.0
## 当前攻击动画的 Hit 事件时间（秒）；<0 = 动画无事件数据，走比例兜底
var _hit_event_time: float = -1.0
## Hit 事件时间是否已解析（换武器时重置）
var _hit_time_resolved: bool = false

## 动画内嵌事件转发（Spine events[] 语义）。
## 目前用于 Sound:* 音效钩子；音效资产落地后按 SFX_PATHS 登记即可发声。
signal weapon_anim_event(anim_name: String, event_name: String, value: String)

## Spine 事件 string（如 "Swoosh"/"Thump"/"MagikillBlast"）→ 音效资源路径。
## 表为空 = 音效资产未落地，事件只发信号不发声（不会出现加载报错）。
const SFX_PATHS: Dictionary = {}


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
	# 副手盾牌（**绑定矛兵**：原版也只有 Spearton 持盾，其余兵种无盾——
	# 曾给全员挂盾导致"人手一面盾"的怪相，用户决策回归原版）
	if shield_enabled and weapon_type == WeaponType.SPEAR:
		_mount_shield(owner_entity)
	# 订阅动画内嵌事件（命中帧 + 音效钩子）
	_connect_rig_events(owner_entity)


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
## GripPoint = 纹理像素坐标（贴图中心为原点，即"手抓在贴图哪个点"），
## 来自解包附件数据换算（推导见各武器 tscn 头注释）。经 Sprite 的缩放+旋转
## 映射到武器根空间后取负，使握点精确落在挂载骨骼原点（手）上。
## 武器根自身不旋转，朝向完全由 Sprite.rotation 承担——旧实现把
## -grip.rotation 写在挂载根上、且映射忽略 Sprite 旋转，对带 ±90° 的
## 矛/镐/杖握点必错（跨栈翻译保真度审计 2026-08-30 修复）。
func _mount_one(scene: PackedScene, bone: Node2D, node_name: String) -> Node2D:
	var instance: Node2D = scene.instantiate()
	var grip := instance.get_node_or_null("GripPoint") as Marker2D
	var spr := instance.get_node_or_null("Sprite") as Sprite2D
	if grip != null and spr != null:
		instance.position = -(grip.position * spr.scale).rotated(spr.rotation)
	instance.name = node_name
	bone.add_child(instance)
	# 层级跟随单位所在带（EntityHost z=3）：相对层级 + 树序近似 SWL 槽序。
	# 旧写法 z_as_relative=false 是"绝对 z"——武器 -2 掉到所有地图瓦片层
	# （地面 0/装饰 1/建筑 2）之下、盾 20 压过前景层 10，武器被地面盖住。
	# 现在：武器 0 = 与身体填充同带，树序在手 subtree（盖腿/躯干/头，见
	# reorder_render_order 把 neck 提到臂前）；盾 1 = 全局 4，盖武器与全身，
	# 仍低于前景层 10。躯干盖武器需拆分填充层，待渲染重构（审计已知项）。
	instance.z_index = 1 if node_name == "Shield" else 0
	instance.z_as_relative = true
	return instance


## 惰性连接 rig.animation_event（Spine events[] 复刻信号）。
func _connect_rig_events(owner_entity: Node) -> void:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null or not rig.has_signal("animation_event"):
		return
	if rig.animation_event.is_connected(_on_rig_anim_event):
		return
	rig.animation_event.connect(_on_rig_anim_event)


## 动画事件回调：命中帧结算 + 音效事件转发。
## 只响应本武器对应的攻击动画（防止"播矛刺动画、被剑的事件误触发"）。
func _on_rig_anim_event(anim_name: String, event_name: String, value: String) -> void:
	if anim_name != _attack_anim_name():
		return
	weapon_anim_event.emit(anim_name, event_name, value)
	match event_name:
		"Hit":
			_try_strike_frame()
		"Sound":
			_play_event_sfx(value)


## 动画内嵌音效事件：查 SFX_PATHS 表播放（表为空则只转发信号、不发声）。
func _play_event_sfx(sfx_name: String) -> void:
	var path: String = SFX_PATHS.get(sfx_name, "")
	if path.is_empty():
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null and am.has_method("play_sfx"):
		am.play_sfx(path)


## 本武器的攻击动画名（与实体 play_attack 共用 StickmanAnims 的映射表）
func _attack_anim_name() -> String:
	return Anims.anim_for_weapon(weapon_type)


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
	# 兵种移速（SWL 兵种机动性差异：档案 move_mult → 实体 move_speed_mult）
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity != null and "move_speed_mult" in owner_entity:
		owner_entity.move_speed_mult = float(
				ScriptBehaviorProfiles.get_profile(int(weapon_type)).get("move_mult", 1.0))


## 查找武器骨 weapon_hand（SWL pickaxe1 补译；挂 hand_inner 手骨原点，
## 挥剑时武器随腕甩动——动画经 pickaxe1 通道驱动该骨旋转）。
func _find_hand_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand")


## 查找盾骨 shield_hand（SWL Arrow1 补译；挂 hand_outer 手骨原点，
## 拉弓/举盾的动画经 Arrow1 通道驱动该骨）。
func _find_shield_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_outer/forearm_outer/hand_outer/shield_hand")


func _physics_process(delta: float) -> void:
	update_cooldown(delta)
	# 格挡重置冷却（原版 blockResetInterval）
	if _block_reset_timer > 0.0:
		_block_reset_timer = maxf(0.0, _block_reset_timer - delta)
	# 命中帧结算（Saga Strike 模式）
	if not _strike_fired:
		_pending_strike_elapsed += delta
	_try_strike_frame()
	# 延迟发射/施法结算：远程计时到点按武器类型分派（视觉对齐攻击动画）
	if _pending_ranged_target != null:
		if is_instance_valid(_pending_ranged_target):
			_bow_fire_timer -= delta
			if _bow_fire_timer <= 0.0:
				if weapon_type == WeaponType.BOW:
					_fire_arrow(_pending_ranged_target)
				else:
					_cast_magic(_pending_ranged_target)
				_pending_ranged_target = null
		else:
			_pending_ranged_target = null


# ─────────────────────────────── 公共 API ────────────────────────────────

## 是否可以攻击。
## 冷却结束 → 可以；冷却未走完但命中帧已过、动画播进"可打断尾段"
## （原版 AnimationCancelFractionOfAnimationAfterAttackHit）→ 也可以提前出手。
func can_attack() -> bool:
	if _cooldown_timer <= 0.0:
		return true
	return _cancel_window_latched or _can_cancel_attack_anim()


## 动画可打断判定：本次攻击已挥过命中帧，且当前动画播放位置越过了
## 可打断点 = hit_time + cancel_fraction ×（动画时长 − hit_time）。
## cancel_fraction <= 0 = 关闭打断（等完整冷却）；无事件数据 / 未命中 /
## 动画已切走时同样不打断（保守走完整冷却）。
func _can_cancel_attack_anim() -> bool:
	if not _strike_fired or animation_cancel_fraction <= 0.0:
		return false
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return false
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_time") \
			or not rig.has_method("get_anim_length"):
		return false
	_resolve_hit_event_time()
	if _hit_event_time < 0.0:
		return false
	var t: float = rig.get_anim_time(_attack_anim_name())
	if t < 0.0:
		return false
	var anim_len: float = rig.get_anim_length(_attack_anim_name())
	var cancel_point: float = _hit_event_time \
			+ animation_cancel_fraction * maxf(0.0, anim_len - _hit_event_time)
	if t >= cancel_point:
		_cancel_window_latched = true
		return true
	return false


## 当前冷却剩余时间
func get_cooldown_remaining() -> float:
	return _cooldown_timer


## 执行一次攻击。
## 近战（剑/矛/镐）：距离 + 命中率判定，命中则目标受击反馈。
## 远程（弓）：发射箭矢投影物，命中由箭矢实际碰撞决定。
## 施法（杖）：延迟结算（attack_staff 的 Spell Hit@1.0s 前摇到点直接结算，
## SWL Magikill-Spell1 语义；弹道化见待办"魔法弹投射物"）。
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
	# 弓：发射箭矢（命中由箭矢决定）；杖：延迟施法结算
	if weapon_type == WeaponType.BOW or weapon_type == WeaponType.STAFF:
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
	# 挥砍动画（无论命中与否都有挥砍动作）。
	# 必须由发起攻击这一步自己触发：命中帧是按动画时间结算的，若等外部（AI/玩家）
	# 之后再播动画，首帧动画尚未起播 → 命中会被判成"立即结算"，对齐就白做了。
	_play_swing()
	# 登记待结算目标：动画播到命中帧时 _strike() 结算（复刻 Saga HitUpdate→Strike）
	_pending_strike_target = target
	_pending_strike_owner = owner_entity
	_strike_fired = false
	_pending_strike_elapsed = 0.0
	_cancel_window_latched = false
	# 进入冷却（含情绪修正）
	_cooldown_timer = _get_effective_cooldown()
	result["reason"] = "striking"
	return result


## 空挥（复刻原版 User Control：附身单位无目标也可出攻击动作）。
## 播对应武器攻击动画 + 进冷却；不登记目标 → 命中帧 _strike() 无结算
## （弓空挥 = 拉弓不放箭，与原版一致）。返回是否成功起挥（冷却中为 false）。
func perform_swing() -> bool:
	if not can_attack():
		return false
	_play_swing()
	_pending_strike_target = null
	_pending_strike_owner = get_owner_entity()
	_strike_fired = false
	_pending_strike_elapsed = 0.0
	_cancel_window_latched = false
	_cooldown_timer = _get_effective_cooldown()
	return true


## 命中帧兜底比例：只在动画**没有** Hit 事件数据时使用（程序化动画/测试桩）。
## 有事件数据时一律用事件真值——解包数据里各武器命中点差异很大
## （剑 75%、矛 52%、弓 27%、镐 67%、杖 60%），写死 0.45 是拍脑袋。
const STRIKE_FRAME_RATIO_FALLBACK := 0.45
## 攻击动画起播宽限（s）：perform_attack 与动画真正起播之间有一两帧延迟
## （travel → AnimationTree 下一帧才切状态）。等待期间不结算，否则命中会退化成
## "发起瞬间就结算"（等于白做命中帧对齐）。宽限过后仍未起播（无 rig / 无动画）
## 立即结算，保证 headless 与无动画场景不卡住。
const STRIKE_ANIM_GRACE := 0.3

var _pending_strike_target: Node = null
var _pending_strike_owner: Node = null
var _strike_fired: bool = true
## 发起攻击后经过的时间（用于动画起播宽限判定）
var _pending_strike_elapsed: float = 0.0
## 可打断窗口锁存：动画一旦越过可打断点即置位，下次起挥时复位。
## 决策（AI 轮询 can_attack）与执行（perform_attack）之间可能隔帧、动画时间
## 已继续推进——锁存保证"看到窗口开着 → 出手必成"，不因查询时序丢攻击。
var _cancel_window_latched: bool = false

## 命中帧结算（Saga MeleeAttackSystem.Strike）：
## 攻击动画播到 **Hit 事件时间** 时结算一次；无事件数据时回退到进度比例。
## 触发源有两个（都经 _strike_fired 保证只结算一次）：
##   ① rig.animation_event 的 "Hit" 事件（有事件数据时的主路径）
##   ② _physics_process 轮询（兜底：无事件数据 / 事件信号尚未接上）
func _try_strike_frame() -> void:
	if _strike_fired or _pending_strike_target == null:
		return
	if not is_instance_valid(_pending_strike_target):
		_pending_strike_target = null
		return
	if not _has_reached_hit_frame():
		return
	_strike_fired = true
	var target: Node = _pending_strike_target
	var owner_entity: Node = _pending_strike_owner
	_pending_strike_target = null
	# 空挥（perform_swing 无登记目标）：纯动作，命中帧无结算
	if target == null or not is_instance_valid(target):
		return
	# 挥到命中帧时二次确认距离（目标可能跑出射程：Saga AttackWhileStanding 同语义）
	if owner_entity == null or not is_instance_valid(owner_entity):
		return
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range * 1.25:
		return
	# 情绪修正命中率（犹豫/恐慌时挥空）
	if randf() > _get_effective_hit_chance():
		return
	# 暴击掷骰（原版 isCrit；暴击附带自伤代价 critBonusDamageInflictedToSelf）
	var is_crit: bool = randf() < crit_chance
	# ── AOE 挥击：身前扇形内按 number_of_units_that_can_hit 结算多个目标 ──
	var victims: Array = _collect_strike_targets(owner_entity, target)
	for i in victims.size():
		var victim: Node = victims[i]
		var p := DamagePipeline.Params.new(damage, owner_entity)
		p.direction = (victim.global_position - owner_entity.global_position).normalized()
		p.type = DamagePipeline.DAMAGE_TYPE.MELEE
		p.knockback = damage * KNOCKBACK_PER_DAMAGE
		p.is_crit = is_crit
		p.crit_damage_multiplier = crit_damage_multiplier
		p.crit_self_damage = crit_bonus_damage_inflicted_to_self
		p.head_shot_bonus_damage = head_shot_bonus_damage
		# 超出"能打中人数"的部分按溅射系数结算（NumberOfUnitsThatCanHitWithSplash）
		if i >= number_of_units_that_can_hit:
			p.amount *= splash_modifier
			p.type = DamagePipeline.DAMAGE_TYPE.SPLASH
			p.is_blockable = false
		DamagePipeline.apply(victim, p)
		if owner_entity.has_method("get_battle_instance"):
			var battle: Node = owner_entity.get_battle_instance()
			if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
				battle.register_attacker(victim, owner_entity)
	_hitstop()


## 是否已越过命中帧。
## 有 Hit 事件 → 比较动画播放的**绝对秒**与事件时间；
## 无事件 → 回退到进度比例（0~1）与 STRIKE_FRAME_RATIO_FALLBACK 比较。
func _has_reached_hit_frame() -> bool:
	_resolve_hit_event_time()
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return true
	var rig: Node = owner_entity.get("rig")
	if rig == null:
		return true
	var anim_name: String = _attack_anim_name()
	if _hit_event_time >= 0.0 and rig.has_method("get_anim_time"):
		var t: float = rig.get_anim_time(anim_name)
		if t < 0.0:
			# 动画尚未起播 / 已播完切走：宽限期内继续等，超时才结算
			return _pending_strike_elapsed >= STRIKE_ANIM_GRACE
		return t >= _hit_event_time
	# 无事件数据：回退到进度比例（旧行为，立即结算语义不变）
	if rig.has_method("get_anim_progress"):
		return rig.get_anim_progress(anim_name) >= STRIKE_FRAME_RATIO_FALLBACK
	return true


## AOE 挥击目标列表：主目标 + 扇形内最近的 N-1 个敌人（NumberOfUnitsThatCanHit），
## 再加 number_of_units_that_can_hit_with_splash 个溅射目标。
## 返回数组按"先满伤、后溅射"排序，调用方按下标决定是否乘 splash_modifier。
func _collect_strike_targets(owner_entity: Node, main_target: Node) -> Array:
	if owner_entity == null or main_target == null:
		return [main_target] if main_target != null else []
	var max_count: int = number_of_units_that_can_hit + number_of_units_that_can_hit_with_splash
	if max_count <= 1:
		return [main_target]
	var facing: Vector2 = _owner_facing(owner_entity, main_target)
	var found: Array = TargetFinder.find_targets_in_arc(owner_entity, {
		"range": attack_range * 1.25,
		"half_angle": strike_arc_half_angle,
		"max_count": max_count,
		"force_first": main_target,
		"facing": facing,
	})
	if found.is_empty():
		return [main_target]
	return found


## 挥击朝向：优先实体自身朝向（get_facing），单位没有该接口时回退到"面向主目标"
func _owner_facing(owner_entity: Node, main_target: Node) -> Vector2:
	if owner_entity != null and owner_entity.has_method("get_facing"):
		return Vector2(float(owner_entity.get_facing()), 0.0)
	if owner_entity != null and main_target != null:
		return (main_target.global_position - owner_entity.global_position).normalized()
	return Vector2.RIGHT


## 解析当前武器攻击动画的 Hit 事件时间（真值，秒）。
func _resolve_hit_event_time() -> void:
	if _hit_time_resolved:
		return
	_hit_time_resolved = true
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_event_time"):
		return
	_hit_event_time = rig.get_anim_event_time(_attack_anim_name(), "Hit")


## 每帧递减冷却（也可由外部调用）
func update_cooldown(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(0.0, _cooldown_timer - delta)


# ─────────────────────────────── 远程攻击（弓）────────────────────────────────

## 弓：发射箭矢朝向目标（命中由箭矢实际飞行碰撞决定，非概率）。
## 延迟发射：记录目标 + 倒计时，拉弓拉满（attack_bow 的 Hit 事件 @0.5333s）时放箭。
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
	_pending_ranged_target = target
	_bow_fire_timer = _get_bow_fire_delay()
	result["reason"] = "fired"
	_cooldown_timer = _get_effective_cooldown()
	return result


## 放箭/施法结算延迟（s）：读攻击动画的 Hit 事件真值
## （弓 Archidon-Draw Hit@0.5333s 满弓 / 杖 Magikill-Spell1 Hit@1.0s 施法前摇），
## 无事件数据时回退 BOW_FIRE_DELAY_FALLBACK。
func _get_bow_fire_delay() -> float:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return BOW_FIRE_DELAY_FALLBACK
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_event_time"):
		return BOW_FIRE_DELAY_FALLBACK
	var t: float = rig.get_anim_event_time(_attack_anim_name(), "Hit")
	return t if t >= 0.0 else BOW_FIRE_DELAY_FALLBACK


## 法术结算（SWL Magikill-Spell1 施法前摇到点）：不发射投射物，直接对目标
## 结算 SPELL 伤害——格挡对法术无效（is_blockable=false，原版盾挡箭不挡魔法）。
## 弹道化（魔法弹投射物可 miss）见待办"箭矢重力弹道"条目。
func _cast_magic(target: Node) -> void:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or target == null or not is_instance_valid(target):
		return
	var health: Node = _get_health(target)
	if health == null or health.is_dead():
		return
	var p := DamagePipeline.Params.new(damage, owner_entity)
	p.direction = (target.global_position - owner_entity.global_position).normalized()
	p.type = DamagePipeline.DAMAGE_TYPE.SPELL
	p.is_blockable = false
	var dealt: float = DamagePipeline.apply(target, p)
	# 击晕（SWL Magikill 法术效果，StunSystem 语义）：被法术命中短暂眩晕——
	# 给召唤护卫争取围堵时间；状态效果系统的首个消费者
	if dealt > 0.0 and target.has_method("apply_status"):
		target.apply_status(ScriptStatusEffects.Type.STUN, 0.5, 0.0, owner_entity)
	# 登记攻击者（防集火；与箭矢一致）
	if owner_entity.has_method("get_battle_instance"):
		var battle: Node = owner_entity.get_battle_instance()
		if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
			battle.register_attacker(target, owner_entity)
	if dealt > 0.0 and target.has_method("apply_hit_reaction"):
		target.apply_hit_reaction(p.direction, dealt * KNOCKBACK_PER_DAMAGE)


## 发射箭矢：从射手胸口**抛物线**发射（SWL Arrow.launchY/AimAngle 弹道）。
## 固定重力 G，水平分速按距离解算，竖直初速度解抛物线过目标点——
## 近距离平射、远距自动高弧越顶（友军前排不挡箭），这是弓手能站后排
## 远程压制的物理基础（直线弹道会把箭全打在自己前排背上）。
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
	# 抛物线解算（SWL AimAngle 语义）：飞行时间 T 按全距离取（基准速 ARROW_VX），
	# 初速 = 直线分量(d/T) + 抛物线补偿(−½GT)——T 秒后恰好落到目标点，方向自洽
	# （旧解算用 dist_x 且 lead 加进 vx/vy，纵深差大时方向失配 = "轨迹奇怪"根因）
	var dist: float = from.distance_to(aim_point)
	var t: float = clampf(dist / ARROW_VX, 0.12, 2.2)
	# 移动预判：先按 T 平移目标点，再对**新目标点**解算（保证弹道自洽）
	if target is CharacterBody2D:
		aim_point += (target as CharacterBody2D).velocity * t * ARROW_LEAD_FACTOR
		dist = from.distance_to(aim_point)
		t = clampf(dist / ARROW_VX, 0.12, 2.2)
	var aim: Vector2 = aim_point - from
	var vel := Vector2(aim.x / t, aim.y / t - 0.5 * ARROW_GRAVITY * t)
	# SWL AimAngle 散布（currentShotBodyRandomness/NextGaussian）：出弓方向加高斯扰动，
	# σ 取兵种档案 aim_scatter（rad）——箭雨自然散开，不再人人弹道全同
	var scatter: float = float(ScriptBehaviorProfiles.get_profile(int(weapon_type)).get("aim_scatter", 0.0))
	if scatter > 0.0:
		var u1: float = maxf(randf(), 0.0001)
		var g: float = sqrt(-2.0 * log(u1)) * cos(TAU * randf())
		vel = vel.rotated(g * scatter)
	var arrow: Node2D = scene.instantiate()
	var parent: Node = owner_entity.get_parent()
	if parent == null:
		parent = get_tree().current_scene
	parent.add_child(arrow)
	arrow.global_position = from
	# SWL drawPower：拉弓满弓比例（BOW_FIRE_DELAY 计时结束 = 满弓 1.0）
	if arrow.has_method("setup"):
		arrow.call("setup", vel, damage, owner_entity, target, 1.0, ARROW_GRAVITY)
	# 箭矢威胁标记（SWL SpeartonAi.IsAnyArrowThreat 感知源）：出弓瞬间通知目标，
	# 举盾兵种（档案 arrow_threat_block）在威胁窗口内举盾
	if target != null and is_instance_valid(target) and "arrow_threat_time" in target:
		target.arrow_threat_time = Time.get_ticks_msec() / 1000.0


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


## 持盾格挡判定（被攻击方调用；DamagePipeline 的格挡入口）。
## 复刻原版三件套，缺一不可：
##   ① 装备了盾（持盾单位才可能挡）
##   ② **处于举盾姿态** IsBlocking()——原版不是无条件概率，Spearton 要真的举盾才挡
##   ③ 伤害来自**正面**（CanBlockAttack() 的姿态/方向判定）
## 外加 blockResetInterval 节流：刚格挡过的一段时间内不能再挡。
## incoming_dir: 攻击者→受击者方向；留空（零向量）时跳过正面判定。
func is_shield_blocking(incoming_dir: Vector2 = Vector2.ZERO) -> bool:
	if _shield == null or not is_instance_valid(_shield):
		return false
	if not _blocking:
		return false
	if _block_reset_timer > 0.0:
		return false
	if incoming_dir != Vector2.ZERO and not _is_frontal(incoming_dir):
		return false
	return randf() < BLOCK_CHANCE


## 举盾姿态（原版 IsBlocking()）：true = 该单位正处于防御姿态。
## 由 AI（守备/被压制）或玩家输入切换；无盾单位设了也挡不住。
func set_blocking(v: bool) -> void:
	_blocking = v


## 是否处于举盾姿态（受击方选受击动画用：举盾被击走 Hit-Spearton-Block 池）
func is_blocking() -> bool:
	return _blocking


## 是否处于举盾姿态
func get_blocking() -> bool:
	return _blocking


## 标记一次成功格挡（由 DamagePipeline 调用）：启动 blockResetInterval 冷却，
## 防止高攻速单位被同一面盾连续无限吃掉伤害。
func notify_block_succeeded() -> void:
	_block_reset_timer = BLOCK_RESET_INTERVAL


## 是否可被反伤（原版 Unit.CanReceiveReflectDamage 虚方法，缺省可被反伤）。
## 未来免疫反伤的单位类型（雕像/亡灵等）在此覆写。
func can_receive_reflect_damage() -> bool:
	return true


## 正面判定：来袭方向（攻击者→自己）与自身朝向相反 ⇒ 从正面打来。
## facing=+1 面向右 ⇒ 来自右侧的攻击（incoming_dir.x > 0）是正面。
func _is_frontal(incoming_dir: Vector2) -> bool:
	var owner_entity: Node = get_owner_entity()
	var facing: float = 1.0
	if owner_entity != null and owner_entity.has_method("get_facing"):
		facing = float(owner_entity.get_facing())
	if facing == 0.0:
		return true
	return incoming_dir.normalized().dot(Vector2(signf(facing), 0.0)) >= BLOCK_FRONT_DOT


## 是否正在挥砍（程序化挥砍已移除，挥砍由攻击动画驱动，恒 false）
func is_swinging() -> bool:
	return false


# ─────────────────────────────── 内部 ────────────────────────────────

## 攻击挥砍：剑挂 hand_inner 骨骼，攻击动画（按武器类型选，转译自解包 Spine）
## 驱动手臂挥砍，剑自动跟随，无需程序化 Tween 旋转。
## 由发起攻击这一步直接触发——命中帧按动画时间结算，动画必须先起播。
func _play_swing() -> void:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity != null and owner_entity.has_method("play_attack"):
		owner_entity.play_attack()


## 命中顿帧：短暂冻结时间（打击感核心，参考 Stickman Burst Hit Stop 方案）。
## headless 下禁用（避免拖慢测试计时）。
## 2026-08-31 审计 P0-2 规模节流：全局 Engine.time_scale 冻结是为 1v1 打击感
## 设计的——24+ 单位混战每次近战命中都冻结整个世界，画面反复掉到 5% 速度
## 且多个恢复 timer 互相覆盖。加全局最小触发间隔（0.3s 至多一次）。
static var _last_hitstop_ms: int = -100000

func _hitstop() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# 2026-08-31 四轮审计：全局 time_scale 冻结只在**玩家附身单位命中**时触发——
	# 48 人观察场每 0.3s 冻结全世界 0.06s = "又加速又卡顿掉帧"的元凶。
	# AI 互殴的打击感由受击硬直/击退/红闪承担（原版 SWL 也不冻结全场）
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or not owner_entity.is_possessed():
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_hitstop_ms < int(HITSTOP_MIN_INTERVAL * 1000.0):
		return
	_last_hitstop_ms = now_ms
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
## 换武器后让持有者立即换持械站姿（visual_controller.refresh_idle_stance）。
func _refresh_owner_stance() -> void:
	var e := get_owner_entity()
	if e != null and e.has_method("refresh_stance"):
		e.refresh_stance()


func get_owner_entity() -> CharacterBody2D:
	var p: Node = get_parent()
	if p is CharacterBody2D:
		return p as CharacterBody2D
	return null
