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
	var s := _mount._sim()
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


## 法术结算（SWL Magikill.CastStun 施法前摇到点）：对目标结算 SPELL 伤害——
## 格挡对法术无效（is_blockable=false，原版盾挡箭不挡魔法）。
## **命中点爆炸 AOE（放倒一片）**：对齐 dump Magikill.CastStun/StunOpponents/
## unitsToDamage/STUN_RANGE 真值——命中点半径内敌人同时受击 + 击晕（2026-09-01 反馈 9e），
## 半径挂档案 spell_aoe_radius（STAFF 90），并触发 MAGIC_BLAST 爆炸粒子。
func cast_magic(target: Node) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or target == null or not is_instance_valid(target):
		return
	var health: Node = _mount._get_health(target)
	if health == null or health.is_dead():
		return
	var p := DamagePipeline.Params.new(_mount.damage, owner_entity)
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
		target.apply_hit_reaction(p.direction, dealt * _mount.KNOCKBACK_PER_DAMAGE)
	# 命中点爆炸 AOE（放倒一片）+ 爆炸粒子
	var aoe_radius: float = float(
			ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("spell_aoe_radius", 0.0))
	if aoe_radius > 0.0:
		_apply_spell_blast(owner_entity, target, aoe_radius)
	if owner_entity.get_tree() != null:
		FxPool.spawn_burst(owner_entity.get_tree(), FxLibrary.MAGIC_BLAST,
				_body_pos(target) + Vector2(0, -30))


## 法术爆炸 AOE 结算（SWL StunOpponents 直译）：命中点 radius 内其他敌人
## 受 50% SPELL 伤害 + 同步击晕——"放倒一片"的核心；主目标已在 cast_magic 全额结算。
func _apply_spell_blast(owner_entity: CharacterBody2D, center: Node, radius: float) -> void:
	var faction: int = owner_entity.get_faction() if owner_entity.has_method("get_faction") else 0
	if faction == 0 or not owner_entity.has_method("get_battle_instance"):
		return
	var battle: Node = owner_entity.get_battle_instance()
	if battle == null or not is_instance_valid(battle) or not battle.has_method("get_enemies_of"):
		return
	var center_pos: Vector2 = (center as Node2D).global_position
	for e in battle.get_enemies_of(faction):
		if e == null or not is_instance_valid(e) or e == center:
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if not (e is Node2D):
			continue
		if (e as Node2D).global_position.distance_to(center_pos) > radius:
			continue
		var ep := DamagePipeline.Params.new(_mount.damage * 0.5, owner_entity)
		ep.direction = ((e as Node2D).global_position - center_pos).normalized()
		ep.type = DamagePipeline.DAMAGE_TYPE.SPLASH
		ep.is_blockable = false
		DamagePipeline.apply(e, ep)
		if e.has_method("apply_status"):
			e.apply_status(ScriptStatusEffects.Type.STUN, 0.5, 0.0, owner_entity)
		if e.has_method("get_battle_instance"):
			var b2: Node = e.get_battle_instance()
			if b2 != null and is_instance_valid(b2) and b2.has_method("register_attacker"):
				b2.register_attacker(e, owner_entity)


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
	# 射手胸口（Collider 上部）与目标身体中心（Collider 位置）
	var from: Vector2 = _body_pos(owner_entity) + Vector2(0, -70)
	var aim_point: Vector2 = _body_pos(target)
	# 抛物线解算（SWL AimAngle 语义）+ 移动目标预判迭代 → ArrowBallistics
	var target_vel: Vector2 = (target as CharacterBody2D).velocity if target is CharacterBody2D else Vector2.ZERO
	var solution: Dictionary = ArrowBallistics.solve(from, aim_point, target_vel, _mount.ARROW_VX, _mount.ARROW_LEAD_FACTOR, _mount.ARROW_GRAVITY)
	var vel: Vector2 = solution["vel"]
	var t: float = solution["t"]
	aim_point = solution["aim_point"]
	# SWL AimAngle 散布（currentShotBodyRandomness/NextGaussian）：出弓方向加高斯扰动，
	# σ 取兵种档案 aim_scatter（rad）× RWR sustained_fire 热度放大（连射越打越散）——
	# 箭雨自然散开，不再人人弹道全同
	var scatter: float = float(ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("aim_scatter", 0.0)) \
			* (1.0 + _mount._sustained_fire_heat)
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
		arrow.call("setup", vel, _mount.damage, owner_entity, target, 1.0, _mount.ARROW_GRAVITY, t, aim_point.y + 65.0)
	# MissingArrowsTolerance 估计口径（11d）：在飞箭矢按满伤害登记到目标头上，
	# 弓手出手前据此避免对将死目标浪费箭（箭矢终态扣减，见 arrow_projectile）
	if target != null and is_instance_valid(target) and "incoming_arrow_damage" in target:
		target.incoming_arrow_damage += _mount.damage
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
