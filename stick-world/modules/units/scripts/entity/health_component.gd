class_name HealthComponent
extends Node
## 生命组件 -- 挂在 StickmanEntity 下，管理 HP。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §7.1（HealthComponent）。
## P0 阶段数值为占位值（数值层待原型后填，见 §16）。
##
## 职责：
##   - 维护 hp / max_hp
##   - take_damage() 扣血
##   - 提供 is_dead() 查询
##   - 发射 died / damaged / healed 信号供外部响应

# ─────────────────────────────── 信号 ────────────────────────────────
@warning_ignore("unused_signal") signal died
@warning_ignore("unused_signal") signal damaged(amount: float, source: Node)
@warning_ignore("unused_signal") signal healed(amount: float)

# ─────────────────────────────── @export（P0 占位数值）────────────────────────────────
## 最大 HP
@export var max_hp: float = 100.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前 HP
var hp: float = 0.0
## 死亡原因：最后一击是否爆头（原版 Kill(isHeadShot) 参数——爆头致死播
## Death-Headshot 专属死亡动画）。由 DamagePipeline 在爆头致死时置位。
var died_from_headshot: bool = false


func _ready() -> void:
	hp = max_hp


# ─────────────────────────────── 公共 API ────────────────────────────────

## 受到伤害。source 为造成伤害的实体（可能为 null）。
func take_damage(amount: float, source: Node = null) -> void:
	if is_dead():
		return
	amount = maxf(0.0, amount)
	hp = maxf(0.0, hp - amount)
	damaged.emit(amount, source)
	if hp <= 0.0:
		died.emit()


## 恢复 HP（不超过上限）
func heal(amount: float) -> void:
	if is_dead():
		return
	amount = maxf(0.0, amount)
	hp = minf(max_hp, hp + amount)
	healed.emit(amount)


## 是否已死亡
func is_dead() -> bool:
	return hp <= 0.0


## HP 比例 [0,1]
func get_hp_ratio() -> float:
	if max_hp <= 0.0:
		return 0.0
	return hp / max_hp
