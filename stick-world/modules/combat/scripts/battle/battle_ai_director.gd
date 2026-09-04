class_name BattleAIDirector
extends RefCounted
## 战场导演 -- 周期性给单位打"情绪标签"，实现小兵灵动性。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.4（小兵步枪式灵动性 - 第二层）。
## 每 2~5s 给每个单位打一个情绪标签，影响其 WeaponMount 的命中/冷却。
##
## 情绪概率受：士气、伤亡比影响（P0 简化版，指挥官能力/文化传统留待后续）。
##
## 情绪标签（本模块本地枚举，数值与 WeaponMount.Mood 契约一致，避免跨模块引用内部类）：
##   STEADY   - 稳定（默认）
##   HESITANT - 犹豫（命中率-30%、移动减速）
##   EXCITED  - 亢奋（命中率+10%、冷却缩短）
##   PANICKED - 恐慌（命中率-50%、优先找掩体/溃逃）


# ─────────────────────────────── 常量 ────────────────────────────────
## 情绪枚举（顺序/取值与 units/weapon_mount.gd 的 Mood 保持一致）
enum Mood {
	STEADY,
	HESITANT,
	EXCITED,
	PANICKED,
}
## 情绪刷新最小/最大间隔（秒）
const TICK_MIN: float = 2.0
const TICK_MAX: float = 5.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 关联的战斗实例（BattleInstance）——weakref 弱引用持有（架构债 P0-8）。
## 本类 extends RefCounted，生命周期不与 Node 绑定：BattleInstance 被
## queue_free 后强引用会悬垂（非 null 的 freed instance），访问即报错。
## 一律经 _get_battle() 取实例，禁止直接读本字段。
var _battle_ref: WeakRef = null
## 距下次刷新的倒计时
var _timer: float = 3.0


## 关联战斗实例
func setup(battle: Node) -> void:
	_battle_ref = weakref(battle)
	_reset_interval()


## 取关联的战斗实例；未关联或已被释放时返回 null（唯一合法访问路径）。
func _get_battle() -> Node:
	return _battle_ref.get_ref() if _battle_ref != null else null


## 每帧推进（由 BattleInstance._physics_process 调用）
func tick(delta: float) -> void:
	if _get_battle() == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		assign_moods()
		_reset_interval()


## 给所有参战单位打情绪标签
func assign_moods() -> void:
	var battle: Node = _get_battle()
	if battle == null or not battle.has_method("get_all_units"):
		return
	for unit in battle.get_all_units():
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
			return Mood.PANICKED
		return Mood.HESITANT
	# 士气较低 -> 可能犹豫
	if morale_ratio < 0.5:
		if randf() < 0.4:
			return Mood.HESITANT
	# 士气高昂 -> 偶尔亢奋
	if morale_ratio > 0.75 and randf() < 0.15:
		return Mood.EXCITED
	return Mood.STEADY


func _reset_interval() -> void:
	_timer = randf_range(TICK_MIN, TICK_MAX)
