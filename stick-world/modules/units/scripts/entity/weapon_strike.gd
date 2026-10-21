extends RefCounted
## 命中帧结算助手 —— 从 weapon_mount.gd 拆出的攻击结算子域（无自持状态）。
##
## 职责（Saga MeleeAttackSystem.Strike 语义）：
## - try_strike_frame / sim_strike_now：命中帧结算触发（旧链动画事件/轮询 →
##   do_strike；sim 链 BattleSim crossing → sim_strike_now；共用结算链）
## - sim_fire_now：sim 模式远程到点回调（弓放箭 / 杖施法分派）
## - do_strike：结算本体（二次距离确认 + 剑光弧 + 命中/暴击掷骰 + AOE 挥击
##   多目标 + 溅射系数 + DamagePipeline + 攻击者登记 + hitstop）
## - has_reached_hit_frame / resolve_hit_event_time：命中帧到达判定
##   （Hit 事件真值优先，无事件回退进度比例；billboard 链 .tres 元数据直读）
## - collect_strike_targets / _owner_facing：AOE 扇形目标收集
## - can_cancel_attack_anim：动画可打断判定（冷却门禁的提前出手窗口）
## - resolve_hit_seconds：sim 模式命中帧绝对秒
##
## 纪律：挥砍状态（_pending_strike_target/_pending_strike_owner/_strike_fired/
## _pending_strike_elapsed/_cancel_window_latched/_hit_event_time/_hit_time_resolved，
## 被 can_attack 门禁与 _play_swing 变体重置消费）全部留在宿主 WeaponMount，
## 经 _mount 动态回引读写；宿主保留 sim_strike_now/sim_fire_now facade
## （BattleSim 直调，签名不可变）。

## 命中帧兜底比例：只在动画**没有** Hit 事件数据时使用（程序化动画/测试桩）。
## 有事件数据时一律用事件真值——解包数据里各武器命中点差异很大
## （剑 75%、矛 52%、弓 27%、镐 67%、杖 60%），写死 0.45 是拍脑袋。
const STRIKE_FRAME_RATIO_FALLBACK := 0.45
## 攻击动画起播宽限（s）：perform_attack 与动画真正起播之间有一两帧延迟
## （travel → AnimationTree 下一帧才切状态）。等待期间不结算，否则命中会退化成
## "发起瞬间就结算"（等于白做命中帧对齐）。宽限过后仍未起播（无 rig / 无动画）
## 立即结算，保证 headless 与无动画场景不卡住。
const STRIKE_ANIM_GRACE := 0.3

## 目标查找器（AOE 挥击扇形搜索）；显式 preload 防 headless class_name 未注册
## （TargetFinder 为 tactics 对外公共类型，tactics/api.gd 契约出口）
const ScriptTargetFinder := preload("res://modules/tactics/api.gd").Finder

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## 动画可打断判定：本次攻击已挥过命中帧，且当前动画播放位置越过了
## 可打断点 = hit_time + cancel_fraction ×（动画时长 − hit_time）。
## cancel_fraction <= 0 = 关闭打断（等完整冷却）；无事件数据 / 未命中 /
## 动画已切走时同样不打断（保守走完整冷却）。
func can_cancel_attack_anim() -> bool:
	if not _mount._strike_fired or _mount.animation_cancel_fraction <= 0.0:
		return false
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return false
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_time") \
			or not rig.has_method("get_anim_length"):
		return false
	resolve_hit_event_time()
	if _mount._hit_event_time < 0.0:
		return false
	var t: float = rig.get_anim_time(_mount._attack_anim_name())
	if t < 0.0:
		return false
	var anim_len: float = rig.get_anim_length(_mount._attack_anim_name())
	var cancel_point: float = _mount._hit_event_time \
			+ _mount.animation_cancel_fraction * maxf(0.0, anim_len - _mount._hit_event_time)
	if t >= cancel_point:
		_mount._cancel_window_latched = true
		return true
	return false


## 命中帧结算（Saga MeleeAttackSystem.Strike）：
## 攻击动画播到 **Hit 事件时间** 时结算一次；无事件数据时回退到进度比例。
## 触发源有两个（都经 _strike_fired 保证只结算一次）：
##   ① rig.animation_event 的 "Hit" 事件（有事件数据时的主路径）
##   ② _physics_process 轮询（兜底：无事件数据 / 事件信号尚未接上）
func try_strike_frame() -> void:
	if _mount._strike_fired or _mount._pending_strike_target == null:
		return
	if not is_instance_valid(_mount._pending_strike_target):
		_mount._pending_strike_target = null
		return
	if not has_reached_hit_frame():
		return
	_mount._strike_fired = true
	do_strike()


## sim 模式命中帧到点回调（BattleSim._tick_weapon crossing 触发；sim 为时序权威）。
## 结算链与旧路径共用 do_strike()（AOE/情绪/hitstop/伤害管线零重复）。
func sim_strike_now() -> void:
	if _mount._strike_fired or _mount._pending_strike_target == null:
		return
	_mount._strike_fired = true
	do_strike()


## sim 模式远程到点回调（弓放箭 / 杖施法；延迟计时归 BattleSim）。
func sim_fire_now() -> void:
	if _mount._pending_ranged_target == null:
		return
	var target: Node = _mount._pending_ranged_target
	_mount._pending_ranged_target = null
	if not is_instance_valid(target):
		return
	if _mount.weapon_type == _mount.WeaponType.BOW:
		_mount._ranged.fire_arrow(target)
	else:
		_mount._ranged.cast_magic(target)


## 命中帧结算本体（旧 _try_strike_frame 的结算段；触发源：旧链动画到点 /
## sim crossing）。Saga MeleeAttackSystem.Strike。
func do_strike() -> void:
	var target: Node = _mount._pending_strike_target
	var owner_entity: Node = _mount._pending_strike_owner
	_mount._pending_strike_target = null
	# 空挥（perform_swing 无登记目标）：纯动作，命中帧无结算
	if target == null or not is_instance_valid(target):
		return
	# 挥到命中帧时二次确认距离（目标可能跑出射程：Saga AttackWhileStanding 同语义）
	if owner_entity == null or not is_instance_valid(owner_entity):
		return
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > _mount.attack_range * 1.25:
		return
	# 剑光弧（Demo 打磨：命中帧朝目标方向斩击弧光；近战才显——远程有弹道）
	var wt: int = int(_mount.weapon_type) if "weapon_type" in _mount else 0
	if wt != _mount.WeaponType.BOW:
		var ang: float = (target.global_position - owner_entity.global_position).angle()
		FxLibrary.spawn_slash_arc(owner_entity.get_tree(), owner_entity.global_position + Vector2(0, -30), ang, wt == _mount.WeaponType.SWORD)
	# 命中掷骰（未中=挥空）——单位种子 RNG（可注入可复现，P4 回放前置）
	if _mount._roll_dice() > _mount.base_hit_chance:
		return
	# 暴击掷骰（原版 isCrit；暴击附带自伤代价 critBonusDamageInflictedToSelf）
	var is_crit: bool = _mount._roll_dice() < _mount.crit_chance
	# ── AOE 挥击：身前扇形内按 number_of_units_that_can_hit 结算多个目标 ──
	var victims: Array = collect_strike_targets(owner_entity, target)
	for i in victims.size():
		var victim: Node = victims[i]
		var p := DamagePipeline.Params.new(_mount.effective_damage(), owner_entity)
		p.direction = (victim.global_position - owner_entity.global_position).normalized()
		p.type = DamagePipeline.DAMAGE_TYPE.MELEE
		p.knockback = _mount.damage * _mount.KNOCKBACK_PER_DAMAGE
		p.is_crit = is_crit
		p.crit_damage_multiplier = _mount.crit_damage_multiplier
		p.crit_self_damage = _mount.crit_bonus_damage_inflicted_to_self
		p.head_shot_bonus_damage = _mount.head_shot_bonus_damage
		# 超出"能打中人数"的部分按溅射系数结算（NumberOfUnitsThatCanHitWithSplash）；
		# 附身挥击的额外目标走原版附身溅射系数（USER_CONTROLLED_SPLASH_MODIFIER）
		if i >= _mount.number_of_units_that_can_hit:
			p.amount *= _mount.splash_modifier
			p.type = DamagePipeline.DAMAGE_TYPE.SPLASH
			p.is_blockable = false
			if owner_entity.has_method("is_possessed") and owner_entity.is_possessed():
				p.amount *= _mount.USER_CONTROLLED_SPLASH_MODIFIER / maxf(_mount.splash_modifier, 0.01)
		DamagePipeline.apply(victim, p)
		if owner_entity.has_method("get_battle_instance"):
			var battle: Node = owner_entity.get_battle_instance()
			if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
				battle.register_attacker(victim, owner_entity)
	_mount._hitstop()


## 是否已越过命中帧。
## 有 Hit 事件 → 比较动画播放的**绝对秒**与事件时间；
## 无事件 → 回退到进度比例（0~1）与 STRIKE_FRAME_RATIO_FALLBACK 比较。
func has_reached_hit_frame() -> bool:
	resolve_hit_event_time()
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return true
	var rig: Node = owner_entity.get("rig")
	if rig == null:
		return true
	var anim_name: String = _mount._attack_anim_name()
	if _mount._hit_event_time >= 0.0 and rig.has_method("get_anim_time"):
		var t: float = rig.get_anim_time(anim_name)
		if t < 0.0:
			# 动画尚未起播 / 已播完切走：宽限期内继续等，超时才结算
			return _mount._pending_strike_elapsed >= STRIKE_ANIM_GRACE
		return t >= _mount._hit_event_time
	# 无事件数据：回退到进度比例（旧行为，立即结算语义不变）
	if rig.has_method("get_anim_progress"):
		return rig.get_anim_progress(anim_name) >= STRIKE_FRAME_RATIO_FALLBACK
	return true


## AOE 挥击目标列表：主目标 + 扇形内最近的 N-1 个敌人（NumberOfUnitsThatCanHit），
## 再加 number_of_units_that_can_hit_with_splash 个溅射目标。
## 返回数组按"先满伤、后溅射"排序，调用方按下标决定是否乘 splash_modifier。
func collect_strike_targets(owner_entity: Node, main_target: Node) -> Array:
	if owner_entity == null or main_target == null:
		return [main_target] if main_target != null else []
	# 附身溅射（SWL USER_CONTROLLED_SPLASH_HIT_LIMIT）：玩家附身挥击扇形
	# 额外多收 4 个溅射目标
	var possessed_bonus: int = _mount.USER_CONTROLLED_SPLASH_HIT_LIMIT \
			if owner_entity.has_method("is_possessed") and owner_entity.is_possessed() else 0
	var max_count: int = _mount.number_of_units_that_can_hit \
			+ _mount.number_of_units_that_can_hit_with_splash + possessed_bonus
	if max_count <= 1:
		return [main_target]
	var facing: Vector2 = _owner_facing(owner_entity, main_target)
	var found: Array = ScriptTargetFinder.find_targets_in_arc(owner_entity, {
		"range": _mount.attack_range * 1.25,
		"half_angle": _mount.strike_arc_half_angle,
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
func resolve_hit_event_time() -> void:
	if _mount._hit_time_resolved:
		return
	_mount._hit_time_resolved = true
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return
	var anim_name: String = _mount._attack_anim_name()
	var rig: Node = owner_entity.get("rig")
	if rig != null and rig.has_method("get_anim_event_time"):
		_mount._hit_event_time = rig.get_anim_event_time(anim_name, "Hit")
		return
	# billboard 链（rig==null）：无 rig 帧表解析——.tres 元数据直读（镜像通道
	# 语义补全 #3），命中时序与 2D 富管线同一真相源，不再退化为立即结算
	_mount._hit_event_time = _mount.Anims.rigless_anim_event_time(anim_name, "Hit")


## sim 模式命中帧绝对秒（秒）：Hit 事件真值优先；无事件数据时按动画时长 ×
## fallback 比例换算；连动画时长都拿不到（测试桩无 rig）返回 0——
## 对齐旧链「无动画数据立即结算」语义。
func resolve_hit_seconds() -> float:
	resolve_hit_event_time()
	if _mount._hit_event_time >= 0.0:
		return _mount._hit_event_time
	var anim_name: String = _mount._attack_anim_name()
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity != null and "rig" in owner_entity:
		var rig: Node = owner_entity.get("rig")
		if rig != null and rig.has_method("get_anim_length"):
			var anim_len: float = rig.get_anim_length(anim_name)
			if anim_len > 0.0:
				return anim_len * STRIKE_FRAME_RATIO_FALLBACK
	# billboard 链（rig==null）：无 rig 时长回退走 .tres 直读
	var rigless_len: float = _mount.Anims.rigless_anim_length(anim_name)
	if rigless_len > 0.0:
		return rigless_len * STRIKE_FRAME_RATIO_FALLBACK
	return 0.0
