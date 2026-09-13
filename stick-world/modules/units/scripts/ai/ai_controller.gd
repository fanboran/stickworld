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
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptBehaviorHeal := preload("res://modules/units/scripts/ai/behavior_heal.gd")
const ScriptBehaviorHarvest := preload("res://modules/units/scripts/ai/behavior_harvest.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 决策检查间隔（秒）（R1 代码默认：档案 decision_interval 可覆盖，见 _roll_decision_interval）
const DECISION_INTERVAL: float = 0.3
## 决策间隔硬下限（s）：方差掷骰/配置注入不得低于此值，防决策风暴（对齐 A1 MIN_BEAT_INTERVAL 语义）
const MIN_DECISION_INTERVAL: float = 0.05
## 到点判定时间容差（s，1 纳秒）：绝对时刻比较留容差，消除"间隔恰为帧步长整数倍"
## 时浮点累积舍入方向差异（如 0.3s / (1/60) = 18 帧整）导致的周期 ±1 帧漂移——
## 使关错峰时与旧 delta 累加器触发帧号逐位一致（远小于任何物理帧，无提前触发风险）
const DUE_EPSILON: float = 1.0e-9
## W2 出生错峰 RNG 默认种子（专用 RNG、对齐 A3 RETREAT_MOD_DEFAULT_SEED 惯例：
## 生产按实体实例 id 派生 = 每单位不同；实体不可用/单测未注入时兜底，保证可复现）
const SPAWN_JITTER_DEFAULT_SEED: int = 20260912
## 决策时钟族序列化格式版本（存档字段演进留位；导入侧只认当前版本语义）
const TIMING_STATE_VERSION: int = 1
## W2 域级间隔通道表（channel -> 档案间隔键）：探测型行为失败冷却的粒度单位。
## WorldBox M4 冷却挂"行为 index"不挂单位（Actor.cs `_decision_cooldowns[]`）；本项目
## L1 无行为 index 数组，粒度落到"域级探测"，间隔复用 A9 既有键或新增键：
##   combat 选敌探测（_try_combat，复用 acquire_interval 同域节奏）
##   job    派工/采集探测（_try_work/_try_harvest）
const DOMAIN_CHANNELS: Dictionary = {
	"combat": "acquire_interval",
	"job": "job_scan_interval",
}
## idle 后切换到 wander 的概率（当前 0：工人无事做原地待机，不随机漫游。
## BehaviorWander 行为本体保留，敌人 AI / 闲逛功能启用时调大此值即可）
const WANDER_PROBABILITY: float = 0.0

## 村民 idle 完成后切 wander 的概率（小镇生活批次 3 [提案/待定]：
## 空闲走动让村子"活"起来）。作用域过滤见 _is_villager（批次 4 改造）：
## 村民身份标志（is_villager）+ 不在编队——待业村民闲逛，战斗/编队/敌方
## 单位仍走 WANDER_PROBABILITY=0——待机乱走会破坏战斗测试语义。
## 用 var 便于测试注入 0/1 做确定性断言。
var villager_wander_probability: float = 0.5

## TeamAi 姿态枚举（对齐 TeamAi.STANCE_* / dump Team.Stance 序；本地常量避免跨模块依赖。
## 3=ROUT 敌将撤仗终态，本作扩展——出征与领地架构 §4.2）
const TEAM_AI_STANCE_GARRISON: int = 0
const TEAM_AI_STANCE_DEFEND: int = 1
const TEAM_AI_STANCE_ATTACK: int = 2
const TEAM_AI_STANCE_ROUT: int = 3

## 状态调制（反编译参考实装 E）：低血狂暴 / 被围背墙 背水一战。
## 被围判定：SURROUND_RANGE 内敌对单位 >= SURROUND_MIN 视为被围
const SURROUND_RANGE: float = 120.0
## 威胁判定距离（SWL Ai.IsUnderThreat：近身有活敌即被威胁；
## dump 无数值真值，取被围半径同量级，待实测校准）
const THREAT_RANGE: float = 140.0
## 被围所需敌对单位数
const SURROUND_MIN: int = 2
## 背墙判定：身后此距离内有掩体视为背墙
const WALL_LOOKBACK: float = 80.0
## 低血狂暴判定阈值（hp_ratio 低于此值视为低血）
const RAGE_LOW_HP: float = 0.3
## 狂暴所需最低士气（低血但士气高于此值 → 狂暴反击；低于此值走溃逃）
const RAGE_MORALE_THRESHOLD: float = 0.4
## 撤退掷骰 RNG 默认种子（A3 · C6：固定默认种子锁确定性，单测可锁/battle_sim
## 可复现；与 A1 team_ai DEFAULT_RANDOM_SEED 同值惯例。测试经
## _retreat_mod_rng.seed 重掷，生产恒定）
const RETREAT_MOD_DEFAULT_SEED: int = 20260911

## 工作类型（与 FormationSystem.WorkType 保持一致，本地常量避免跨模块依赖）
const WorkTypeCombat := "WORK_COMBAT"
const WorkTypeBuild := "WORK_BUILD"
const WorkTypeHaul := "WORK_HAUL"
const WorkTypeForage := "WORK_FORAGE"

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属实体引用
var _entity: CharacterBody2D = null
## 状态机
var _state_machine: BehaviorStateMachine = null
## 世界时钟（s，本 AI 视角的单调游戏时刻）：由 physics_update 累加本拍 delta，
## 暂停/hitstop 时物理帧不推进 = 时钟不推进（与旧累加器语义同源）。
## 绝对时刻语义的基准——所有"下次到期"都记世界时刻而非剩余秒数（WorldBox M4）
var _world_time: float = 0.0
## W2 时钟注入出口（单测确定性断言用；无效 Callable = 用 _world_time 世界时钟）
var clock_override: Callable = Callable()
## W2 出生错峰 RNG 种子覆盖（<0 = 未注入 → 按实体实例 id 派生，成批出生各自不同；
## 显式注入 = 单测/读档可复现，对齐 A3/A9 固定种子惯例）
var jitter_seed_override: int = -1
## 下次决策的世界时刻（s；绝对时刻语义，到点判定 now >= _next_decision_at）
var _next_decision_at: float = INF
## 当前决策间隔（R1 间隔族：基值 ± 方差逐拍重掷，见 _roll_decision_interval）
var _decision_interval: float = DECISION_INTERVAL
## 决策时钟是否已装配（首次装配前不消费时钟；physics_update 内兜底懒装配）
var _timing_armed: bool = false
## 已触发的决策拍数（W2 观测面：get_decision_timing_state 消费，拨针单测可断言拍数）
var _decision_beats: int = 0
## 各域级通道的下次到期世界时刻（channel -> 时刻，s；W2 假偏移/失败冷却落点）
var _domain_next_at: Dictionary = {}
## W2 出生错峰专用 RNG（与全局 randf 隔离：种子可注入 = 单测确定性；
## 装配置一次种子，逐通道各抽一次 = 通道间独立错峰）
var _jitter_rng := RandomNumberGenerator.new()
## 上一帧是否被附身（用于检测附身状态变化）
var _was_possessed: bool = false
## 9i+ 试探接敌脉冲状态（test_engage_enabled 开时在脱战低士气分支消费）
var _test_pulse_active: bool = false
var _test_pulse_until: float = -1.0e9
## A3 · C6 撤退掷骰专用 RNG（与全局 randf 隔离：固定默认种子锁确定性，
## 单测/battle_sim 可复现；先例 team_ai._rng）
var _retreat_mod_rng := RandomNumberGenerator.new()
## A3 · C6 下次允许掷骰的战斗时刻（战斗时长时间戳法，同 _test_pulse_until；
## 掷骰节流 = 档案 retreat_mod_reevaluate 评估周期内只掷一次）
var _retreat_mod_next_roll_at: float = -1.0e9
## W1 观测面（get_retreat_mod_state 消费）：最近一次调制评估快照——候选因子
## 命中集/掷骰值/概率/是否触发。评估未到达（开关关/无威胁/节流内）时保持
## 上次评估值；last_chance 为 NAN = 尚未评估过。
var _retreat_mod_last_factors: Dictionary = {}
var _retreat_mod_last_roll: float = NAN
var _retreat_mod_last_chance: float = NAN
var _retreat_mod_last_result: bool = false

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
	_retreat_mod_rng.seed = RETREAT_MOD_DEFAULT_SEED
	_setup_state_machine()
	# W2 出生错峰：装配完成即预置首次决策/域级到期时刻（关=装配后 interval，
	# 与旧累加器语义一致；开=预置假偏移防成批出生齐套，见 apply_spawn_jitter）
	apply_spawn_jitter()


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

	# 采集行为族（小镇生活批次 2：伐木/挖矿/打铁，有职业村民的自主劳作）
	var harvest := ScriptBehaviorHarvest.new()
	harvest.name = "BehaviorHarvest"
	harvest.behavior_name = "harvest"
	harvest.entity = _entity
	_state_machine.add_child(harvest)
	_state_machine.register_behavior(harvest)

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

	# 治疗行为（P7 批次 7b：MericAi 直译宿主）
	var heal := ScriptBehaviorHeal.new()
	heal.name = "BehaviorHeal"
	heal.behavior_name = "heal"
	heal.entity = _entity
	_state_machine.add_child(heal)
	_state_machine.register_behavior(heal)


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

	# 决策（W2 绝对世界时刻语义）：世界时钟累加本拍 delta（暂停/hitstop 期物理帧
	# 不推进 = 时钟不推进，与旧 delta 累加器逐位同源），到点判定 now >= 到期时刻
	# （不是"剩余秒数倒计时"——读档无换算成本，WorldBox M4）；触发后下次到期 =
	# 触发时刻 + 重掷间隔（余量不结转，等同旧"计时器清零后重掷"）。
	# 探针成败不影响主节拍推进（无失败原地重试路径，③ 语义锁定）
	_world_time += delta
	if _advance_decision_clock(_now()):
		_make_decision()


# ─────────────────────────────── 决策逻辑 ────────────────────────────────

## P0 决策：命令覆盖 > 战斗（参战时）> work（有派工）> idle/wander 循环。
## 命令覆盖：tactical_orders 下达的号令优先于自主决策，但溃逃例外。
## 职责过滤：编队中的单位只能做队伍职责范围内的行为（见 _can_work / _can_combat）。
## 优先级（A6 · C9 落定）：强制溃逃链 > 压制禁令 > 命令覆盖 > 自主决策。
##   - 溃逃 > 压制：禁令是"不敢动"不是"不能逃"，士气崩溃照样跑；
##   - 压制 > 命令覆盖：CoH pinned isInterruptablePlan=false——禁令期号令
##     **挂起不清除**（压制是暂态锁死，号令是玩家意图），压制结束自动续行。
func _make_decision() -> void:
	# 强制溃逃链（士气崩溃）：最高优先——清号令走溃逃强制链（is_routed →
	# retreat 在 _try_combat），压制期亦溃逃
	if _is_routing():
		_ordered_behavior = ""
		_ordered_params = {}
	# 压制禁令（A6 · C9 定时锁死）：非溃逃被压制 → 强制短行为（原地停滞），
	# 不可被常规决策与号令执行打断（惩罚来自模拟因果，非数值折扣）
	elif _is_suppressed():
		_suppressed_stall()
		return
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
	# W2 域级失败冷却（默认关 = 逐拍探测，零回归）：仅在上次"选敌探测失败"后
	# 的冷却窗内跳过重探（探测成功 = 已在战斗中，不会入冷却，故跳过期必无战事）
	if _probe_domain_due("combat"):
		if _try_combat():
			return
		_note_probe_failure("combat")
	# 1.5 跟随决策（小队开启跟随玩家时，高于工作/待机）
	if _try_follow():
		return
	if not _state_machine.has_active_behavior():
		# 无激活行为，检查派工
		if _try_job_probes():
			return
		_state_machine.travel("idle")
		return

	var current := _state_machine.get_current_behavior_name()
	if not _state_machine.is_current_finished():
		return  # 当前行为未完成，不切换

	if current == "idle":
		# 闲置完成：优先看是否有派工
		if _try_job_probes():
			return
		# 村民空闲走动（小镇生活批次 3 [提案/待定]）：村民 idle 完成后概率
		# wander（批次 4 起含待业村民，_is_villager 判身份标志+不在编队）；
		# 其他单位（战斗/编队/敌方）保持原地待命（P0 语义不变）。
		# 村民 wander 锚定村庄中心（批次 4）：待业村民全天闲逛，无锚会累积
		# 漂出村子/地图——锚 = 地图 town_center_world_x（村中心，village_a=0）
		if _is_villager() and randf() < villager_wander_probability:
			_state_machine.travel("wander", _villager_wander_params())
			return
		# 没有派工，原地待机（工人无事做原地待命）
		_state_machine.travel("idle")
	elif current == "wander":
		# 漫游完成：先检查派工
		if _try_job_probes():
			return
		_state_machine.travel("idle")
	elif current == "work":
		# work 完成（项目完工或取消）：检查是否还有派工
		if _try_job_probes():
			return
		_state_machine.travel("idle")
	elif current == "harvest":
		# 采集结束（资源耗尽/无工位/无法寻位）：回 idle，决策循环稍后重试
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
	if current in ["attack", "seek_cover", "retreat", "heal"]:
		if not _state_machine.is_current_finished():
			return true
	var bi_param: Dictionary = {"battle": bi}
	var health: Node = _entity.get_health() if _entity.has_method("get_health") else null
	# 溃逃或士气极低 -> retreat（IsUnderThreat 真值化：低士气且**确有近身威胁**
	# 才溃逃；脱战低士气不强制溃逃，交由士气自然恢复——9i 配套）
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			_state_machine.travel("retreat", bi_param)
			return true
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() < 0.25:
			if _is_under_threat(bi):
				_state_machine.travel("retreat", bi_param)
				return true
			# 脱战低士气：9i+ 增强（逃开后再战 + 前排试探接敌，档案开关默认关 = 既有行为）
			if _try_rout_reengage(bi, bi_param, health):
				return true
			# 既有行为：不进战斗决策（避免 travel→finish 抖动），原地待命回士气
			return false
	# A3 · C6 概率调制撤退：补"未到强制阈值但战况恶化"的中间带（档案开关默认关 =
	# 零回归；强制链优先，见 _try_retreat_modulation 注释）
	if _try_retreat_modulation(bi, bi_param, health):
		return true
	# 状态调制（反编译参考实装 E）：低血狂暴 / 被围背墙背水一战
	var mods: Dictionary = _compute_state_modifiers(bi, health)
	if _should_rage(mods, health):
		var rage_param: Dictionary = bi_param.duplicate()
		rage_param["rage"] = true
		_state_machine.travel("attack", rage_param)
		return true
	# HP 低且附近有掩体 -> seek_cover
	if health != null and health.has_method("get_hp_ratio") and health.get_hp_ratio() < 0.4:
		var cover = bi.get_cover() if bi.has_method("get_cover") else null
		if cover != null and cover.has_method("has_covers") and cover.has_covers():
			_state_machine.travel("seek_cover", bi_param)
			return true
	# 默认 -> attack（MERIC 祭司路由到 heal，P7 批次 7b）
	if _is_meric():
		_state_machine.travel("heal", bi_param)
	else:
		_state_machine.travel("attack", bi_param)
	return true


## A3 · C6 概率调制撤退（设计文档12号 §三C6 / 设计原则3）：补"未到强制阈值但
## 战况恶化"的中间带——血量/士气逼近阈值或周边友军崩坏时，按档案概率掷骰
## 触发 RETREAT（非确定性开关，消除阈值边界的机械感；掷骰是执行机制不是因果，
## 候选判定仍是真实战况）。与既有强制溃逃链并存：上游 is_routed / 低士气+近身
## 威胁已 return（强制链优先），本函数只处理中间带。
## 双档语义（CoH fallback_*/retreat_* 同构）：战线崩坏 → withdraw 撤退回己方
## 锚点；个人战况恶化 → fallback 战术后退（脱离接触原地后撤重整）。
## 返回 true 表示已切入撤退行为。
func _try_retreat_modulation(bi: Node, bi_param: Dictionary, health: Node) -> bool:
	var profile: Dictionary = _get_behavior_profile()
	if not bool(profile.get("retreat_mod_enabled", false)):
		return false
	# 近身无威胁不评估（脱战不逃；脱战低士气分支语义不变）
	if not _is_under_threat(bi):
		return false
	# 掷骰节流：评估周期内只掷一次（CoH retreat_chance_reevaluate_ticks 20 tick≈2.5s）
	var now: float = bi.get_duration() \
			if bi != null and is_instance_valid(bi) and bi.has_method("get_duration") else 0.0
	if now < _retreat_mod_next_roll_at:
		return false
	_retreat_mod_next_roll_at = now + maxf(float(profile.get("retreat_mod_reevaluate", 2.5)), 0.05)
	# 候选判定（因果=真实战况，三因子任一成立即候选）
	var hp_ok := true
	var morale_ok := true
	if health != null:
		if health.has_method("get_hp_ratio"):
			hp_ok = health.get_hp_ratio() >= float(profile.get("retreat_mod_hp_ratio", 0.49))
		if health.has_method("get_morale_ratio"):
			morale_ok = health.get_morale_ratio() >= float(profile.get("retreat_mod_morale_ratio", 0.35))
	var line_collapsed := _nearby_ally_break_ratio(bi, profile) \
			>= float(profile.get("retreat_mod_ally_break_ratio", 0.51))
	# W1 观测面：候选因子命中项登记（任一 true = 撤退候选；查询 get_retreat_mod_state）
	_retreat_mod_last_factors = {
		"hp_low": not hp_ok,
		"morale_low": not morale_ok,
		"line_collapsed": line_collapsed,
	}
	if hp_ok and morale_ok and not line_collapsed:
		return false
	# 掷骰概率三级链（难度分档已裁决移除·开放问题#3）：档案显式值（NAN=未覆写）
	# → personality 单一档案 global 行 retreat_chance → 代码默认
	var chance: float = float(profile.get("retreat_mod_chance", NAN))
	if is_nan(chance):
		chance = ScriptBehaviorProfiles.get_personality_retreat_chance()
	if is_nan(chance):
		chance = 0.30
	# W1 观测面：掷骰值/概率/结果登记（概率是执行机制不是因果，调试可见）
	var roll: float = _retreat_mod_rng.randf()
	_retreat_mod_last_roll = roll
	_retreat_mod_last_chance = chance
	_retreat_mod_last_result = roll < chance
	if roll >= chance:
		return false
	# 双档语义：战线崩坏 → 撤退（回锚点）；个人战况恶化 → 后撤（战术后退重整）
	var params: Dictionary = bi_param.duplicate()
	params["retreat_mode"] = "withdraw" if line_collapsed else "fallback"
	_state_machine.travel("retreat", params)
	return true


## 附近友军崩坏比例（A3 · C6 候选因子三）：判定半径内同阵营单位中"已阵亡或
## 已溃逃"的占比（CoH retreat_suppressed_percentage「周边小队被压制比例」同构
## ——本作压制映射到士气/存活状态）。无友军（孤军）返回 0：孤军安危由个人
## 血量/士气因子承担，不构成战线崩坏信号。
func _nearby_ally_break_ratio(bi: Node, profile: Dictionary) -> float:
	if _entity == null or not is_instance_valid(_entity) or not _entity.has_method("get_faction"):
		return 0.0
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_allies_of"):
		return 0.0
	var radius: float = float(profile.get("retreat_mod_ally_radius", 300.0))
	var total: int = 0
	var broken: int = 0
	for ally_v in bi.get_allies_of(_entity.get_faction()):
		var ally := ally_v as Node2D
		if ally == null or not is_instance_valid(ally) or ally == _entity:
			continue
		if _entity.global_position.distance_to(ally.global_position) > radius:
			continue
		total += 1
		var dead: bool = ally.has_method("is_dead") and ally.is_dead()
		var routed: bool = false
		var ah: Node = ally.get_health() if ally.has_method("get_health") else null
		if ah != null and is_instance_valid(ah) and ah.has_method("is_routed"):
			routed = ah.is_routed()
		if dead or routed:
			broken += 1
	if total <= 0:
		return 0.0
	return float(broken) / float(total)


## 撤退调制状态只读快照（W1 · 方案 §2.6 接口缺口补齐；调试悬停/观察场消费）：
##   enabled            档案开关实测值（retreat_mod_enabled）
##   next_roll_at       下次允许掷骰的战斗时刻（节流窗口起点）
##   throttle_remaining 节流窗口余量（s，≥0；战斗时长不可用 = 0）
##   last_factors       最近评估候选因子命中项 {hp_low, morale_low, line_collapsed}
##   last_roll/last_chance/last_result  最近掷骰值/概率/是否触发（NAN = 从未评估）
## 纯查询零副作用；实体/战斗实例不可用降级安全默认（调试面板不倒逼战斗侧改结构）。
func get_retreat_mod_state() -> Dictionary:
	var profile: Dictionary = _get_behavior_profile()
	var now: float = 0.0
	if _entity != null and is_instance_valid(_entity) and _entity.has_method("get_battle_instance"):
		var bi: Node = _entity.get_battle_instance()
		if bi != null and is_instance_valid(bi) and bi.has_method("get_duration"):
			now = float(bi.get_duration())
	return {
		"enabled": bool(profile.get("retreat_mod_enabled", false)),
		"next_roll_at": _retreat_mod_next_roll_at,
		"throttle_remaining": maxf(_retreat_mod_next_roll_at - now, 0.0),
		"last_factors": _retreat_mod_last_factors.duplicate(),
		"last_roll": _retreat_mod_last_roll,
		"last_chance": _retreat_mod_last_chance,
		"last_result": _retreat_mod_last_result,
	}


## 是否祭司兵种（MERIC 路由判定，P7 批次 7b）
func _is_meric() -> bool:
	if _entity == null or not is_instance_valid(_entity) or not _entity.has_method("get_weapon"):
		return false
	var w: Node = _entity.get_weapon()
	if w == null or not is_instance_valid(w) or "weapon_type" not in w:
		return false
	return int(w.weapon_type) == ScriptBehaviorProfiles.MERIC


## IsUnderThreat 真值化（SWL Ai.IsUnderThreat 直译）：THREAT_RANGE 内存活敌人
## 数 > 0 = 被威胁。溃逃触发的前置真值（无近身威胁不溃逃，9i 配套）。
func _is_under_threat(bi: Node) -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	return _count_enemies_near(_entity.global_position, THREAT_RANGE, bi) > 0


## 公开威胁查询（血条脱战渐隐等 UI 消费）：近身有活敌 = 在战
func is_under_threat() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	var bi: Node = _entity.get_battle_instance() if _entity.has_method("get_battle_instance") else null
	return _is_under_threat(bi)


## 半径内存活敌对单位数（战斗性能优化：地图空间网格邻域查询，
## 替代对战斗敌对列表的全量线性扫描；未参战/无地图网格时回落旧全扫路径）
func _count_enemies_near(pos: Vector2, radius: float, bi: Node) -> int:
	if _entity == null or not is_instance_valid(_entity):
		return 0
	var faction: int = _entity.get_faction() if _entity.has_method("get_faction") else 0
	var map: Node = _entity.get_map() if _entity.has_method("get_map") else null
	if faction != 0 and map != null and is_instance_valid(map) and map.has_method("query_neighbors"):
		var n: int = 0
		for e in map.query_neighbors(pos, radius + 8.0):
			if e == null or not is_instance_valid(e) or e == _entity:
				continue
			if not (e is CharacterBody2D):
				continue
			if e.has_method("is_dead") and e.is_dead():
				continue
			if not e.has_method("get_faction"):
				continue
			var ef: int = e.get_faction()
			if ef == 0 or ef == faction:
				continue
			if pos.distance_to(e.global_position) <= radius:
				n += 1
		return n
	# 回落：战斗实例敌对列表全扫（旧语义，测试桩/中立目标路径）
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_enemies_of"):
		return 0
	var n2: int = 0
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if pos.distance_to(e.global_position) <= radius:
			n2 += 1
	return n2


## 9i+ 逃开后再战 + 前排试探接敌（P6 批次 7c，design §2.1.3.6 #1/#4）。
## 全部档案开关默认关 = 返回 false → 既有"原地待命"行为；姿态查询不可用降级同。
## 仅改决策取向，不触碰选目标、出手、伤害管线；手动号令执行中不生效（命令覆盖优先）。
func _try_rout_reengage(bi: Node, bi_param: Dictionary, health: Node) -> bool:
	var profile: Dictionary = _get_behavior_profile()
	var reengage_on: bool = bool(profile.get("rout_reengage_enabled", false))
	var test_on: bool = bool(profile.get("test_engage_enabled", false))
	if not reengage_on and not test_on:
		return false
	# GARRISON 维持待命（归队由锚点号令覆盖）；ROUT 战役撤离不再接敌（C3：全军撤；
	# 个别溃兵被 ROUT 撤离号令周期重发拉回，此处再战通道同样关闭）；查询不可用降级为 DEFEND（保守不压上）
	var stance: int = _query_team_stance(bi)
	if stance == TEAM_AI_STANCE_GARRISON or stance == TEAM_AI_STANCE_ROUT:
		return false
	# 仅 ATTACK/DEFEND 姿态下执行再战/试探（stance 查询失败降级 DEFEND 也允许）
	var morale_ratio: float = 1.0
	if health != null and health.has_method("get_morale_ratio"):
		morale_ratio = health.get_morale_ratio()
	# #1 逃开后再战：士气过再战线 → 重进 attack（重返战线）
	if reengage_on and morale_ratio >= float(profile.get("re_engage_morale", 0.15)):
		_state_machine.travel("attack", bi_param)
		return true
	# #4 前排怯战试探接敌：脉冲周期在"允许进 attack / 维持待命"间切换
	if test_on:
		# 手动号令执行中不生效（命令覆盖优先，spec §5.6.3.2）
		if not _ordered_behavior.is_empty():
			return false
		if bi == null or not is_instance_valid(bi) or not bi.has_method("get_nearest_enemy"):
			return false
		var enemy: Node = bi.get_nearest_enemy(_entity)
		if enemy == null or not is_instance_valid(enemy):
			return false
		var dist: float = _entity.global_position.distance_to(enemy.global_position)
		if dist > float(profile.get("test_engage_range", 480.0)):
			return false
		# 脉冲推进（时间戳法，无需在 physics_update 推进独立计时器）
		var now: float = bi.get_duration() if bi.has_method("get_duration") else 0.0
		if now >= _test_pulse_until:
			_test_pulse_active = not _test_pulse_active
			_test_pulse_until = now + (float(profile.get("test_pulse_on", 2.0)) if _test_pulse_active \
					else float(profile.get("test_pulse_off", 3.0)))
		if _test_pulse_active:
			_state_machine.travel("attack", bi_param)
			return true
	return false


## 读取当前兵种行为档案（RWR 基线+覆盖；无武器回落 SWORD 基线）
func _get_behavior_profile() -> Dictionary:
	if _entity != null and is_instance_valid(_entity) and _entity.has_method("get_weapon"):
		var w: Node = _entity.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w:
			return ScriptBehaviorProfiles.get_profile(int(w.get("weapon_type")))
	return ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)


## 掷下一次决策间隔（R1 · RWR interval 族直译：choose_enemy_time ± wait_time_variance
## 同构——主决策间隔读档案 decision_interval，± decision_variance 逐拍重掷去同步；
## 钳 MIN_DECISION_INTERVAL 下限防决策风暴）。
func _roll_decision_interval() -> float:
	var p: Dictionary = _get_behavior_profile()
	var base: float = float(p.get("decision_interval", DECISION_INTERVAL))
	var variance: float = maxf(float(p.get("decision_variance", 0.0)), 0.0)
	return maxf(base + randf_range(-variance, variance), MIN_DECISION_INTERVAL)


# ─────────────────── W2 决策冷却错峰（WorldBox M4/Top2）───────────────────
# 语义：所有"下次到期"记**世界时刻**而非剩余秒数（读档零换算成本）；
# 装配时预置 now + interval×(1 - ratio×rand%) 的假偏移 = "上次触发发生在随机
# 过去时刻"，成批出生/读档的群体决策天然错峰（本项目痛点是兵营爆兵齐套尖峰）。

## 世界时刻读取（绝对时刻语义唯一时间源）：注入时钟优先（单测确定性），
## 否则用本 AI 的世界时钟（physics_update 按 delta 累加，暂停/hitstop 同步冻结
## ——不用 Time.get_ticks_msec() 实时钟，避免暂停/hitstop 期时钟空转导致恢复后
## 多触发一拍，破坏"关开关与旧累加器逐位等价"）
func _now() -> float:
	if clock_override.is_valid():
		return float(clock_override.call())
	return _world_time


## 出生错峰开关（档案；缺载/未配置回落代码默认 false = 零回归）
func _jitter_enabled() -> bool:
	return bool(_get_behavior_profile().get("spawn_jitter_enabled", false))


## 假偏移比例（0~1 钳制；WorldBox 真值 0.5 = rand(0, 0.5×cd)）
func _spawn_jitter_ratio() -> float:
	return clampf(float(_get_behavior_profile().get("spawn_jitter_ratio", 0.5)), 0.0, 1.0)


## 域级探测失败冷却开关（档案；默认 false = 失败下一拍即重试 = 既有语义）
func _probe_fail_cooldown_enabled() -> bool:
	return bool(_get_behavior_profile().get("probe_fail_cooldown_enabled", false))


## 解析错峰 RNG 种子：显式注入优先（单测/读档可复现），否则按实体实例 id 派生
## （成批出生各实例 id 不同 = 真错峰；实体不可用回落常量种子）
func _resolve_jitter_seed() -> int:
	if jitter_seed_override >= 0:
		return jitter_seed_override
	if _entity != null and is_instance_valid(_entity):
		return int(_entity.get_instance_id())
	return SPAWN_JITTER_DEFAULT_SEED


## 首次到期时长 = interval（关）/ interval×(1 - ratio×rand%)（开）——
## 等价"上次触发发生在过去 rand(0, ratio×interval) 秒处"。
## 每次调用抽一次随机数：逐通道各抽 = 通道间独立错峰（通道内一次装配只抽一次）
func _first_interval(interval: float) -> float:
	if not _jitter_enabled():
		return interval
	return interval * (1.0 - _spawn_jitter_ratio() * _jitter_rng.randf())


## 装配时钟族：重掷当前决策间隔 + 预置主节拍与各域级通道的首次到期世界时刻。
## 域级通道在错峰关时置 -1.0e9（立即到期，同 _retreat_mod_next_roll_at 惯例）。
func _init_decision_timing(now: float) -> void:
	_timing_armed = true
	_jitter_rng.seed = _resolve_jitter_seed()
	_decision_interval = _roll_decision_interval()
	_next_decision_at = now + _first_interval(_decision_interval)
	_domain_next_at = {}
	var jitter: bool = _jitter_enabled()
	for ch in DOMAIN_CHANNELS:
		var iv: float = _domain_interval(ch)
		if jitter:
			_domain_next_at[ch] = now + _first_interval(iv)
		else:
			_domain_next_at[ch] = now - 1.0e9


## 出生/读档错峰入口（装配完成、读档还原、首次启用时调用）：幂等——重复调用
## 即重新掷一次假偏移（读档场景 = 按当前时刻重新错峰）。测试可显式调用 +
## 注入 clock_override/jitter_seed_override 做确定性断言。
func apply_spawn_jitter() -> void:
	_init_decision_timing(_now())


# ── WB2 读档序列化（AI 时钟族）──────────────────────────────────────────────
# 语义：导出量一律记"相对当前世界时钟的剩余时长"——实体读档重建后本地时钟从 0
# 重新起算，剩余量回填即恢复原相位（错峰离散度不丢，也不随存档时间基准漂移）。
# 导入只回填、不重掷：错峰 RNG 不再抽一次（重掷 = 错峰双重随机，反而打乱相位）。

## 决策时钟族导出（读档序列化出口）：主节拍与域级通道的剩余时长 + 当前间隔 +
## 错峰种子（字符串保精度：实体实例 id 可能超出 JSON 数值的精确整数范围）。
## 未装配/无到期时刻给 -1.0 哨兵，导入侧跳过。
func export_timing_state() -> Dictionary:
	var now: float = _now()
	var dom: Dictionary = {}
	for ch in DOMAIN_CHANNELS:
		dom[ch] = float(_domain_next_at.get(ch, now - 1.0e9)) - now
	return {
		"version": TIMING_STATE_VERSION,
		"armed": _timing_armed,
		"decision_remaining": (_next_decision_at - now) if is_finite(_next_decision_at) else -1.0,
		"decision_interval": _decision_interval,
		"jitter_seed": str(_resolve_jitter_seed()),
		"domain_remaining": dom,
	}


## 决策时钟族导入（读档序列化入口）：按剩余时长回填到期时刻，**不重掷错峰**；
## 错峰种子回填注入位（后续重新装配可复现同一偏移）。
## 老存档（无该字段）/字段缺失/类型不符 → 保持调用方装配语义（_ready 的
## apply_spawn_jitter 结果），不报错。
func import_timing_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	var now: float = _now()
	if bool(d.get("armed", false)) and d.has("decision_remaining"):
		var rem: float = _safe_float(d["decision_remaining"])
		if is_finite(rem):
			_timing_armed = true
			_next_decision_at = now + rem
	var iv: float = _safe_float(d.get("decision_interval"))
	if is_finite(iv) and iv > 0.0:
		_decision_interval = iv
	var seed: int = _safe_seed(d.get("jitter_seed"))
	if seed >= 0:
		jitter_seed_override = seed
	var dom: Variant = d.get("domain_remaining")
	if dom is Dictionary:
		var dom_d: Dictionary = dom
		for ch in DOMAIN_CHANNELS:
			if not dom_d.has(ch):
				continue
			var r: float = _safe_float(dom_d[ch])
			if is_finite(r):
				_domain_next_at[ch] = now + r


## 存档数值安全读取（JSON 往返：int/float 均可；类型不符/缺失 → NAN，调用方跳过）
static func _safe_float(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	return NAN


## 存档错峰种子安全读取（字符串优先保精度；非法值 → -1 表示不注入）
static func _safe_seed(v: Variant) -> int:
	if v is String:
		var s: String = v
		return int(s) if s.is_valid_int() else -1
	if v is float or v is int:
		return int(v)
	return -1


## 决策时钟推进（纯时钟，不决策）：时钟未装配则先装配（懒装配 = 与旧"首次
## physics_update 起累计"语义一致）；到点则记一拍、重掷间隔、下次到期 =
## 当前时刻 + 新间隔，返回 true 由调用方执行 _make_decision。
## _make_decision 不读 _decision_interval（重掷先于决策 = 旧"决策后重掷"等价）
func _advance_decision_clock(now: float) -> bool:
	if not _timing_armed:
		_init_decision_timing(now)
	if now + DUE_EPSILON < _next_decision_at:
		return false
	_decision_beats += 1
	_decision_interval = _roll_decision_interval()
	_next_decision_at = now + _decision_interval
	return true


## 域级通道间隔（s，档案键经 DOMAIN_CHANNELS 映射；钳 MIN_DECISION_INTERVAL 防风暴）
func _domain_interval(ch: String) -> float:
	var key: String = str(DOMAIN_CHANNELS.get(ch, ""))
	if key.is_empty():
		return DECISION_INTERVAL
	var p: Dictionary = _get_behavior_profile()
	return maxf(float(p.get(key, DECISION_INTERVAL)), MIN_DECISION_INTERVAL)


## 域级探测是否到期（可探测）。两开关全关（默认）= 恒到期 = 逐拍探测（既有语义）；
## 错峰开 = 假偏移生效（首次探测错峰到 now+偏移，等价"上次探测在随机过去时刻"）；
## 失败冷却开 = 探测失败后一个间隔内不再重探。
func _probe_domain_due(ch: String) -> bool:
	if not _probe_fail_cooldown_enabled() and not _jitter_enabled():
		return true
	return _now() + DUE_EPSILON >= float(_domain_next_at.get(ch, -1.0e9))


## 记一次域级探测失败：失败冷却开 → 入该通道一个间隔的短冷却（WorldBox M6
## "action_check_launch 失败也入冷却，防反复探测昂贵条件"）；关 → 不记（下一拍即重试）。
## 只冷却失败分支，成功路径的节拍不受影响。
func _note_probe_failure(ch: String) -> void:
	if not _probe_fail_cooldown_enabled():
		return
	_domain_next_at[ch] = _now() + _domain_interval(ch)


## 决策时钟状态只读快照（W2 调试面板/单测出口）：主节拍 + 各域级通道的下次
## 到期世界时刻/当前间隔/是否已错峰。纯查询零副作用，档案缺载降级安全默认。
func get_decision_timing_state() -> Dictionary:
	var now: float = _now()
	var gate_enabled: bool = _probe_fail_cooldown_enabled() or _jitter_enabled()
	var domains: Dictionary = {}
	for ch in DOMAIN_CHANNELS:
		var next_at: float = float(_domain_next_at.get(ch, -1.0e9))
		domains[ch] = {
			"next_at": next_at,
			"interval": _domain_interval(ch),
			"gate_enabled": gate_enabled,
			"cooling_down": gate_enabled and now + DUE_EPSILON < next_at,
		}
	return {
		"now": now,
		"jitter_enabled": _jitter_enabled(),
		"jitter_ratio": _spawn_jitter_ratio(),
		"jitter_seed": _resolve_jitter_seed(),
		"probe_fail_cooldown_enabled": _probe_fail_cooldown_enabled(),
		"decision": {
			"next_at": _next_decision_at,
			"interval": _decision_interval,
			"beats": _decision_beats,
			"jittered": _jitter_enabled(),
		},
		"domains": domains,
	}


## 查询所属阵营的 TeamAi 姿态（duck 调用 + has_method 防御；未注册/查询不可用降级 DEFEND）
func _query_team_stance(bi: Node) -> int:
	if _entity == null or not is_instance_valid(_entity) or not _entity.has_method("get_faction"):
		return TEAM_AI_STANCE_DEFEND
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_team_ai"):
		return TEAM_AI_STANCE_DEFEND
	var tai: Variant = bi.get_team_ai(_entity.get_faction())
	if tai == null or not is_instance_valid(tai) or not tai.has_method("get_stance"):
		return TEAM_AI_STANCE_DEFEND
	return int(tai.get_stance())


## 状态调制检测（反编译参考实装 E）：低血 / 溃逃 / 被围 / 背墙。
## 返回 {"low_hp", "routing", "surrounded", "backed_to_wall"} 布尔集。
func _compute_state_modifiers(bi: Node, health: Node) -> Dictionary:
	var mods := {
		"low_hp": false,
		"routing": false,
		"surrounded": false,
		"backed_to_wall": false,
	}
	if health != null:
		mods["low_hp"] = health.has_method("get_hp_ratio") and health.get_hp_ratio() < RAGE_LOW_HP
		mods["routing"] = health.has_method("is_routed") and health.is_routed()
	# 被围：SURROUND_RANGE 内敌对单位数 >= SURROUND_MIN（空间网格邻域查询）
	if bi != null:
		mods["surrounded"] = _count_enemies_near(
				_entity.global_position, SURROUND_RANGE, bi) >= SURROUND_MIN
	# 背墙：身后（朝向反方向）WALL_LOOKBACK 距离内有掩体
	if bi != null and bi.has_method("get_cover"):
		# CoverSystem 是 RefCounted（纯逻辑），注解用 Variant 防类型不匹配报错
		var cover = bi.get_cover()
		if cover != null and cover.has_method("is_in_cover"):
			var facing: int = _entity.get_facing() if _entity.has_method("get_facing") else 1
			var back_pos: Vector2 = _entity.global_position - Vector2(facing, 0) * WALL_LOOKBACK
			mods["backed_to_wall"] = cover.is_in_cover(back_pos)
	return mods


## 狂暴判定（反编译参考实装 E，参考传奇 RageSystem/DesperationTriggered）：
##   - 溃逃中 -> 不狂暴（走溃逃）
##   - 被围 + 背墙 -> 背水一战，强制狂暴（不溃逃）
##   - 低血且士气高于 RAGE_MORALE_THRESHOLD -> 狂暴反击
##   - 其余 -> 不狂暴（走现有 seek_cover / attack 决策）
func _should_rage(mods: Dictionary, health: Node) -> bool:
	if mods.get("routing", false):
		return false
	if mods.get("surrounded", false) and mods.get("backed_to_wall", false):
		return true
	if mods.get("low_hp", false):
		var morale_ratio: float = 1.0
		if health != null and health.has_method("get_morale_ratio"):
			morale_ratio = health.get_morale_ratio()
		return morale_ratio > RAGE_MORALE_THRESHOLD
	return false


## 尝试 job 域探测组（W2 域级节流出口）：派工探测失败再试采集探测，两者皆空才
## 记一次域级失败（关 = 逐拍探测，等价既有连续两次探测调用序列）。
## 返回 true 表示已切入 work/haul/harvest 行为。
func _try_job_probes() -> bool:
	if not _probe_domain_due("job"):
		return false
	if _try_work():
		return true
	if _try_harvest():
		return true
	_note_probe_failure("job")
	return false


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


## 尝试采集决策（小镇生活批次 2）：有职业的村民在无建造派工/战斗/跟随/号令时
## 进 harvest 行为自主劳作（寻位→移动→劳作→产出入账，循环见 BehaviorHarvest）。
## 职责过滤：队伍职责不含 WORK_FORAGE 的编队单位不采集（如战斗班被征用后离岗）。
## 职业档案由行为 enter 时经 TownLifeAPI 自查（本层只判"有职业"）。
## 劳作节律（批次 3 [提案/待定] 7~19 时）：休息时段不进采集——在岗村民由
## 行为层 update 收工，本层防"enter 即收工"的 travel 抖动。
## 返回 true 表示已切换到 harvest。
func _try_harvest() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	# 编队职责过滤（未编队/测试直生实体视为允许，同 _can_work 口径）
	if not _can_work(WorkTypeForage):
		return false
	if not _entity.has_method("get_profession"):
		return false
	if String(_entity.get_profession()).is_empty():
		return false  # 待业（无职业不劳作）
	# 节律过滤：休息时段（劳作由行为层收尾，这里不再新进）
	if not TownLifeAPI.is_work_time():
		return false
	# 已在采集且未完成 → 保持（决策节拍内不重入）
	var cur: String = _state_machine.get_current_behavior_name()
	if cur == "harvest" and not _state_machine.is_current_finished():
		return true
	_state_machine.travel("harvest")
	return true


## 村民 wander 参数（批次 4）：锚定村中心（地图 town_center_world_x），
## 防长时间闲逛累积漂离；地图引用未注入/无该属性的桩环境返回空参数
##（wander 原语义，零扰动）。
func _villager_wander_params() -> Dictionary:
	if _entity == null or not is_instance_valid(_entity):
		return {}
	if not _entity.has_method("get_map_reference"):
		return {}
	var mref: Node2D = _entity.get_map_reference()
	if mref == null or not is_instance_valid(mref) or not ("town_center_world_x" in mref):
		return {}
	return {"anchor_x": float(mref.town_center_world_x)}


## 是否村民（wander 作用域过滤，批次 4 语义改造）：实体带村民身份标志
##（is_villager，spawn 时写入）且**不在编队**。与职业解耦——待业村民与
## 被征用离岗的村民（职业都是空串）仍算村民可闲逛；编队中的单位（含被
## 征用的前村民）保持战斗待命语义不 wander；无标志实体（战斗/敌方/测试
## 裸桩）不判村民。批次 3 的"职业非空"判据在引入待业人口后失效（待业
## 与征用两类空职业实体的行为语义相反），故改身份标志判定。
## "有无职业"由 _try_harvest 单独判定（待业不劳作）。
func _is_villager() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _entity.has_method("get_profession"):
		return false
	if not bool(_entity.get("is_villager")):
		return false
	# 编队中不闲逛（战斗待命语义；FormationSystem 未注入 = 未编队）
	if _entity.has_method("get_formation_system"):
		var fs: Node = _entity.get_formation_system()
		if fs != null and fs.has_method("is_in_squad") and fs.is_in_squad(_entity):
			return false
	return true


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


## 获取当前命令参数（号令来源鉴别用：如编队动态跟队的 follow_order 标记，
## FormationSystem 据此只回收/覆盖自己下的号令，不碰玩家号令）。
func get_ordered_params() -> Dictionary:
	return _ordered_params


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


# ─────────────────────────────── 压制禁令（A6 · C9 定时锁死）────────────────────────────────

## 是否被压制：查询状态效果组件 SUPPRESSED 态（duck；组件缺失/压制未启用
## 返回 false = 零回归）。压制=短时行为禁令（惩罚来自模拟因果，非数值折扣；
## CoH pinned-reaction-plan isInterruptablePlan=false 直译）。
func _is_suppressed() -> bool:
	var se: Node = _status_effects_of()
	return se != null and se.has_method("has_suppressed") and bool(se.has_suppressed())


## 压制期强制短行为（压制蹲伏/停滞）：原地停步 + 落 idle，每决策拍重申
## （禁令期任何 travel 下一拍都被拉回——"不可被常规决策打断"）。
## 受击反馈动画/被推挤走物理与表现层，不受禁令影响。号令挂起不清除：
## 压制结束后命令覆盖段检测 cur != ordered 自动续行。
func _suppressed_stall() -> void:
	if _entity != null and is_instance_valid(_entity) and _entity.has_method("ai_stop"):
		_entity.ai_stop()
	if _state_machine != null and _state_machine.get_current_behavior_name() != "idle":
		_state_machine.travel("idle")


## 所属实体状态效果组件（duck；缺失返回 null——测试桩/未装配环境零回归）。
func _status_effects_of() -> Node:
	if _entity == null or not is_instance_valid(_entity):
		return null
	if not _entity.has_method("get_status_effects"):
		return null
	var se: Node = _entity.get_status_effects()
	if se == null or not is_instance_valid(se):
		return null
	return se
