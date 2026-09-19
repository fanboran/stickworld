extends RefCounted
## 远程攻击助手 —— 从 weapon_mount.gd 拆出的弹道/施法子域（无自持状态）。
##
## 职责：
## - attack_ranged：弓/杖远程攻击入口（距离检查 + 延迟发射登记 + 冷却推进）；
## - fire_arrow：抛物线箭矢发射（SWL Arrow.launchY/AimAngle 弹道 + 散布热度）；
## - cast_magic / _apply_spell_blast：法术结算 + 命中点爆炸 AOE（放倒一片）。
##
## 纪律：状态（_pending_ranged_target/_bow_fire_timer/_sustained_fire_heat/冷却
## 计时）全部留在宿主 WeaponMount，经 _mount 动态回引读写；
## BattleSim.register_ranged 回调对象仍传宿主 mount（sim 为时序权威，
## 到点回调 mount.sim_fire_now）。

## 状态效果（法术击晕 STUN 类型引用；显式 preload 防 headless class_name 未注册）
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")
## 兵种行为档案（spell_aoe_radius/aim_scatter 按武器类型读取）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## 远程攻击（弓）：发射箭矢朝向目标（命中由箭矢实际飞行碰撞决定，非概率）。
## 延迟发射：记录目标 + 倒计时，拉弓拉满（attack_bow 的 Hit 事件 @0.5333s）时放箭。
## 返回 {hit:false, damage:0, reason:"fired"/...}——命中结果由箭头落地后报告。
## sim 模式：倒计时与冷却归 BattleSim，到点回调 sim_fire_now()。
func attack_ranged(target: Node) -> Dictionary:
	var result: Dictionary = {"hit": false, "damage": 0.0, "reason": ""}
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		result["reason"] = "no_owner"
		return result
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > _mount.attack_range:
		result["reason"] = "out_of_range"
		return result
	_mount._pending_ranged_target = target
	var s = _mount._sim()
	if s != null:
		s.register_ranged(_mount._sim_sid(), _mount, target, _get_bow_fire_delay())
		s.set_cooldown(_mount._sim_sid(), _mount._get_effective_cooldown())
	else:
		_mount._bow_fire_timer = _get_bow_fire_delay()
		_mount._cooldown_timer = _mount._get_effective_cooldown()
	result["reason"] = "fired"
	return result


## 放箭/施法结算延迟（s）：读攻击动画的 Hit 事件真值
## （弓 Archidon-Draw Hit@0.5333s 满弓 / 杖 Magikill-Spell1 Hit@1.0s 施法前摇），
## 无事件数据时回退 BOW_FIRE_DELAY_FALLBACK。
func _get_bow_fire_delay() -> float:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return _mount.BOW_FIRE_DELAY_FALLBACK
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_event_time"):
		return _mount.BOW_FIRE_DELAY_FALLBACK
	var t: float = rig.get_anim_event_time(_mount._attack_anim_name(), "Hit")
	return t if t >= 0.0 else _mount.BOW_FIRE_DELAY_FALLBACK


## 法术结算（SWL Magikill.CastStun 施法前摇到点，AI 自动锁敌路径）：
## 以目标为心结算——格挡对法术无效（is_blockable=false，原版盾挡箭不挡魔法）。
## **命中点爆炸 AOE（放倒一片）**：对齐 dump Magikill.CastStun/StunOpponents/
## unitsToDamage/STUN_RANGE 真值——命中点半径内敌人同时受击 + 击晕（2026-09-01 反馈 9e），
## 半径挂档案 spell_aoe_radius（STAFF 90），并触发 MAGIC_BLAST 爆炸粒子。
## 结算核心在 _cast_magic_core（与玩家指向施法 cast_magic_at 共用）。
func cast_magic(target: Node) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or target == null or not is_instance_valid(target):
		return
	var health: Node = _mount._get_health(target)
	if health == null or health.is_dead():
		return
	_cast_magic_core(owner_entity, (target as Node2D).global_position, target)


# ─────────────────────────────── 玩家手动弹道（蓄力操控）────────────────────

## 玩家手动放箭（SWL UserControlledArrowReleased）：方向=鼠标指向、力度=按住
## 时长→箭速 lerp(VX_MIN, VX_MAX)。与 AI 解算路径的差异：
## - **零散布零热度**（SWL 玩家拖拽即精确，aim_scatter 是 AI 技术差的模拟）；
## - 无锁定目标（命中走 Area2D 物理碰撞路径），落点走旧模式（低于出射点
##   GROUND_DROP 插地）——瞄准自由度完全交给玩家（平射/吊射自选）。
## draw_power 沿用箭矢伤害公式（0.6+0.4×power）。返回箭矢实例（箭矢镜头消费）。
func fire_arrow_manual(aim_dir: Vector2, power: float) -> Node2D:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return null
	var scene: PackedScene = _mount.ARROW_SCENE
	if scene == null:
		return null
	var from: Vector2 = get_muzzle_pos(owner_entity)
	var vel: Vector2 = aim_dir.normalized() * _mount.charge_launch_speed(power)
	var arrow: Node2D = scene.instantiate()
	var parent: Node = owner_entity.get_parent()
	if parent == null:
		parent = _mount.get_tree().current_scene
	parent.add_child(arrow)
	arrow.global_position = from
	if arrow.has_method("setup"):
		arrow.call("setup", vel, _mount.effective_damage(), owner_entity, null, power, _mount.ARROW_GRAVITY, 0.0, 0.0)
	return arrow


## 矛投射物场景（SWL Spearton.SpawnSpear；复用 arrow_projectile 抛物线链路）
const SPEAR_SCENE_PATH := "res://modules/units/scenes/components/spear_projectile.tscn"
const SPEAR_SCENE: PackedScene = preload("res://modules/units/scenes/components/spear_projectile.tscn")
## 矛出手速度区间（px/s）：矛重于箭，满力 950 但无抛物线解算补偿——
## 落点全凭玩家手感，投掷是技能型操作
const SPEAR_SPEED_MIN: float = 420.0
const SPEAR_SPEED_MAX: float = 950.0
## 矛投射物重力（与箭同源重力场）
const SPEAR_GRAVITY: float = 2000.0


## 玩家蓄力投矛（SWL Spearton.ThrowSpear）：初速沿瞄准方向、重力抛物线；
## 伤害走 draw_power 公式；无锁定目标，命中走物理碰撞路径。
func throw_spear_manual(aim_dir: Vector2, power: float) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return
	var from: Vector2 = get_muzzle_pos(owner_entity)
	var vel: Vector2 = aim_dir.normalized() * lerpf(SPEAR_SPEED_MIN, SPEAR_SPEED_MAX, clampf(power, 0.0, 1.0))
	var spear: Node2D = SPEAR_SCENE.instantiate()
	var parent: Node = owner_entity.get_parent()
	if parent == null:
		parent = _mount.get_tree().current_scene
	parent.add_child(spear)
	spear.global_position = from
	if spear.has_method("setup"):
		spear.call("setup", vel, _mount.effective_damage(), owner_entity, null, power, SPEAR_GRAVITY, 0.0, 0.0)


## 玩家指向施法（SWL Magikill 施法的 PC 翻译）：以鼠标落点为心结算——
## 落点半径内最近敌为主目标全额受击，其余敌人走 AOE 半伤+击晕；
## 落点无敌则只播爆炸粒子（空地施法，威慑/预判走位用）。
func cast_magic_at(owner_entity: CharacterBody2D, point: Vector2) -> void:
	if owner_entity == null:
		return
	var main_target: Node = _nearest_enemy_to_point(owner_entity, point)
	_cast_magic_core(owner_entity, point, main_target)


## 落点半径内最近敌（主目标挑选；半径取 AOE 半径，档案缺省 90）
func _nearest_enemy_to_point(owner_entity: CharacterBody2D, point: Vector2) -> Node:
	var aoe: float = float(ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("spell_aoe_radius", 90.0))
	var best: Node = null
	var best_dist: float = aoe
	for e in _enemies_of(owner_entity):
		if e is Node2D:
			var d: float = (e as Node2D).global_position.distance_to(point)
			if d <= best_dist:
				best_dist = d
				best = e
	return best


## 敌方集合（battle 优先，回退地图实体表——explore 野外施法也能结算）
func _enemies_of(owner_entity: CharacterBody2D) -> Array:
	if owner_entity.has_method("get_battle_instance"):
		var battle: Node = owner_entity.get_battle_instance()
		if battle != null and is_instance_valid(battle) and battle.has_method("get_enemies_of"):
			return battle.get_enemies_of(owner_entity.get_faction())
	var map_ref: Node = owner_entity.get("map_ref") if "map_ref" in owner_entity else null
	if map_ref != null and is_instance_valid(map_ref) and map_ref.has_method("get_entities"):
		var out: Array = []
		for e in map_ref.get_entities():
			if e is CharacterBody2D and e != owner_entity \
					and (not e.has_method("get_faction") or e.get_faction() != owner_entity.get_faction()) \
					and not (e.has_method("is_dead") and e.is_dead()):
				out.append(e)
		return out
	return []


## 法术结算核心（cast_magic 与 cast_magic_at 共用）：center 为爆炸心
## （AI 路径=目标位置，玩家路径=鼠标落点），main_target 全额受击
## （可为 null=空地施法），AOE 半伤+击晕以 center 为心。
func _cast_magic_core(owner_entity: CharacterBody2D, center: Vector2, main_target: Node) -> void:
	if main_target != null and is_instance_valid(main_target):
		var health: Node = _mount._get_health(main_target)
		if health != null and not health.is_dead():
			var p := DamagePipeline.Params.new(_mount.effective_damage(), owner_entity)
			p.direction = (center - owner_entity.global_position).normalized()
			p.type = DamagePipeline.DAMAGE_TYPE.SPELL
			p.is_blockable = false
			var dealt: float = DamagePipeline.apply(main_target, p)
			# 击晕（SWL Magikill 法术效果，StunSystem 语义）：给召唤护卫争取围堵时间
			if dealt > 0.0 and main_target.has_method("apply_status"):
				main_target.apply_status(ScriptStatusEffects.Type.STUN, 0.5, 0.0, owner_entity)
			# 登记攻击者（防集火；与箭矢一致）
			if owner_entity.has_method("get_battle_instance"):
				var battle: Node = owner_entity.get_battle_instance()
				if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
					battle.register_attacker(main_target, owner_entity)
			if dealt > 0.0 and main_target.has_method("apply_hit_reaction"):
				main_target.apply_hit_reaction(p.direction, dealt * _mount.KNOCKBACK_PER_DAMAGE)
	# 命中点爆炸 AOE（放倒一片）+ 爆炸粒子（以结算心为中心）
	var aoe_radius: float = float(
			ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("spell_aoe_radius", 0.0))
	if aoe_radius > 0.0:
		_apply_spell_blast_at(owner_entity, center, aoe_radius)
	if owner_entity.get_tree() != null:
		FxPool.spawn_burst(owner_entity.get_tree(), FxLibrary.MAGIC_BLAST,
				center + Vector2(0, -30))


## 法术爆炸 AOE 结算（SWL StunOpponents 直译，坐标版）：center 半径内其他敌人
## 受 50% SPELL 伤害 + 同步击晕——"放倒一片"的核心；主目标已在 core 全额结算。
func _apply_spell_blast_at(owner_entity: CharacterBody2D, center: Vector2, radius: float) -> void:
	var faction: int = owner_entity.get_faction() if owner_entity.has_method("get_faction") else 0
	if faction == 0:
		return
	for e in _enemies_of(owner_entity):
		if e == null or not is_instance_valid(e) or not (e is Node2D):
			continue
		if (e as Node2D).global_position.distance_to(center) > radius:
			continue
		var ep := DamagePipeline.Params.new(_mount.effective_damage() * 0.5, owner_entity)
		ep.direction = ((e as Node2D).global_position - center).normalized()
		ep.type = DamagePipeline.DAMAGE_TYPE.SPLASH
		ep.is_blockable = false
		DamagePipeline.apply(e, ep)
		if e.has_method("apply_status"):
			e.apply_status(ScriptStatusEffects.Type.STUN, 0.5, 0.0, owner_entity)
		if e.has_method("get_battle_instance"):
			var b2: Node = e.get_battle_instance()
			if b2 != null and is_instance_valid(b2) and b2.has_method("register_attacker"):
				b2.register_attacker(e, owner_entity)


## 手动放箭/投矛出射点（射手胸口，与 AI 解算路径同源）
func get_muzzle_pos(entity: Node) -> Vector2:
	return _body_pos(entity) + Vector2(0, -70)


## 实体身体位置（Collider 世界坐标，缺省回落 global + 典型偏移）
func _body_pos(entity: Node) -> Vector2:
	var collider: Node = entity.get_node_or_null("Collider")
	if collider != null and collider is Node2D:
		return (collider as Node2D).global_position
	return entity.global_position + Vector2(8.5, 130)


## 发射箭矢：从射手胸口**抛物线**发射（SWL Arrow.launchY/AimAngle 弹道）。
## 固定重力 G，水平分速按距离解算，竖直初速度解抛物线过目标点——
## 近距离平射、远距自动高弧越顶（友军前排不挡箭），这是弓手能站后排
## 远程压制的物理基础（直线弹道会把箭全打在自己前排背上）。
func fire_arrow(target: Node) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return
	var scene: PackedScene = _mount.ARROW_SCENE
	if scene == null:
		push_warning("[WeaponMount] 箭矢场景加载失败: %s" % _mount.ARROW_SCENE_PATH)
		return
	# 射手胸口（Collider 上部；get_muzzle_pos 与手动放箭路径同源）与目标身体中心
	var from: Vector2 = get_muzzle_pos(owner_entity)
	var aim_point: Vector2 = _body_pos(target)
	# 抛物线解算（SWL AimAngle 语义）+ 移动目标预判迭代 → ArrowBallistics
	var target_vel: Vector2 = (target as CharacterBody2D).velocity if target is CharacterBody2D else Vector2.ZERO
	var solution: Dictionary = ArrowBallistics.solve(from, aim_point, target_vel, _mount.ARROW_VX, _mount.ARROW_LEAD_FACTOR, _mount.ARROW_GRAVITY)
	var vel: Vector2 = solution["vel"]
	var t: float = solution["t"]
	aim_point = solution["aim_point"]
	# SWL AimAngle 散布（currentShotBodyRandomness/NextGaussian）：出弓方向加高斯扰动，
	# σ 取兵种档案 aim_scatter（rad）× RWR sustained_fire 热度放大（连射越打越散）
	# × AI 附身技能档位乘数（SWL Personality.UserControlSkill：LIMITED 更散、PRO 更准）——
	# 箭雨自然散开，不再人人弹道全同
	var profile: Dictionary = ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type))
	var scatter: float = float(profile.get("aim_scatter", 0.0)) \
			* (1.0 + _mount._sustained_fire_heat) \
			* float(ScriptBehaviorProfiles.SKILL_AIM_SCATTER_MULT.get(
					int(profile.get("user_control_skill", 1)), 1.0))
	if scatter > 0.0:
		vel = vel.rotated(ArrowBallistics.next_gaussian(0.0, scatter, -2.0 * scatter, 2.0 * scatter))
	_mount._sustained_fire_heat = minf(_mount._sustained_fire_heat + _mount.SUSTAINED_FIRE_GROW, _mount.SUSTAINED_FIRE_HEAT_MAX)
	var arrow: Node2D = scene.instantiate()
	var parent: Node = owner_entity.get_parent()
	if parent == null:
		parent = _mount.get_tree().current_scene
	parent.add_child(arrow)
	arrow.global_position = from
	# SWL drawPower：拉弓满弓比例（BOW_FIRE_DELAY 计时结束 = 满弓 1.0）；
	# 传解算飞行时间 t + 瞄准点地面线（Collider 中心下方约半个身位≈地面）——
	# 箭越过目标后落在目标脚下地面（miss 插进敌阵），不再"低于出射点 500px"插地（9c）
	if arrow.has_method("setup"):
		arrow.call("setup", vel, _mount.effective_damage(), owner_entity, target, 1.0, _mount.ARROW_GRAVITY, t, aim_point.y + 65.0)
	# MissingArrowsTolerance 估计口径（11d）：在飞箭矢按满伤害登记到目标头上，
	# 弓手出手前据此避免对将死目标浪费箭（箭矢终态扣减，见 arrow_projectile）
	if target != null and is_instance_valid(target) and "incoming_arrow_damage" in target:
		target.incoming_arrow_damage += _mount.effective_damage()
	# 箭矢威胁标记（SWL SpeartonAi.IsAnyArrowThreat 感知源）：出弓瞬间通知目标，
	# 举盾兵种（档案 arrow_threat_block）在威胁窗口内举盾
	if target != null and is_instance_valid(target) and "arrow_threat_time" in target:
		target.arrow_threat_time = Time.get_ticks_msec() / 1000.0
