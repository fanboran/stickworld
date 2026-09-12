class_name StatusEffects
extends Node
## 状态效果组件（SWL ApplyBurn/ApplySlow/ApplyFreeze + legend 81 个 Unit System 的
## 最小集直译，2026-08-31 全量直译批次）。
##
## 效果类型：
##   BURN  灼烧 -- DOT（按 tick 扣血，不可叠加刷新时长）
##   POISON 中毒 -- DOT（中箭 poisonAmount 语义，可致死）
##   SLOW  减速 -- 移速 ×0.5
##   STUN  眩晕 -- AI/移动停滞（Magikill 法术击晕）
##   HEAL  治疗持续回复 -- HOT（P7 批次 7b：按 tick 回血，禁入 DamagePipeline）
##   SUPPRESSED 压制 -- 定时行为禁令（A6 · C9：被压制=短时锁死，惩罚来自模拟
##        因果非数值折扣；见 suppression_trigger/suppression_drain）
##
## 用法：
##   entity.get_status_effects().apply(StatusEffects.Type.BURN, 3.0, 4.0, source)
## 查询：has_stun() / has_suppressed() / get_speed_mult() / has_effect(Type)
## DOT 伤害走 DamagePipeline 单入口（type=SPELL、is_blockable=false——状态伤害不可格挡）。
## HEAL 正向结算不经 DamagePipeline（伤害单入口语义不破坏，spec §6.2.2.2a）。
##
## 压制（A6 · C9，CoH pinned-reaction-plan 直译——被压制的实质是定时禁令）：
##   - 触发源（最小可判定取舍）：受击达门槛——①射手主手弓（远程投射物代理）
##     命中 ≥ suppression_ranged_min_damage（箭矢压制）；②任意近战重击
##     ≥ suppression_melee_min_damage（量级对齐 HIT_BIG_DAMAGE_THRESHOLD）。
##     插地箭近失需投射物侧近失几何（arrow_projectile 不在 A6 文件面内），
##     预留 apply(SUPPRESSED, ...) 通用入口后续接入。状态 DOT tick 同信号不可辨
##     （take_damage 无 is_status 上下文），当前无 BURN/POISON 施加方（直译登记
##     未启用），若未来启用须在管线侧过滤或提高门槛（挂总账）。
##   - 总开关 suppression_enabled 默认关（零回归基线）；豁免：已溃逃/已死亡/
##     玩家附身/suppression_immune 兵种级豁免。同 type 刷新不叠加（既有 apply 语义
##     = 持续火力延长锁死）。
##   - 士气联动：SUPPRESSED 期间按 tick 经 lose_morale 流失（power=每 tick 点数，
##     只损士气不伤血），可推向溃逃——溃逃链优先级高于压制禁令（ai_controller）。
##   - 消费端：ai_controller 决策链（强制停滞，禁令不可被常规决策/号令执行打断）、
##     behavior_attack（在途行为兜底）、squad_phase_plan（真实压制查询）。

signal effect_applied(type: int, duration: float)

## 压制触发依赖兵种行为档案（同模块 ai/ 子目录；实体/ai_controller 同款
## get_profile 消费口径。跨模块 preload 才需 api.gd，同模块不涉审计约束）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

## 效果类型
enum Type { BURN, POISON, SLOW, STUN, HEAL, SUPPRESSED }

## DOT 结算间隔（s；legend DamageOverTimeSystem 的 tick 语义）
const TICK_INTERVAL: float = 0.5
## SLOW 移速倍率
const SLOW_SPEED_MULT: float = 0.5
## 效果表（type -> {until: 游戏秒, power: 每 tick 伤害, source, next_tick: 距下次 tick 秒}）
var _effects: Dictionary = {}
## 所属实体（_ready 时取父节点）
var _owner: Node = null


func _ready() -> void:
	_owner = get_parent()
	_connect_suppression_trigger()


## 压制触发接线（A6 · C9）：监听所属实体 HealthComponent.damaged。
## 独立成方法便于测试直调（不进树的 fixture 先注入 _owner 再接线）；
## 重复调用幂等（is_connected 防重连）。
func _connect_suppression_trigger() -> void:
	if _owner == null or not is_instance_valid(_owner):
		return
	var health: Node = _health_of()
	if health == null or not is_instance_valid(health):
		return
	if not health.has_signal("damaged"):
		return
	if not health.damaged.is_connected(_on_owner_damaged):
		health.damaged.connect(_on_owner_damaged)


## 所属实体生命组件（duck：get_health() API 优先，节点名回退）。
func _health_of() -> Node:
	if _owner == null or not is_instance_valid(_owner):
		return null
	if _owner.has_method("get_health"):
		var h: Node = _owner.get_health()
		if h != null and is_instance_valid(h):
			return h
	return _owner.get_node_or_null("HealthComponent")


## 施加/刷新效果（同 type 刷新时长与强度，不叠加层数——对齐原版语义）
func apply(type: int, duration: float, power: float = 0.0, source: Node = null) -> void:
	if duration <= 0.0:
		return
	_effects[type] = {
		"until": _now() + duration,
		"power": power,
		"source": source,
		"next_tick": TICK_INTERVAL,
	}
	effect_applied.emit(type, duration)


## 是否处于眩晕（AI/移动据此停滞）
func has_stun() -> bool:
	return _effects.has(Type.STUN) and _effects[Type.STUN]["until"] > _now()


## 是否被压制（A6 · C9：ai_controller 决策链/behavior_attack/squad_phase_plan 消费）
func has_suppressed() -> bool:
	return has_effect(Type.SUPPRESSED)


## 是否有某效果
func has_effect(type: int) -> bool:
	return _effects.has(type) and _effects[type]["until"] > _now()


## 列出当前激活效果（属性面板消费）：[{type, remain, power}]
func list_active() -> Array:
	var now: float = _now()
	var out: Array = []
	for key in _effects:
		var e: Dictionary = _effects[key]
		var remain: float = e["until"] - now
		if remain > 0.0:
			out.append({"type": key, "remain": remain, "power": e["power"]})
	return out


## 移速倍率（SLOW 生效时 0.5，否则 1.0）
func get_speed_mult() -> float:
	return SLOW_SPEED_MULT if has_effect(Type.SLOW) else 1.0


func _physics_process(delta: float) -> void:
	if _effects.is_empty() or _owner == null or not is_instance_valid(_owner):
		return
	var now: float = _now()
	var expired: Array = []
	for type in _effects.keys():
		var e: Dictionary = _effects[type]
		if e["until"] <= now:
			expired.append(type)
			continue
		# DOT 结算（BURN/POISON）
		if type in [Type.BURN, Type.POISON]:
			e["next_tick"] -= delta
			if e["next_tick"] <= 0.0:
				e["next_tick"] = TICK_INTERVAL
				_apply_dot(e)
		# HOT 结算（HEAL，P7 批次 7b）：tick 节奏复用 TICK_INTERVAL 不新增常量
		elif type == Type.HEAL:
			e["next_tick"] -= delta
			if e["next_tick"] <= 0.0:
				e["next_tick"] = TICK_INTERVAL
				_apply_hot(e)
		# 压制期士气流失（A6 · C9 士气联动）：tick 节奏同 DOT/HOT；
		# 被压制→士气持续流失（语义推断待实测校准），可推向溃逃
		elif type == Type.SUPPRESSED:
			e["next_tick"] -= delta
			if e["next_tick"] <= 0.0:
				e["next_tick"] = TICK_INTERVAL
				_apply_suppression_drain(e)
	for type in expired:
		_effects.erase(type)


## DOT 结算：走 DamagePipeline 单入口（SPELL 语义、不可格挡，对齐原版状态伤害）
func _apply_dot(e: Dictionary) -> void:
	if _owner == null or not _owner.has_method("get_health"):
		return
	var p := DamagePipeline.Params.new(float(e["power"]), e["source"])
	p.type = DamagePipeline.DAMAGE_TYPE.SPELL
	p.is_blockable = false
	p.is_status = true
	DamagePipeline.apply(_owner, p)


## HOT 结算（HEAL 正向回复，P7 批次 7b）：禁入 DamagePipeline（伤害单入口语义不破坏）。
## dump 无方法体真值，语义推断（待实测校准）；叠加语义 = apply 既有"刷新不叠加"。
## 防御：_owner 失效/已死跳过（防治疗已死单位产生复活数值）；power 钳正
## （负值经 heal() 会绕过伤害管线扣血）；上限钳制由 HealthComponent.heal 既有 minf max_hp 保障。
func _apply_hot(e: Dictionary) -> void:
	if _owner == null or not is_instance_valid(_owner) or not _owner.has_method("get_health"):
		return
	if _owner.has_method("is_dead") and _owner.is_dead():
		return
	var hp: Node = _owner.get_health()
	if hp == null or not is_instance_valid(hp) or not hp.has_method("heal"):
		return
	hp.heal(maxf(0.0, float(e["power"])))


# ─────────────────────────────── 压制（A6 · C9 定时锁死）────────────────────────────────

## 受击触发（HealthComponent.damaged 消费）：达门槛 → apply SUPPRESSED。
## 开关/豁免/门槛全档案化（behavior_profiles，总开关默认关 = 零回归基线）。
func _on_owner_damaged(amount: float, source: Node) -> void:
	if _owner == null or not is_instance_valid(_owner):
		return
	var profile: Dictionary = _suppression_profile()
	if not bool(profile.get("suppression_enabled", false)):
		return
	if bool(profile.get("suppression_immune", false)):
		return  # 兵种级豁免（英雄/巨人类预留）
	if _owner.has_method("is_possessed") and _owner.is_possessed():
		return  # 玩家附身：行为禁令语义不作用于玩家操控
	if _owner.has_method("is_dead") and _owner.is_dead():
		return  # 已死者不压制（致死一击的受击反馈链不受影响）
	var health: Node = _health_of()
	if health != null and health.has_method("is_routed") and health.is_routed():
		return  # 豁免：已溃逃者禁令无意义（强制溃逃链优先于压制禁令）
	if not _qualifies_suppression_hit(amount, source, profile):
		return
	# power = 压制期每 tick 士气流失点数（suppression_drain 消费）；同 type 刷新不叠加
	apply(Type.SUPPRESSED, float(profile.get("suppression_duration", 4.5)),
			float(profile.get("suppression_morale_per_tick", 2.0)), source)


## 触发门槛判定（最小可判定取舍见类头注释）：远程命中达下限 / 近战重击达下限。
func _qualifies_suppression_hit(amount: float, source: Node, profile: Dictionary) -> bool:
	var dmg: float = maxf(0.0, amount)
	if dmg >= float(profile.get("suppression_melee_min_damage", 12.0)):
		return true
	# 远程投射物代理：射手主手为弓（当前唯一投射物武器；格挡残余/远距衰减低于
	# 下限不压制——"挡住的箭不压制"）。DOT tick 若未来由弓手施加且单 tick 低于
	# 下限，同样被此门槛挡住。
	if source != null and is_instance_valid(source) and source.has_method("get_weapon"):
		var w: Node = source.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w \
				and int(w.weapon_type) == ScriptBehaviorProfiles.BOW \
				and dmg >= float(profile.get("suppression_ranged_min_damage", 4.0)):
			return true
	return false


## 压制期士气流失（tick 结算）：只损士气不伤血（lose_morale 语义），不进伤害管线。
## 防御：_owner 失效/已死跳过；power 钳正。
func _apply_suppression_drain(e: Dictionary) -> void:
	if _owner == null or not is_instance_valid(_owner):
		return
	if _owner.has_method("is_dead") and _owner.is_dead():
		return
	var health: Node = _health_of()
	if health == null or not is_instance_valid(health) or not health.has_method("lose_morale"):
		return
	health.lose_morale(maxf(0.0, float(e["power"])))


## 兵种行为档案（压制键族）：按所属实体主手武器类型解析；
## 无武器/类型缺失回落空档案 = 全默认（开关关，零回归）。
func _suppression_profile() -> Dictionary:
	if _owner == null or not is_instance_valid(_owner) \
			or not _owner.has_method("get_weapon"):
		return {}
	var w: Node = _owner.get_weapon()
	if w == null or not is_instance_valid(w) or not ("weapon_type" in w):
		return {}
	return ScriptBehaviorProfiles.get_profile(int(w.weapon_type))


## 当前游戏秒（TimeManager 加速档不影响 tick 相对节奏）
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
