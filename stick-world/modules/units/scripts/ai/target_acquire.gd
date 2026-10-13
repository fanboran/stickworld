extends RefCounted
## 找目标系统——SWL Ai 锁定规则直译（裁决#31 重写：创始人点正「个体锁定规则
## 为什么这么混乱，就隔壁火柴人战争的锁定规则就可以了」）。
##
## SWL 真相（docs/技术/参考/SWL-单位行为完整翻译.md §6.4）：
##   - `Ai.target` + `UpdateTarget()`：当前目标 + 周期刷新；
##   - 距离度量 `AiDistance` + 仇恨半径 `AGRO_RANGE`：候选须在仇恨半径内；
##   - 前向过滤 `OnlyTargetsUnitsForward()` / `IsValidForForwardOnlyTarget`：
##     只打身前目标（防回头送）；
##   - 无滞回/无驻留/无分层——旧 SW3 系增量改进+滞回+驻留+分层机器已随本批拆除。
##
## 本作口径（创始人 2026-10-13「优先追击最近的敌人」）：
##   - 选举 = 前向半平面内最近存活敌；身前无敌回退全域（SWL 单位会转身使
##     半平面旋转，我方面向跟随目标——回退层兜住等价语义，防站立挨打死锁）；
##   - **无距离门**——最近敌直接追（裁决#31 首版保留射程×4 仇恨半径被集成
##     夹具实锤拦死跨距接战：两军对峙无伤亡；#21c 的回头问题由前向过滤兜住）；
##   - 目标死亡/失效 → 立即重选；
##   - 强制目标（打通态拦路者）最高优先；
##   - 守位者守卫：目标须在仇恨半径内（跨半场冲锋 = 留守失效）。
##
## 参数经兵种档案（behavior_profiles）注入。消费点：behavior_attack（每物理帧
## advance）。

## 目标选择器（tactics 对外公共类型；显式 preload 防 headless class_name 未注册）
const ScriptFinder := preload("res://modules/tactics/api.gd").Finder

# ─────────────────────── 常量（回退值，与 behavior_profiles.BASELINE 同值）────────────────────────────────
## 目标扫视轮询间隔（s）
const ACQUIRE_INTERVAL: float = 0.5
## 仇恨半径倍数（候选/当前目标距本单位不得超过 武器射程×此值——SWL AGRO_RANGE
## 的数值等价：够得着才追，半个战场外不锁）
const AGRO_MULT: float = 4.0

# ─────────────────────── 宿主注入 ────────────────────────
## 决策单位（StickmanEntity；读位置/武器/守位，全部 duck）
var entity: Node = null
## 所属战斗实例（候选枚举）
var battle: Node = null
## 兵种行为档案引用（宿主 enter 时注入；参数缺省回退上方常量）
var profile: Dictionary = {}

# ─────────────────────── 目标状态 ────────────────────────
## 当前目标（null = 无目标可打，调用方 finish）
var _target: Node = null
## 强制目标（打通态"打通"拦路者：params 注入；死亡/失效/超仇恨半径即清除回落）
var _forced_target: Node = null
## 下次选举倒计时（s）
var _acquire_timer: float = 0.0
## 目标已驻留时长（s；换靶清零——纯观测面保留）
var _dwell: float = 0.0


## 装配（宿主 enter 时调用；幂等——重入重绑宿主引用）
func setup(p_entity: Node, p_battle: Node, p_profile: Dictionary) -> void:
	entity = p_entity
	battle = p_battle
	profile = p_profile


## 强制目标注入（打通态：behavior_move 请求 → ai_controller → attack params）
func set_forced_target(t: Node) -> void:
	_forced_target = t


## 当前目标（behavior_attack 每帧同步到本地 _target 字段供下游消费）
func get_target() -> Node:
	return _target


## 当前目标驻留时长（s；测试/调试观测面）
func get_dwell() -> float:
	return _dwell


## 每物理帧推进：计时 → 目标失效即时重选，到期例行刷新。返回当前目标
## （null = 无目标可打）。
func advance(delta: float) -> Node:
	_acquire_timer -= delta
	_dwell += delta
	if _acquire_timer > 0.0 and _target_ok(_target):
		return _target
	_elect()
	return _target


## 当前目标是否超仇恨半径（观测面保留；裁决#31 起无距离门，恒 false——
## 守位者守卫仍用 _in_agro 判定）
func is_beyond_leash() -> bool:
	return false


# ─────────────────────── 选举（感知拍）────────────────────────────────

## 选举一拍（SWL UpdateTarget）：强制目标 → 前向最近 → 全域最近（都须在
## 仇恨半径内）。无滞回无驻留——最近者得。
func _elect() -> void:
	_acquire_timer = _p("acquire_interval", ACQUIRE_INTERVAL)
	# 1. 强制目标（打通态拦路者）：有效且未超仇恨半径 → 最高优先锁定
	var forced: Node = _valid_forced()
	if forced != null:
		_accept(forced)
		_post_guard()
		return
	# 2. 前向半平面最近存活敌（SWL OnlyTargetsUnitsForward 直译——只打身前
	#    目标防回头送；前向配对让接触沿正面自然分布）
	var best: Node = _find_best(true)
	# 3. 身前无敌（被抄后/残局）回退全域——防站立挨打死锁（SWL 单位会转身使
	#    半平面旋转，我方面向跟随目标——回退层兜住等价语义）。无距离门——
	#    最近敌直接追（创始人裁决#31）
	if best == null:
		best = _find_best(false)
	if best != null:
		_accept(best)
	_post_guard()


## 最近有效敌（前向过滤可配；候选须在仇恨半径内）
func _find_best(forward_only: bool) -> Node:
	return ScriptFinder.find_target(entity, {
		"battle": battle,
		"ignore_current_attackers": true,
		"prefer_large": _p("prefer_large", 0.0),
		"only_forward": forward_only,
	})


## 接受目标（换靶清零驻留时钟；同目标续驻留）
func _accept(t: Node) -> void:
	if t == _target:
		return
	_target = t
	_dwell = 0.0


## 目标当前是否有效（活着）
func _target_ok(t: Node) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	if t.has_method("is_dead") and t.is_dead():
		return false
	return true


## 距离是否在仇恨半径内（武器射程 × AGRO_MULT；无武器回退 100 旧口径）
func _in_agro(t: Node) -> bool:
	if t == null or not is_instance_valid(t) or entity == null or not is_instance_valid(entity):
		return false
	var dist: float = entity.global_position.distance_to(t.global_position)
	return dist <= _attack_range() * _p("agro_mult", AGRO_MULT)


## 攻击射程（duck 读武器；无武器回落 100 = 旧口径）
func _attack_range() -> float:
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_weapon"):
		return 100.0
	var w: Node = entity.get_weapon()
	if w != null and "attack_range" in w:
		return float(w.attack_range)
	return 100.0


## 强制目标有效性维护：有效 → 返回目标；死亡/失效/超仇恨半径 → 清除返回 null
func _valid_forced() -> Node:
	if _forced_target == null:
		return null
	if not _target_ok(_forced_target):
		_forced_target = null
		return null
	return _forced_target


## 守位者守卫（指挥官/阵地护卫）：目标超仇恨半径 → 放弃（不跨半场冲锋）
func _post_guard() -> void:
	if _target == null or entity == null or not is_instance_valid(entity):
		return
	if entity.has_method("holds_post") and entity.holds_post() \
			and not _in_agro(_target):
		_target = null


## 档案参数读取（缺省回退常量）
func _p(key: String, fallback: float) -> float:
	if profile == null or not profile.has(key):
		return fallback
	return float(profile[key])
