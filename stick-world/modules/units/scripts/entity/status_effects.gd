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
##
## 用法：
##   entity.get_status_effects().apply(StatusEffects.Type.BURN, 3.0, 4.0, source)
## 查询：has_stun() / get_speed_mult() / has_effect(Type)
## DOT 伤害走 DamagePipeline 单入口（type=SPELL、is_blockable=false——状态伤害不可格挡）。
## HEAL 正向结算不经 DamagePipeline（伤害单入口语义不破坏，spec §6.2.2.2a）。

signal effect_applied(type: int, duration: float)

## 效果类型
enum Type { BURN, POISON, SLOW, STUN, HEAL }

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


## 当前游戏秒（TimeManager 加速档不影响 tick 相对节奏）
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
