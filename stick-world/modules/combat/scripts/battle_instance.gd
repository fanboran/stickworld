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

const ScriptCoverSystem := preload("res://modules/combat/scripts/cover_system.gd")
const ScriptBattleAIDirector := preload("res://modules/combat/scripts/battle_ai_director.gd")

# ─────────────────────────────── 状态枚举 ────────────────────────────────
enum State {
	PREPARING,      ## 准备阶段
	ENGAGED,        ## 交战中
	ATTACKER_WIN,   ## 进攻方（faction 1）胜利
	DEFENDER_WIN,   ## 防守方（faction 2）胜利
	DRAW,           ## 平局（双方同时覆灭）
}

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
	_state = result
	if EventBus != null:
		var attacker_wins: bool = result == State.ATTACKER_WIN
		EventBus.battle_ended.emit(get_battle_id(), attacker_wins)
