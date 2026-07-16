class_name BattleAIDirector
extends RefCounted
## 战场导演 -- 周期性给单位打"情绪标签"，实现小兵灵动性。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.4（小兵步枪式灵动性 - 第二层）。
## 每 2~5s 给每个单位打一个情绪标签，影响其 WeaponMount 的命中/冷却。
##
## 情绪概率受：士气、伤亡比影响（P0 简化版，指挥官能力/文化传统留待后续）。
##
## 情绪标签（WeaponMount.Mood）：
##   STEADY   - 稳定（默认）
##   HESITANT - 犹豫（命中率-30%、移动减速）
##   EXCITED  - 亢奋（命中率+10%、冷却缩短）
##   PANICKED - 恐慌（命中率-50%、优先找掩体/溃逃）

const ScriptWeaponMount := preload("res://modules/units/scripts/weapon_mount.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 情绪刷新最小/最大间隔（秒）
const TICK_MIN: float = 2.0
const TICK_MAX: float = 5.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 关联的战斗实例（BattleInstance）
var _battle: Node = null
## 距下次刷新的倒计时
var _timer: float = 3.0


## 关联战斗实例
func setup(battle: Node) -> void:
	_battle = battle
	_reset_interval()


## 每帧推进（由 BattleInstance._physics_process 调用）
func tick(delta: float) -> void:
	if _battle == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		assign_moods()
		_reset_interval()


## 给所有参战单位打情绪标签
func assign_moods() -> void:
	if _battle == null or not _battle.has_method("get_all_units"):
		return
	for unit in _battle.get_all_units():
		if not is_instance_valid(unit):
			continue
		if unit.has_method("is_dead") and unit.is_dead():
			continue
		if not unit.has_method("get_weapon"):
			continue
		var wm: Node = unit.get_weapon()
		if wm == null:
			continue
		wm.set_mood(_decide_mood(unit))


# ─────────────────────────────── 内部 ────────────────────────────────

## 根据单位士气决定情绪标签
func _decide_mood(unit: Node) -> int:
	var morale_ratio: float = 1.0
	if unit.has_method("get_health"):
		var health: Node = unit.get_health()
		if health != null and health.has_method("get_morale_ratio"):
			morale_ratio = health.get_morale_ratio()
	# 士气极低 -> 大概率恐慌
	if morale_ratio < 0.25:
		if randf() < 0.6:
			return ScriptWeaponMount.Mood.PANICKED
		return ScriptWeaponMount.Mood.HESITANT
	# 士气较低 -> 可能犹豫
	if morale_ratio < 0.5:
		if randf() < 0.4:
			return ScriptWeaponMount.Mood.HESITANT
	# 士气高昂 -> 偶尔亢奋
	if morale_ratio > 0.75 and randf() < 0.15:
		return ScriptWeaponMount.Mood.EXCITED
	return ScriptWeaponMount.Mood.STEADY


func _reset_interval() -> void:
	_timer = randf_range(TICK_MIN, TICK_MAX)
