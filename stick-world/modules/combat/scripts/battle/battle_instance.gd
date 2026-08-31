class_name BattleInstance
extends Node
## 单场战斗实例 -- 纯逻辑+调度，挂载到 MapInstance.BattleAnchor。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.1（战斗实例 vs 战场场景）。
## 管理参战双方、战斗状态、伤亡统计、胜负判定。
## 不依赖场景渲染，只持有单位引用并 tick AI 导演。
##
## 设计原则（§8.1）：城镇被袭变战场时不切场景，当前 VillageMap 挂载本节点即可。
## BattleAnchor 节点就是本实例的挂载点。无战斗时为空。
##
## 状态流转：PREPARING -> ENGAGED -> ATTACKER_WIN / DEFENDER_WIN / DRAW

const ScriptCoverSystem := preload("res://modules/combat/scripts/battle/cover_system.gd")
const ScriptBattleAIDirector := preload("res://modules/combat/scripts/battle/battle_ai_director.gd")

# ─────────────────────────────── 状态枚举 ────────────────────────────────
enum State {
	PREPARING,      ## 准备阶段
	ENGAGED,        ## 交战中
	ATTACKER_WIN,   ## 进攻方（faction 1）胜利
	DEFENDER_WIN,   ## 防守方（faction 2）胜利
	DRAW,           ## 平局（双方同时覆灭）
}

# ─────────────────────────────── 常量（士气）────────────────────────────────
## 伤亡恐慌：队友死亡时同阵营单位的最大士气损失（距离衰减）
const ALLY_DEATH_MORALE_LOSS: float = 12.0
## 伤亡恐慌影响半径（px）
const MORALE_AFFECT_RANGE: float = 600.0

## 防集火计数的新鲜窗口（ms）：超过此间隔未再登记的攻击者视为停手，不再计数
const ATTACKER_FRESH_WINDOW_MS: int = 3000

# ─────────────────────────────── 常量 ────────────────────────────────
## 进攻方阵营 ID
const FACTION_ATTACKER: int = 1
## 防守方阵营 ID
const FACTION_DEFENDER: int = 2

# ─────────────────────────────── 运行时 ────────────────────────────────
## 战斗所在地图
var _map: Node2D = null
## 掩体系统
var _cover: ScriptCoverSystem = null
## 战场导演
var _director: ScriptBattleAIDirector = null
## 进攻方单位列表
var _units_attacker: Array = []
## 防守方单位列表
var _units_defender: Array = []
## 战斗状态
var _state: State = State.PREPARING
## 战斗持续时长（秒）
var _duration: float = 0.0
## 进攻方伤亡数（死亡）
var _casualties_attacker: int = 0
## 防守方伤亡数（死亡）
var _casualties_defender: int = 0
## 每目标当前攻击者数（防集火重叠；反编译参考实装 A 的 TODO 落地）。
## 结构：target.instance_id -> {"attackers": {attacker_iid: 最后登记 msec}}。
## 计数按新鲜窗口衰减（审计 P1-3）：攻击者停手超过窗口后自动失效，
## 无需依赖 unregister_attacker 被正确调用（原"只增不减"导致集火分配逐渐失真）。
var _target_attackers: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 初始化：注入地图，创建掩体系统和导演。
func setup(map: Node2D) -> void:
	_map = map
	_cover = ScriptCoverSystem.new()
	_cover.setup(map)
	_director = ScriptBattleAIDirector.new()
	_director.setup(self)


## 添加参战单位。
## unit: StickmanEntity（需有 set_faction / set_battle_instance / get_health）
## faction: FACTION_ATTACKER(1) 或 FACTION_DEFENDER(2)
func add_unit(unit: Node, faction: int) -> void:
	if not is_instance_valid(unit):
		return
	if unit.has_method("set_faction"):
		unit.set_faction(faction)
	if unit.has_method("set_battle_instance"):
		unit.set_battle_instance(self)
	if faction == FACTION_ATTACKER:
		_units_attacker.append(unit)
	else:
		_units_defender.append(unit)


## 开始战斗（PREPARING -> ENGAGED）
func start() -> void:
	_state = State.ENGAGED
	if EventBus != null:
		EventBus.battle_started.emit(get_battle_id())


func _physics_process(delta: float) -> void:
	if _state != State.ENGAGED:
		return
	# TimeManager 暂停门禁（审计 P1-5"假暂停"）：暂停语义全局统一，战斗停 tick
	if TimeManager != null and TimeManager.is_paused():
		return
	_duration += delta
	_director.tick(delta)
	_check_victory()


# ─────────────────────────────── 单位事件 ────────────────────────────────

## 单位死亡回调（由 StickmanEntity._on_died 调用）
func on_unit_died(unit: Node) -> void:
	if unit in _units_attacker:
		_casualties_attacker += 1
	elif unit in _units_defender:
		_casualties_defender += 1
	# 清理该目标上的攻击者计数（死亡后不再被围攻）
	_target_attackers.erase(unit.get_instance_id())
	# 伤亡恐慌（行业最佳实践）：同阵营存活单位按距离衰减掉士气（见队友倒下）
	if unit.has_method("get_faction"):
		_apply_casualty_morale_loss(unit.get_faction(), unit.global_position)


## 伤亡恐慌：同阵营存活单位按距离衰减掉士气。
## 距离 MORALE_AFFECT_RANGE 内的单位损失 LOSS × (1 - dist/range)。
func _apply_casualty_morale_loss(faction: int, pos: Vector2) -> void:
	for ally in get_allies_of(faction):
		if not is_instance_valid(ally) or ally == null:
			continue
		if ally.has_method("is_dead") and ally.is_dead():
			continue
		if not ally.has_method("get_health"):
			continue
		var health: Node = ally.get_health()
		if health == null or not health.has_method("lose_morale"):
			continue
		var dist: float = pos.distance_to(ally.global_position)
		if dist > MORALE_AFFECT_RANGE:
			continue
		var loss: float = ALLY_DEATH_MORALE_LOSS * (1.0 - dist / MORALE_AFFECT_RANGE)
		health.lose_morale(loss)


# ─────────────────────────────── 攻击者计数（防集火重叠）────────────────────────────────

## 登记一次攻击：target 被 attacker 攻击（weapon_mount.perform_attack 命中时调用）。
## 记录最后登记时间，计数按新鲜窗口自动衰减（见 get_attacker_count）。
func register_attacker(target: Node, attacker: Node) -> void:
	if target == null or attacker == null or not is_instance_valid(target) or not is_instance_valid(attacker):
		return
	var iid: int = target.get_instance_id()
	if not _target_attackers.has(iid):
		_target_attackers[iid] = {"attackers": {}}
	var entry: Dictionary = _target_attackers[iid]
	# 刷新该攻击者的最后登记时间（持续攻击 = 持续占用攻击槽）
	entry["attackers"][attacker.get_instance_id()] = Time.get_ticks_msec()


## 撤销一次攻击（攻击者失效/停止攻击时；兜底用——正常路径按新鲜窗口自动衰减）
func unregister_attacker(target: Node, attacker: Node) -> void:
	if target == null or attacker == null or not is_instance_valid(target):
		return
	var iid: int = target.get_instance_id()
	if not _target_attackers.has(iid):
		return
	var entry: Dictionary = _target_attackers[iid]
	entry["attackers"].erase(attacker.get_instance_id())
	if entry["attackers"].is_empty():
		_target_attackers.erase(iid)


## 查询某目标当前被几个单位攻击（TargetFinder 防集火过滤用）。
## 只统计新鲜窗口内（ATTACKER_FRESH_WINDOW_MS）仍登记的攻击者，
## 过期项顺带惰性清理——修复原"只增不减"导致的集火分配失真（审计 P1-3）。
func get_attacker_count(target: Node) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var iid: int = target.get_instance_id()
	var entry: Variant = _target_attackers.get(iid, null)
	if entry == null:
		return 0
	var now_ms: int = Time.get_ticks_msec()
	var fresh: int = 0
	var expired: Array = []
	for attacker_iid in entry["attackers"].keys():
		if now_ms - int(entry["attackers"][attacker_iid]) <= ATTACKER_FRESH_WINDOW_MS:
			fresh += 1
		else:
			expired.append(attacker_iid)
	for k in expired:
		entry["attackers"].erase(k)
	if entry["attackers"].is_empty():
		_target_attackers.erase(iid)
	return fresh


# ─────────────────────────────── 查询 API ────────────────────────────────

## 获取某阵营的所有敌人（含已死亡，调用方需自行过滤）
func get_enemies_of(faction: int) -> Array:
	return _units_defender if faction == FACTION_ATTACKER else _units_attacker


## 获取某阵营的所有盟友
func get_allies_of(faction: int) -> Array:
	return _units_attacker if faction == FACTION_ATTACKER else _units_defender


## 获取所有参战单位
func get_all_units() -> Array:
	return _units_attacker + _units_defender


## 获取某单位最近的存活敌人
func get_nearest_enemy(unit: Node) -> Node:
	if not is_instance_valid(unit):
		return null
	var faction: int = unit.faction_id if "faction_id" in unit else 0
	var enemies: Array = get_enemies_of(faction)
	var best: Node = null
	var best_dist: float = INF
	for e in enemies:
		if not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var d: float = unit.global_position.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best


## 获取掩体系统
func get_cover() -> ScriptCoverSystem:
	return _cover


## 获取战场导演
func get_director() -> ScriptBattleAIDirector:
	return _director


## 战斗是否进行中
func is_active() -> bool:
	return _state == State.ENGAGED


## 获取战斗状态
func get_state() -> State:
	return _state


## 获取胜方阵营 ID（0=进行中/平局，1=进攻方，2=防守方）
func get_winner() -> int:
	match _state:
		State.ATTACKER_WIN:
			return FACTION_ATTACKER
		State.DEFENDER_WIN:
			return FACTION_DEFENDER
		_:
			return 0


## 获取战斗 ID（用于 EventBus 信号）
func get_battle_id() -> String:
	return "battle_%d" % get_instance_id()


## 获取战斗持续时长
func get_duration() -> float:
	return _duration


## 获取某方伤亡数
func get_casualties(faction: int) -> int:
	return _casualties_attacker if faction == FACTION_ATTACKER else _casualties_defender


## 获取某方存活单位数
func get_alive_count(faction: int) -> int:
	var units: Array = _units_attacker if faction == FACTION_ATTACKER else _units_defender
	return _count_alive(units)


# ─────────────────────────────── 内部 ────────────────────────────────

## 检查胜负条件：一方全灭则另一方胜
func _check_victory() -> void:
	var a_alive: int = _count_alive(_units_attacker)
	var b_alive: int = _count_alive(_units_defender)
	if a_alive == 0 and b_alive == 0:
		_end(State.DRAW)
	elif a_alive == 0:
		_end(State.DEFENDER_WIN)
	elif b_alive == 0:
		_end(State.ATTACKER_WIN)


func _count_alive(units: Array) -> int:
	var n: int = 0
	for u in units:
		if is_instance_valid(u):
			if u.has_method("is_dead") and not u.is_dead():
				n += 1
			elif not u.has_method("is_dead"):
				n += 1
	return n


func _end(result: State) -> void:
	# 防御：_check_victory 可能在同一帧多次命中，只允许结束一次
	if _state != State.ENGAGED:
		return
	_state = result
	# 清理单位身上的战斗引用（AI 依据 battle_instance 判参战，结束后应立即解除）
	for unit in _units_attacker + _units_defender:
		if is_instance_valid(unit) and unit.has_method("set_battle_instance"):
			unit.set_battle_instance(null)
	_units_attacker.clear()
	_units_defender.clear()
	_target_attackers.clear()
	if EventBus != null:
		var attacker_wins: bool = result == State.ATTACKER_WIN
		EventBus.battle_ended.emit(get_battle_id(), attacker_wins)
	# 结束即释放：Director 只持有引用列表，下一帧会裁剪失效项
	queue_free()
