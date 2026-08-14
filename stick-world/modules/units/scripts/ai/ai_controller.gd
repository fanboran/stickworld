class_name AIController
extends Node
## AI 决策大脑 -- 持有行为状态机，根据三层命令系统决策行为切换。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1 / §7.3。
## 职责：
##   1. 持有 BehaviorStateMachine，注册并调度行为
##   2. 每决策周期检查当前状态，决定是否切换行为
##   3. 玩家附身时暂停 AI，取消附身时恢复
##
## P0 阶段实现最简决策：
#   - work（有派工）优先级最高
#   - idle 完成后，若有派工则 work，否则继续原地待机（不随机漫游）
#   - wander 仅保留供战术号令等场景显式调用

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptBehaviorWork := preload("res://modules/units/scripts/ai/behavior_work.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")
const ScriptBehaviorSeekCover := preload("res://modules/units/scripts/ai/behavior_seek_cover.gd")
const ScriptBehaviorRetreat := preload("res://modules/units/scripts/ai/behavior_retreat.gd")
const ScriptBehaviorHaul := preload("res://modules/units/scripts/ai/behavior_haul.gd")
const ScriptBehaviorFollow := preload("res://modules/units/scripts/ai/behavior_follow.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 决策检查间隔（秒）
const DECISION_INTERVAL: float = 0.3
## idle 后切换到 wander 的概率（当前 0：工人无事做原地待机，不随机漫游。
## BehaviorWander 行为本体保留，敌人 AI / 闲逛功能启用时调大此值即可）
const WANDER_PROBABILITY: float = 0.0

## 工作类型（与 FormationSystem.WorkType 保持一致，本地常量避免跨模块依赖）
const WorkTypeCombat := "WORK_COMBAT"
const WorkTypeBuild := "WORK_BUILD"
const WorkTypeHaul := "WORK_HAUL"
const WorkTypeForage := "WORK_FORAGE"

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属实体引用
var _entity: CharacterBody2D = null
## 行为状态机
var _state_machine: BehaviorStateMachine = null
## 决策计时器
var _decision_timer: float = 0.0
## 上一帧是否被附身（用于检测附身状态变化）
var _was_possessed: bool = false

# ─────────────────────────────── 命令覆盖（§8.3 战术号令）────────────────────────────────
## 当前下达的命令行为名（空=无命令，由 AI 自主决策）
var _ordered_behavior: String = ""
## 命令参数
var _ordered_params: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_entity = get_parent() as CharacterBody2D
	if _entity == null:
		push_error("[AIController] 父节点非 CharacterBody2D，AI 无法工作")
		return
	_setup_state_machine()


## 创建状态机并注册基础行为
func _setup_state_machine() -> void:
	_state_machine = BehaviorStateMachine.new()
	_state_machine.name = "BehaviorStateMachine"
	add_child(_state_machine)

	var idle := BehaviorIdle.new()
	idle.name = "BehaviorIdle"
	idle.behavior_name = "idle"
	idle.entity = _entity
	_state_machine.add_child(idle)
	_state_machine.register_behavior(idle)

	var wander := BehaviorWander.new()
	wander.name = "BehaviorWander"
	wander.behavior_name = "wander"
	wander.entity = _entity
	_state_machine.add_child(wander)
	_state_machine.register_behavior(wander)

	var work := ScriptBehaviorWork.new()
	work.name = "BehaviorWork"
	work.behavior_name = "work"
	work.entity = _entity
	_state_machine.add_child(work)
	_state_machine.register_behavior(work)

	# 搬运行为（仓库↔工地往返，阶段3）
	var haul := ScriptBehaviorHaul.new()
	haul.name = "BehaviorHaul"
	haul.behavior_name = "haul"
	haul.entity = _entity
	_state_machine.add_child(haul)
	_state_machine.register_behavior(haul)

	# 跟随行为（小队"跟随玩家"模式，§8.3）
	var follow := ScriptBehaviorFollow.new()
	follow.name = "BehaviorFollow"
	follow.behavior_name = "follow"
	follow.entity = _entity
	_state_machine.add_child(follow)
	_state_machine.register_behavior(follow)

	# 移动行为（§7.2，阶段 0.6 战术号令用）
	var move := ScriptBehaviorMove.new()
	move.name = "BehaviorMove"
	move.behavior_name = "move"
	move.entity = _entity
	_state_machine.add_child(move)
	_state_machine.register_behavior(move)

	# 战斗行为（§7.2 / §8，阶段 0.5）
	var attack := ScriptBehaviorAttack.new()
	attack.name = "BehaviorAttack"
	attack.behavior_name = "attack"
	attack.entity = _entity
	_state_machine.add_child(attack)
	_state_machine.register_behavior(attack)

	var seek_cover := ScriptBehaviorSeekCover.new()
	seek_cover.name = "BehaviorSeekCover"
	seek_cover.behavior_name = "seek_cover"
	seek_cover.entity = _entity
	_state_machine.add_child(seek_cover)
	_state_machine.register_behavior(seek_cover)

	var retreat := ScriptBehaviorRetreat.new()
	retreat.name = "BehaviorRetreat"
	retreat.behavior_name = "retreat"
	retreat.entity = _entity
	_state_machine.add_child(retreat)
	_state_machine.register_behavior(retreat)

	# 初始行为：闲置
	_state_machine.travel("idle")


# ─────────────────────────────── 每物理帧（由 StickmanEntity 调用）────────────────────────────────

## 由 StickmanEntity._physics_process 在处理 AI 输入前调用。
## 负责状态机调度 + 决策，设置 entity 的 AI 移动方向。
func physics_update(delta: float) -> void:
	if _entity == null or not is_instance_valid(_entity):
		return
	if _state_machine == null:
		return

	# 附身检测
	var possessed: bool = _entity.is_possessed()
	if possessed:
		if not _was_possessed:
			_was_possessed = true
		return  # 附身时暂停 AI

	if _was_possessed:
		# 刚取消附身，恢复 AI 从 idle 开始
		_was_possessed = false
		_state_machine.travel("idle")

	# 状态机调度
	_state_machine.physics_update(delta)

	# 决策
	_decision_timer += delta
	if _decision_timer >= DECISION_INTERVAL:
		_decision_timer = 0.0
		_make_decision()


# ─────────────────────────────── 决策逻辑 ────────────────────────────────

## P0 决策：命令覆盖 > 战斗（参战时）> work（有派工）> idle/wander 循环。
## 命令覆盖：tactical_orders 下达的号令优先于自主决策，但溃逃例外。
## 职责过滤：编队中的单位只能做队伍职责范围内的行为（见 _can_work / _can_combat）。
func _make_decision() -> void:
	# 0. 命令覆盖（最高优先级，溃逃例外）
	if not _ordered_behavior.is_empty():
		if _is_routing():
			# 士气崩溃，无视命令强制溃逃
			_ordered_behavior = ""
			_ordered_params = {}
		else:
			var cur_behavior: String = _state_machine.get_current_behavior_name()
			if cur_behavior == _ordered_behavior:
				if not _state_machine.is_current_finished():
					return  # 命令执行中，保持
				# 命令完成，清除并转入正常决策
				_ordered_behavior = ""
				_ordered_params = {}
			else:
				# 命令被中断（如战斗行为抢占），重新下达
				_state_machine.travel(_ordered_behavior, _ordered_params)
				return
	# 1. 战斗决策（最高优先级，阶段 0.5）
	if _try_combat():
		return
	# 1.5 跟随决策（小队开启跟随玩家时，高于工作/待机）
	if _try_follow():
		return
	if not _state_machine.has_active_behavior():
		# 无激活行为，检查派工
		if _try_work():
			return
		_state_machine.travel("idle")
		return

	var current := _state_machine.get_current_behavior_name()
	if not _state_machine.is_current_finished():
		return  # 当前行为未完成，不切换

	if current == "idle":
		# 闲置完成：优先看是否有派工
		if _try_work():
			return
		# 没有派工，原地待机（P0 关闭随机漫游，工人无事做原地待命）
		_state_machine.travel("idle")
	elif current == "wander":
		# 漫游完成：先检查派工
		if _try_work():
			return
		_state_machine.travel("idle")
	elif current == "work":
		# work 完成（项目完工或取消）：检查是否还有派工
		if _try_work():
			return
		_state_machine.travel("idle")
	else:
		# 未知行为，回 idle
		_state_machine.travel("idle")


## 尝试战斗决策。当 entity 参战（有激活的 battle_instance）时返回 true 并切换到战斗行为。
## 决策优先级：溃逃/士气极低 -> retreat；重伤且附近有掩体 -> seek_cover；默认 -> attack。
## 职责过滤：队伍职责不含 WORK_COMBAT 的单位不进入战斗决策（如建造队/工人队）。
func _try_combat() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _can_work(WorkTypeCombat):
		return false
	if not _entity.has_method("get_battle_instance"):
		return false
	var bi: Node = _entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi):
		return false
	if not bi.has_method("is_active") or not bi.is_active():
		return false
	if _entity.has_method("is_dead") and _entity.is_dead():
		return false
	# 战斗行为进行中且未完成 -> 保持
	var current: String = _state_machine.get_current_behavior_name()
	if current in ["attack", "seek_cover", "retreat"]:
		if not _state_machine.is_current_finished():
			return true
	var bi_param: Dictionary = {"battle": bi}
	var health: Node = _entity.get_health() if _entity.has_method("get_health") else null
	# 溃逃或士气极低 -> retreat
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			_state_machine.travel("retreat", bi_param)
			return true
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() < 0.25:
			_state_machine.travel("retreat", bi_param)
			return true
		# HP 低且附近有掩体 -> seek_cover
		if health.has_method("get_hp_ratio") and health.get_hp_ratio() < 0.4:
			var cover = bi.get_cover() if bi.has_method("get_cover") else null
			if cover != null and cover.has_method("has_covers") and cover.has_covers():
				_state_machine.travel("seek_cover", bi_param)
				return true
	# 默认 -> attack
	_state_machine.travel("attack", bi_param)
	return true


## 尝试进入 work 行为。如果工人被派工到活跃项目，travel("work", {project})。
## 返回 true 表示已切换到 work。
## 职责过滤：队伍职责不含 WORK_BUILD/WORK_HAUL 的单位不接建造派工（如战斗班）。
func _try_work() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _can_work(WorkTypeBuild):
		return false
	if not _entity.has_method("get_construction_manager"):
		return false
	var manager: Node = _entity.get_construction_manager()
	if manager == null:
		return false
	if not manager.has_method("get_worker_project"):
		return false
	var project: RefCounted = manager.get_worker_project(_entity)
	if project == null:
		# 没有派工，尝试自动派工
		if manager.has_method("try_assign_worker"):
			if manager.try_assign_worker(_entity):
				project = manager.get_worker_project(_entity)
	if project == null:
		return false
	# 检查项目是否还在接受工人（PLANNED 或 UNDER_CONSTRUCTION）
	if not project.is_accepting_workers():
		return false
	# 职责过滤按实际行为分支判断：需要材料时按 WORK_HAUL 过滤，否则按 WORK_BUILD 过滤。
	# 修复：此前入口处只校验 WORK_BUILD，导致仅含 WORK_HAUL 的工人队（fp_worker_crew）无法搬运。
	var can_build: bool = _can_work(WorkTypeBuild)
	var can_haul: bool = _can_work(WorkTypeHaul)
	if project.needs_material() and can_haul and _has_warehouse():
		_state_machine.travel("haul", {"project": project})
		return true
	if can_build:
		_state_machine.travel("work", {"project": project})
		return true
	return false


## 是否存在可用的仓库建筑（搬运取货点）。
func _has_warehouse() -> bool:
	if _entity == null or not _entity.has_method("get_construction_manager"):
		return false
	var manager: Node = _entity.get_construction_manager()
	if manager == null or not manager.has_method("get_nearest_warehouse"):
		return false
	return manager.get_nearest_warehouse(_entity.global_position) != null


## 检查单位是否被队伍职责允许执行某工作类型（编队行为过滤）。
## 通过 entity 上的 FormationSystem 引用查询；未注入（未编队/测试直生实体）视为允许。
func _can_work(work_type: String) -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return true
	if not _entity.has_method("get_formation_system"):
		return true
	var fs: Node = _entity.get_formation_system()
	if fs == null or not fs.has_method("is_work_allowed"):
		return true
	return fs.is_work_allowed(_entity, work_type)


## 尝试跟随决策：单位所在小队开启"跟随玩家"时，travel("follow") 尾随玩家。
## 返回 true 表示已切换到跟随。
func _try_follow() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _entity.has_method("get_formation_system"):
		return false
	var fs: Node = _entity.get_formation_system()
	if fs == null or not fs.has_method("is_unit_squad_following"):
		return false
	if not fs.is_unit_squad_following(_entity):
		return false
	# 当前已在跟随且未完成 → 保持
	var cur: String = _state_machine.get_current_behavior_name()
	if cur == "follow":
		if not _state_machine.is_current_finished():
			return true
	# 切换到跟随
	_state_machine.travel("follow")
	return true


# ─────────────────────────────── 公共 API ────────────────────────────────

## 获取当前行为名。
func get_current_behavior() -> String:
	if _state_machine == null:
		return ""
	return _state_machine.get_current_behavior_name()


## 获取状态机引用（供测试用）。
func get_state_machine() -> BehaviorStateMachine:
	return _state_machine


# ─────────────────────────────── 命令覆盖 API（§8.3 战术号令）────────────────────────────────

## 下达命令：覆盖 AI 自主决策，强制执行指定行为直到完成或新命令。
## behavior_name 必须是已注册的行为名（如 "move", "idle", "retreat"）。
## 未注册时拒绝并告警，避免命令残留导致每 0.3s 重试死循环（2026-08 审计修复）。
func set_order(behavior_name: String, params: Dictionary = {}) -> void:
	if _state_machine != null and not _state_machine.has_behavior(behavior_name):
		push_warning("[AIController] 拒绝未注册行为命令: %s" % behavior_name)
		return
	_ordered_behavior = behavior_name
	_ordered_params = params
	if _state_machine != null:
		_state_machine.travel(behavior_name, params)


## 清除命令：恢复 AI 自主决策。
func clear_order() -> void:
	_ordered_behavior = ""
	_ordered_params = {}


## 获取当前命令行为名（空=无命令）。
func get_ordered_behavior() -> String:
	return _ordered_behavior


## 是否有命令在执行。
func has_order() -> bool:
	return not _ordered_behavior.is_empty()


# ─────────────────────────────── 内部辅助 ────────────────────────────────

## 检查实体是否正在溃逃（士气低于阈值）。
func _is_routing() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _entity.has_method("get_health"):
		return false
	var health: Node = _entity.get_health()
	if health == null or not health.has_method("is_routed"):
		return false
	return health.is_routed()
