extends RefCounted
## 火柴人回血助手 —— 从 stickman_entity 拆出的生命恢复子域。
##
## 职责（两条互斥通道，接管单位只走前者）：
## - 接管缓慢回血（SWL Unit 真值 healthRegenPerSecondWhenUserControlled 口径：
##   玩家亲自下场自带恢复，鼓励亲自参战）
## - 脱战回血（9j）：脱离火线（距上次受击超窗）后 HP 缓慢恢复，最多回到
##   血上限的 25%（战损留痕）
##
## 结算共用口径：小数累积、凑满整数 HP 一口 heal——避免高频小数 heal 信号刷屏。
##
## 纪律：user_controlled / health_component / _last_hit_ms 全留宿主，经 _entity 回引
## 只读；本类自持的只有两个小数累积器（回血结算私有，无外部消费）。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null
## 接管回血小数累积器（凑满 1 HP 才结算）
var _user_control_regen_accum: float = 0.0
## 脱战回血小数累积器（与接管回血同款）
var _rest_regen_accum: float = 0.0


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 回血常量 ────────────────────────────────
## 接管回血速率（HP/s；SWL 字段名真值 healthRegenPerSecondWhenUserControlled，
## 数值无 dump 真值为语义推断，待实测校准）
const USER_CONTROL_REGEN_PER_SECOND: float = 0.5
## 脱战回血延迟（s）：距上次受击超过此秒数才开始回（9j；缺陷表口径"脱战 5s 后回"）
const OUT_OF_COMBAT_HP_REGEN_DELAY: float = 5.0
## 脱战回血速率（HP/s，整十口径；待实测校准）
const OUT_OF_COMBAT_HP_REGEN_RATE: float = 10.0
## 脱战回血上限（max_hp 比例）：最多回到血上限的 25%（战损留痕，9j 缺陷表口径）
const OUT_OF_COMBAT_HP_REGEN_CAP_RATIO: float = 0.25


## User Control 期间缓慢回血。满血/死亡不结算；每累积满 1 HP 调一次 HealthComponent.heal。
func tick_user_control_regen(delta: float) -> void:
	var health: Node = _entity.get_node_or_null("HealthComponent")
	if health == null or not is_instance_valid(health):
		return
	if health.is_dead() or health.hp >= health.max_hp:
		_user_control_regen_accum = 0.0
		return
	_user_control_regen_accum += delta * USER_CONTROL_REGEN_PER_SECOND
	if _user_control_regen_accum >= 1.0:
		var whole: int = int(_user_control_regen_accum)
		_user_control_regen_accum -= float(whole)
		health.heal(float(whole))


## 脱战回血（9j 最简版：数值先通，血条渐补表现不做）。接管单位不叠此通道
##（走 SWL 真值接管慢回）。
func tick_rest_hp_recovery(delta: float) -> void:
	var health: Node = _entity.health_component
	if _entity.user_controlled or health == null:
		return
	if health.is_dead() or health.hp >= health.max_hp:
		_rest_regen_accum = 0.0
		return
	var since_hit: float = (Time.get_ticks_msec() - _entity._last_hit_ms) / 1000.0
	if since_hit < OUT_OF_COMBAT_HP_REGEN_DELAY:
		_rest_regen_accum = 0.0
		return
	var cap: float = health.max_hp * OUT_OF_COMBAT_HP_REGEN_CAP_RATIO
	if health.hp >= cap:
		_rest_regen_accum = 0.0
		return
	_rest_regen_accum += delta * OUT_OF_COMBAT_HP_REGEN_RATE
	if _rest_regen_accum >= 1.0:
		var whole: int = mini(int(_rest_regen_accum), int(cap - health.hp))
		if whole > 0:
			_rest_regen_accum -= float(whole)
			health.heal(float(whole))
		else:
			_rest_regen_accum = 0.0  # 上限截断：尾差不足 1 HP，丢弃余量
