extends RefCounted
## 治疗施法助手 —— 从 weapon_mount.gd 拆出的治疗子域（P7 批次 7b：
## Meric 实体层 CastHeal/CanCastHeal/IsCastingHeal 直译；无自持状态）。
##
## 职责：can_cast_heal（冷却满 ∧ 非施法中）/ cast_heal（随机注入治疗动画 →
## 播放 → apply_status(HEAL) HOT 均分 → 刷新计时 → 发射 EventBus.heal_cast）/
## is_casting_heal。
##
## 纪律：治疗状态（_heal_anim_playing/_last_heal_time/_last_heal_effect_spawn/
## healing_animation；_heal_anim_playing 与 _last_heal_time 被 tests/unit/
## test_meric_heal.gd 经 Node 直写——状态留宿主，逻辑下沉）、动画结束清标志
## （宿主 _on_rig_animation_finished）与现实秒时钟（宿主 _now()）都留在宿主
## WeaponMount，本类经 _mount 动态回引读写。

## 状态效果（HEAL 的 TICK_INTERVAL 与 Type.HEAL 引用；显式 preload 防 headless
## class_name 未注册）
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")
## 兵种行为档案（heal_cooldown/heal_amount/heal_duration 按武器类型读取）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 动画名映射（pick_heal_anim 随机注入）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## CanCastHeal 直译：冷却满 ∧ 非施法中。dump 无方法体真值，语义推断（待实测校准）。
## 档案经宿主既有 ScriptBehaviorProfiles preload 读取；heal_cooldown=0 时恒真
## （BASELINE 默认）。
func can_cast_heal() -> bool:
	var profile: Dictionary = ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type))
	var cd: float = float(profile.get("heal_cooldown", 0.0))
	if cd <= 0.0:
		return not _mount._heal_anim_playing
	return (_mount._now() - _mount._last_heal_time >= cd) and not _mount._heal_anim_playing


## CastHeal 直译；签名差异声明：原版无参目标由宿主字段隐含，本项目显式传 target
## 保类型安全，语义等价。dump 无方法体真值，语义推断（待实测校准）。
## 流程：target 防御 → 随机注入 healing_animation → 播放 → apply_status(HEAL)
## → 刷新计时 → 发射 EventBus.heal_cast
func cast_heal(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("is_dead") and target.is_dead():
		return
	var profile: Dictionary = ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type))
	var heal_amount: float = float(profile.get("heal_amount", 0.0))
	var heal_duration: float = float(profile.get("heal_duration", 0.0))
	# 随机注入治疗动画名（dump healingAnimation 字段直译）
	_mount.healing_animation = Anims.pick_heal_anim()
	_mount._heal_anim_playing = true
	# 播放治疗动画（经宿主 rig，参照 _play_swing 消费链）
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity != null:
		var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
		if rig != null and rig.has_method("play"):
			rig.play(_mount.healing_animation)
	# HOT 均分：per_tick = heal_amount × TICK_INTERVAL / heal_duration（spec §6.2.2.4）
	if heal_amount > 0.0 and heal_duration > 0.0 \
			and target.has_method("apply_status"):
		var per_tick: float = heal_amount * ScriptStatusEffects.TICK_INTERVAL / heal_duration
		target.apply_status(ScriptStatusEffects.Type.HEAL, heal_duration, per_tick, _mount)
	# 刷新计时（dump lastHealTime/lastHealEffectSpawn 直译）
	_mount._last_heal_time = _mount._now()
	_mount._last_heal_effect_spawn = _mount._now()
	# 发射治疗施放信号（spec §5.4.3 可观测性）
	var eb: Node = _mount.get_node_or_null("/root/EventBus")
	if eb != null and eb.has_signal("heal_cast"):
		var battle_id: String = ""
		if owner_entity != null and owner_entity.has_method("get_battle_instance"):
			var bi: Node = owner_entity.get_battle_instance()
			if bi != null and bi.has_method("get_battle_id"):
				battle_id = bi.get_battle_id()
		var caster_id: int = owner_entity.get_instance_id() if owner_entity != null else 0
		var target_id: int = target.get_instance_id()
		eb.heal_cast.emit(battle_id, caster_id, target_id, _mount.healing_animation)


## IsCastingHeal 直译：返回施法标志位（比查询 rig 动画名更可测，unit 测试直接置位）。
func is_casting_heal() -> bool:
	return _mount._heal_anim_playing
