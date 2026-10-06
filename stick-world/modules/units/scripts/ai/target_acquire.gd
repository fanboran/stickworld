extends RefCounted
## 找目标系统（SW3 FindTargetAiSystem 直译，确定性模拟核心蓝图 P1）。
##
## 从 behavior_attack 刷新段拆出的独立系统（单职责化，审计 §五：P1 拆分时机）。
## SW3 dump 签名实录（external/il2cppdumper out_saga；行为语义为直译推断）：
##   - ImproveTargetIncremental：每感知拍扫最优候选"增量改进"当前目标，
##     而非"锁定到失效才重扫"（旧 sticky pass）；
##   - RestoreBestTarget(..., FP hysteresis, ...)：换靶滞回——新目标须显著
##     更优（距离 < 当前 × target_switch_ratio）才换，消换靶振荡；
##   - NotBeenOnTargetForEnoughTime：目标驻留时长门槛——当前目标未驻留满
##     target_dwell_min 不做选举性换靶。设计靶心 = 号令粘性/决策承诺感
##     （02-战斗 一-A.5「最短保持期+事件触发换令」/ 二-A.4「选定目标决斗到死」）；
##   - 分层阈值 OutOfFireRangeTier / UnreachableTier：候选按 射程内(0) →
##     追击带内(1) → 超追击带(2) 分层，层提升立即换（质变），同层走滞回+
##     驻留（量变）——追丢的猎物让位给够得着的新敌，不等驻留时钟。
##
## 优先级序（高到低）：
##   强制目标（打通态拦路者，号令插叙）> 小队共享目标（排长集火，SW3
##   TargetPriority 含编队上下文的等价通道）> 自主寻敌（TargetFinder 公共核心）。
## 小队目标存在时不落到自主寻敌（保持旧语义：集火号令期间队员不自选）。
##
## 即时换靶（不受滞回/驻留约束）：当前目标死亡/失效/超追击带；新候选层更低；
## 强制目标有效。指挥官守卫（斩首规则）：自主接战目标必须在 leash 内。
##
## 参数经兵种档案（behavior_profiles）注入；本文件回退值与 BASELINE 同值。
## 消费点：behavior_attack（attack 行为每物理帧 advance）。

## 目标选择器（tactics 对外公共类型；显式 preload 防 headless class_name 未注册）
const ScriptFinder := preload("res://modules/tactics/api.gd").Finder

# ─────────────────────────────── 常量（回退值，与 behavior_profiles.BASELINE 同值）────────────────────────────────
## 目标扫视轮询间隔（s）
const ACQUIRE_INTERVAL: float = 0.5
## 换靶滞回比例（新目标距离 < 当前 × 此值才换；<=0 = 关滞回）
const TARGET_SWITCH_RATIO: float = 0.6
## 目标驻留时长门槛（s；<0.05 视为关——换靶只受滞回约束）
const TARGET_DWELL_MIN: float = 2.0
## 追击放弃倍数（目标超出射程 × 此值即"追丢"）
const LEASH_MULT: float = 4.0

# ─────────────────────────────── 分层阈值（SW3 Tier 语义）────────────────────────────────
## 候选分层：数值越低越优；LOST 表示当前目标已死亡/失效（立即重选）。
enum TargetTier {
	IN_FIRE_RANGE = 0,     ## 射程内（可立即出手）
	OUT_OF_FIRE_RANGE = 1, ## 射程外但追击带内（够得着）
	UNREACHABLE = 2,       ## 超追击带（追丢）
	LOST = 3,              ## 死亡/失效（不构成保留理由）
}

# ─────────────────────────────── 宿主注入 ────────────────────────────────
## 决策单位（StickmanEntity；读位置/武器/指挥官位，全部 duck）
var entity: Node = null
## 所属战斗实例（候选枚举）
var battle: Node = null
## 兵种行为档案引用（宿主 enter 时注入；参数缺省回退上方常量）
var profile: Dictionary = {}
## 小队共享目标提供者 () -> Node（排长集火号令；无小队返回 null。
## behavior_attack._get_squad_target 的 Callable，选举拍才调用）
var squad_target_fn: Callable = Callable()

# ─────────────────────────────── 目标状态 ────────────────────────────────
## 当前目标（null = 无目标可打，调用方 finish）
var _target: Node = null
## 强制目标（打通态"打通"拦路者：params 注入；死亡/失效/超追击带即清除回落）
var _forced_target: Node = null
## 下次选举倒计时（s；到 0 触发增量改进检查）
var _acquire_timer: float = 0.0
## 当前目标已驻留时长（s；换靶即清零——NotBeenOnTargetForEnoughTime 的计时源）
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


## 每物理帧推进：计时 → 到期/失效则选举。返回当前目标（null = 无目标可打）。
## 追丢（UNREACHABLE）同失效处理：不等扫视节拍立即选举（旧"超 leash 重选"语义）。
func advance(delta: float) -> Node:
	_acquire_timer -= delta
	_dwell += delta
	if _acquire_timer > 0.0 and _tier_of(_target) <= TargetTier.OUT_OF_FIRE_RANGE:
		return _target
	_elect()
	return _target


## 当前目标是否超追击带（behavior_attack._is_beyond_leash 转发；测试观测面）
func is_beyond_leash() -> bool:
	return _tier_of(_target) >= TargetTier.UNREACHABLE


# ─────────────────────────────── 选举（感知拍）────────────────────────────────

## 选举一拍：强制目标 → 小队共享目标 → 自主寻敌，逐层接受/滞回/驻留判定。
## 小队目标存在时在本层消化后返回（集火号令期间队员不自选——号令粘性）。
func _elect() -> void:
	_acquire_timer = _p("acquire_interval", ACQUIRE_INTERVAL)
	# 1. 强制目标（打通态拦路者）：有效且未超追击范围 → 最高优先锁定
	var forced: Node = _valid_forced()
	if forced != null:
		_accept(forced)
		_commander_guard()
		return
	# 2. 小队共享目标（排长集火号令）：存在则在此层消化（队员不自选）
	var squad: Node = _squad_target()
	if squad != null:
		if _should_switch_to(squad):
			_accept(squad)
		_commander_guard()
		return
	# 3. 自主寻敌（增量改进）：扫最优候选，滞回/驻留/分层判定换靶
	var best: Node = ScriptFinder.find_target(entity, {
		"battle": battle,
		"ignore_current_attackers": true,
		"prefer_large": _p("prefer_large", 0.0),
		"only_forward": false,
	})
	if best != null and _should_switch_to(best):
		_accept(best)
	_commander_guard()


## 换靶判定（滞回 + 驻留 + 分层阈值）：
##   - 当前 LOST（死亡/失效）或 UNREACHABLE（追丢）→ 立即换（事件触发边，
##     决斗到死的"死"边 + 旧"超 leash 重选"语义，任何有效候选接管）
##   - 候选层更低（射程内 < 追击带 < 追丢）→ 立即换（质变不走滞回）
##   - 候选层更高 → 不换
##   - 同层 → 驻留满 dwell_min 且 距离 < 当前 × ratio 才换（量变双门）
##   - ratio <= 0 = 关滞回（回旧"始终换"语义）；dwell_min < 0.05 = 关驻留
func _should_switch_to(candidate: Node) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	var cur_tier: int = _tier_of(_target)
	if cur_tier >= TargetTier.UNREACHABLE:
		return true
	var cand_tier: int = _tier_of(candidate)
	if cand_tier < cur_tier:
		return true
	if cand_tier > cur_tier:
		return false
	var ratio: float = _p("target_switch_ratio", TARGET_SWITCH_RATIO)
	if ratio <= 0.0:
		return true
	if _dwell < _p("target_dwell_min", TARGET_DWELL_MIN):
		return false
	return entity.global_position.distance_to(candidate.global_position) \
			< entity.global_position.distance_to(_target.global_position) * ratio


## 接受目标（换靶清零驻留时钟；同目标续驻留）
func _accept(t: Node) -> void:
	if t == _target:
		return
	_target = t
	_dwell = 0.0


## 强制目标有效性维护：有效 → 返回目标；死亡/失效/超追击带 → 清除返回 null
func _valid_forced() -> Node:
	if _forced_target == null:
		return null
	var ok: bool = is_instance_valid(_forced_target) \
			and not (_forced_target.has_method("is_dead") and _forced_target.is_dead())
	if ok and _tier_of(_forced_target) >= TargetTier.UNREACHABLE:
		ok = false
	if not ok:
		_forced_target = null
		return null
	return _forced_target


## 小队共享目标（排长集火）：经宿主 Callable 查询（duck 链在 behavior_attack）
func _squad_target() -> Node:
	if not squad_target_fn.is_valid():
		return null
	var t: Node = squad_target_fn.call()
	if t == null or not is_instance_valid(t):
		return null
	return t


## 指挥官守卫（斩首规则）：自主接战目标必须在追击带内——无此门无班的指挥官
## 会跨半个战场冲锋（留守失效）。超带不选不追 → 待命，敌近身后自然选中自卫。
func _commander_guard() -> void:
	if _target == null or entity == null or not is_instance_valid(entity):
		return
	if entity.has_method("is_commander") and entity.is_commander() \
			and _tier_of(_target) >= TargetTier.UNREACHABLE:
		_target = null


# ─────────────────────────────── 内部 ────────────────────────────────

## 目标分层：死亡/失效 = LOST；距离带三档（射程/追击带/追丢）
func _tier_of(t: Node) -> int:
	if t == null or not is_instance_valid(t) or entity == null:
		return TargetTier.LOST
	if t.has_method("is_dead") and t.is_dead():
		return TargetTier.LOST
	var dist: float = entity.global_position.distance_to(t.global_position)
	var range: float = _attack_range()
	if dist <= range:
		return TargetTier.IN_FIRE_RANGE
	if dist <= range * _p("leash_mult", LEASH_MULT):
		return TargetTier.OUT_OF_FIRE_RANGE
	return TargetTier.UNREACHABLE


## 攻击射程（duck 读武器；无武器回落 100 = behavior_attack 旧口径）
func _attack_range() -> float:
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_weapon"):
		return 100.0
	var w: Node = entity.get_weapon()
	if w != null and "attack_range" in w:
		return float(w.attack_range)
	return 100.0


## 档案参数读取（float；缺省回退本文件常量 = BASELINE 同值）
func _p(key: String, fallback: float) -> float:
	return float(profile.get(key, fallback))
