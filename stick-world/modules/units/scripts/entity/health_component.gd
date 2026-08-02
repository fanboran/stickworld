class_name HealthComponent
extends Node
## 生命与士气组件 -- 挂在 StickmanEntity 下，管理 HP / 士气。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1（HealthComponent）。
## P0 阶段数值为占位值（数值层待原型后填，见 §16）。
##
## 职责：
##   - 维护 hp / max_hp / morale / max_morale
##   - take_damage() 扣血并降低士气
##   - 提供 is_dead() / is_routed() 查询（溃逃由 AI 行为判断）
##   - 发射 died / damaged / morale_changed 信号供外部响应

# ─────────────────────────────── 信号 ────────────────────────────────
@warning_ignore("unused_signal") signal died
@warning_ignore("unused_signal") signal damaged(amount: float, source: Node)
@warning_ignore("unused_signal") signal healed(amount: float)
@warning_ignore("unused_signal") signal morale_changed(old_val: float, new_val: float)

# ─────────────────────────────── @export（P0 占位数值）────────────────────────────────
## 最大 HP
@export var max_hp: float = 100.0
## 最大士气
@export var max_morale: float = 100.0
## 溃逃士气阈值（低于此值视为溃逃）
@export var rout_threshold: float = 20.0
## 受伤时士气下降系数（每点伤害扣多少士气）
@export var morale_damage_ratio: float = 0.6

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前 HP
var hp: float = 0.0
## 当前士气
var morale: float = 0.0


func _ready() -> void:
	hp = max_hp
	morale = max_morale


# ─────────────────────────────── 公共 API ────────────────────────────────

## 受到伤害。source 为造成伤害的实体（可能为 null）。
func take_damage(amount: float, source: Node = null) -> void:
	if is_dead():
		return
	amount = maxf(0.0, amount)
	hp = maxf(0.0, hp - amount)
	# 士气随伤害下降
	var old_morale: float = morale
	morale = maxf(0.0, morale - amount * morale_damage_ratio)
	damaged.emit(amount, source)
	if old_morale != morale:
		morale_changed.emit(old_morale, morale)
	if hp <= 0.0:
		died.emit()


## 恢复 HP（不超过上限）
func heal(amount: float) -> void:
	if is_dead():
		return
	amount = maxf(0.0, amount)
	hp = minf(max_hp, hp + amount)
	healed.emit(amount)


## 恢复士气（不超过上限）
func restore_morale(amount: float) -> void:
	amount = maxf(0.0, amount)
	var old_morale: float = morale
	morale = minf(max_morale, morale + amount)
	if old_morale != morale:
		morale_changed.emit(old_morale, morale)


## 设置士气（受情绪标签影响时调用）
func set_morale(value: float) -> void:
	value = clampf(value, 0.0, max_morale)
	var old_morale: float = morale
	if old_morale != value:
		morale = value
		morale_changed.emit(old_morale, value)


## 是否已死亡
func is_dead() -> bool:
	return hp <= 0.0


## 是否溃逃（士气低于阈值且未死）
func is_routed() -> bool:
	return not is_dead() and morale <= rout_threshold


## HP 比例 [0,1]
func get_hp_ratio() -> float:
	if max_hp <= 0.0:
		return 0.0
	return hp / max_hp


## 士气比例 [0,1]
func get_morale_ratio() -> float:
	if max_morale <= 0.0:
		return 0.0
	return morale / max_morale
