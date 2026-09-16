extends RefCounted
## AIController 行为注册表 —— 纯 static 工厂：承接 _setup_state_machine 的
## 11 段行为注册样板（创建 → 命名/注入实体 → 入状态机 → 注册）。
##
## 纪律：
## - 无状态：不持任何回引/实例字段，宿主经 build(entity) 取装好的状态机；
## - 9 个行为节点 preload 随迁至此（宿主保留 ScriptBehaviorProfiles preload 自用，
##   本工厂不消费行为档案）；
## - 行为创建顺序/命名/字段注入/注册顺序与拆分前逐行一致；
##   入树（add_child）与初态 travel("idle") 留在宿主壳完成，顺序不变。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1 / §7.2。

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptBehaviorWork := preload("res://modules/units/scripts/ai/behavior_work.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")
const ScriptBehaviorSeekCover := preload("res://modules/units/scripts/ai/behavior_seek_cover.gd")
const ScriptBehaviorRetreat := preload("res://modules/units/scripts/ai/behavior_retreat.gd")

const ScriptBehaviorHaul := preload("res://modules/units/scripts/ai/behavior_haul.gd")
const ScriptBehaviorFollow := preload("res://modules/units/scripts/ai/behavior_follow.gd")
const ScriptBehaviorHeal := preload("res://modules/units/scripts/ai/behavior_heal.gd")
const ScriptBehaviorHarvest := preload("res://modules/units/scripts/ai/behavior_harvest.gd")


## 构建状态机并注册全部行为（11 段样板；不含入树与初态 travel）。
static func build(entity: CharacterBody2D) -> BehaviorStateMachine:
	var state_machine := BehaviorStateMachine.new()
	state_machine.name = "BehaviorStateMachine"

	var idle := BehaviorIdle.new()
	idle.name = "BehaviorIdle"
	idle.behavior_name = "idle"
	idle.entity = entity
	state_machine.add_child(idle)
	state_machine.register_behavior(idle)

	var wander := BehaviorWander.new()
	wander.name = "BehaviorWander"
	wander.behavior_name = "wander"
	wander.entity = entity
	state_machine.add_child(wander)
	state_machine.register_behavior(wander)

	var work := ScriptBehaviorWork.new()
	work.name = "BehaviorWork"
	work.behavior_name = "work"
	work.entity = entity
	state_machine.add_child(work)
	state_machine.register_behavior(work)

	# 搬运行为（仓库↔工地往返，阶段3）
	var haul := ScriptBehaviorHaul.new()
	haul.name = "BehaviorHaul"
	haul.behavior_name = "haul"
	haul.entity = entity
	state_machine.add_child(haul)
	state_machine.register_behavior(haul)

	# 采集行为族（小镇生活批次 2：伐木/挖矿/打铁，有职业村民的自主劳作）
	var harvest := ScriptBehaviorHarvest.new()
	harvest.name = "BehaviorHarvest"
	harvest.behavior_name = "harvest"
	harvest.entity = entity
	state_machine.add_child(harvest)
	state_machine.register_behavior(harvest)

	# 跟随行为（小队"跟随玩家"模式，§8.3）
	var follow := ScriptBehaviorFollow.new()
	follow.name = "BehaviorFollow"
	follow.behavior_name = "follow"
	follow.entity = entity
	state_machine.add_child(follow)
	state_machine.register_behavior(follow)

	# 移动行为（§7.2，阶段 0.6 战术号令用）
	var move := ScriptBehaviorMove.new()
	move.name = "BehaviorMove"
	move.behavior_name = "move"
	move.entity = entity
	state_machine.add_child(move)
	state_machine.register_behavior(move)

	# 战斗行为（§7.2 / §8，阶段 0.5）
	var attack := ScriptBehaviorAttack.new()
	attack.name = "BehaviorAttack"
	attack.behavior_name = "attack"
	attack.entity = entity
	state_machine.add_child(attack)
	state_machine.register_behavior(attack)

	var seek_cover := ScriptBehaviorSeekCover.new()
	seek_cover.name = "BehaviorSeekCover"
	seek_cover.behavior_name = "seek_cover"
	seek_cover.entity = entity
	state_machine.add_child(seek_cover)
	state_machine.register_behavior(seek_cover)

	var retreat := ScriptBehaviorRetreat.new()
	retreat.name = "BehaviorRetreat"
	retreat.behavior_name = "retreat"
	retreat.entity = entity
	state_machine.add_child(retreat)
	state_machine.register_behavior(retreat)

	# 治疗行为（P7 批次 7b：MericAi 直译宿主）
	var heal := ScriptBehaviorHeal.new()
	heal.name = "BehaviorHeal"
	heal.behavior_name = "heal"
	heal.entity = entity
	state_machine.add_child(heal)
	state_machine.register_behavior(heal)

	return state_machine
