class_name AIController
extends Node
## AI 决策大脑（编排器）-- 持有行为状态机，根据三层命令系统决策行为切换。
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
##
## 编排器定位：本文件持有全部运行时状态与决策主流程，重逻辑已下沉子域助手
##（状态留本类，宿主保留壳转发，测试直戳面/公共 API 不变）：
##   - W2 决策时钟族（世界时刻解析/出生错峰/域级探测冷却/读档序列化）
##     → ai_decision_clock.gd（ScriptDecisionClock，_init 装配）
##   - 行为注册样板（11 段行为构建工厂）→ behavior_registry.gd（纯 static）

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptDecisionClock := preload("res://modules/units/scripts/ai/ai_decision_clock.gd")
const ScriptBehaviorRegistry := preload("res://modules/units/scripts/ai/behavior_registry.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
# （W2 决策时钟族 6 常量随逻辑迁 ai_decision_clock.gd，经 ScriptDecisionClock 取用）
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
## 避战还击的"近战范围"上限（px，诊断 B2 带打带跑）：取最长近战兵种射程
## 矛 200——敌人贴进此范围内，避战单位不再一味后撤而是就地还击；
## 超出仍走避战脱离。待实测校准
const COUNTER_RANGE: float = 200.0
## 打通态脱离距离（px）【提案/待定·待实测校准】：拦路者跑出此距离视为"已脱离"
##（不再构成拦路——风筝敌人越拉越远即放弃追打恢复赶路；再拦再触发）
const BREACH_DROP_DIST: float = 320.0
## 被围所需敌对单位数
const SURROUND_MIN: int = 2
## 背墙判定：身后此距离内有掩体视为背墙
const WALL_LOOKBACK: float = 80.0
## 低血狂暴判定阈值（hp_ratio 低于此值视为低血）
const RAGE_LOW_HP: float = 0.3
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
## W2 决策时钟族助手（子域索引见头注释；状态全部留本类，助手经回引读写）
var _decision_clock: RefCounted = null
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
var _decision_interval: float = ScriptDecisionClock.DECISION_INTERVAL
## 决策时钟是否已装配（首次装配前不消费时钟；physics_update 内兜底懒装配）
var _timing_armed: bool = false
## 已触发的决策拍数（W2 观测面：get_decision_timing_state 消费，拨针单测可断言拍数）
var _decision_beats: int = 0
## 各域级通道的下次到期世界时刻（channel -> 时刻，s；W2 假偏移/失败冷却落点）
var _domain_next_at: Dictionary = {}
## W2 出生错峰专用 RNG（与全局 randf 隔离：种子可注入 = 单测确定性；
## 装配置一次种子，逐通道各抽一次 = 通道间独立错峰）
var _jitter_rng := RandomNumberGenerator.new()
## 命运骰 RNG（决策域概率掷骰统一出口：村民闲逛/看门狗推力方向——
## 与全局 randf 隔离，P4 回放「每单位可注入种子」全覆盖收口；种子按实体
## 实例 id 派生（同 _resolve_jitter_seed 惯例），测试重掷 _dice_rng.seed 可复现）
var _dice_rng := RandomNumberGenerator.new()
var _dice_seeded: bool = false
## 上一帧是否被附身（用于检测附身状态变化）
var _was_possessed: bool = false
# ── 9h 卡死看门狗（O(1)：只记上次采样位置 + 累计计时，不扫描不查询邻居）──
## 有移动意图（实体速度 > 档案阈值）但窗口内净位移 ≈ 0 → 强制重决策。
var _wd_timer: float = 0.0
## 窗口起点位置（进入有意图态时采样；窗口到期时与此比较算净位移）
var _wd_last_pos: Vector2 = Vector2.ZERO
## 分离推力截止时刻（_world_time 时钟；推力期内每拍覆盖行为层移动意图）
var _wd_nudge_until: float = -1.0e9
## 分离推力方向（触发时随机掷一次，短窗内恒定）
var _wd_nudge_dir: Vector2 = Vector2.ZERO
## 撤离行为态（retreat 行为 enter/exit 置位清位，"谁执行谁置位"单一真相源；
## is_disengaging() 对外查询）。**自动避战已根除**（创始人裁决）：本态只由
## 命令撤离（RETREAT 号令/TeamAi ROUT 战役撤仗）进入，单位不再自发脱战
var _disengaging: bool = false
## 遇阻接战"打通"态（创始人口径：任务路上被敌拦住且无法简单绕过 → 攻击路径上
## 的敌人）：由 behavior_move 请求置位（request_breach_engagement），拦路者作为
## 临时战斗目标。**原号令不清空不降级**——本态是号令的临时插叙，拦路者死亡/
## 脱离后由 _breach_tick 清态，命令覆盖段自动续行原号令（恢复的目标点仍是原
## 号令目标）。
var _breach_target: Node = null

# ─────────────────────────────── 命令覆盖（§8.3 战术号令）────────────────────────────────
## 当前下达的命令行为名（空=无命令，由 AI 自主决策）
var _ordered_behavior: String = ""
## 命令参数
var _ordered_params: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 子域助手装配（裸 new() 不进树也立即生效——test_ai_timing_save 依赖）
func _init() -> void:
	_decision_clock = ScriptDecisionClock.new(self)


func _ready() -> void:
	_entity = get_parent() as CharacterBody2D
	if _entity == null:
		push_error("[AIController] 父节点非 CharacterBody2D，AI 无法工作")
		return
	_setup_state_machine()
	# W2 出生错峰：装配完成即预置首次决策/域级到期时刻（关=装配后 interval，
	# 与旧累加器语义一致；开=预置假偏移防成批出生齐套，见 apply_spawn_jitter）
	apply_spawn_jitter()


## 创建状态机并注册基础行为（11 段注册样板下沉 behavior_registry.gd 纯 static
## 工厂；此处留壳：build → add_child 入树 → 初态 travel，顺序与拆分前一致。
## 测试直调面：不进树夹具经 _entity 直写 + 本方法手工装配）
func _setup_state_machine() -> void:
	_state_machine = ScriptBehaviorRegistry.build(_entity)
	add_child(_state_machine)
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
	if _advance_decision_clock(_decision_clock._now()):
		_make_decision()
	# 9h 卡死看门狗（决策之后跑：触发时的分离推力覆盖行为层本拍移动意图）
	_watchdog_tick(delta)


# ─────────────────────────────── 决策逻辑 ────────────────────────────────

## P0 决策：命令覆盖 > 战斗（参战时）> work（有派工）> idle/wander 循环。
## 命令覆盖：tactical_orders 下达的号令优先于自主决策。
## 职责过滤：编队中的单位只能做队伍职责范围内的行为（见 _can_work / _can_combat）。
## 优先级（裁决【删溃逃、立避战】落定）：压制避战 > 命令覆盖 > 自主决策。
##   - 被压制 → 强制避战（RA 压制式脱离：脱离接火优先于一切，含号令——但号令
##     **挂起不清除**，压制结束自动续行，玩家意图保留）；
##   - 单位级"强制溃逃"链已删除（溃逃退役）：劣势/被压时脱离接火走 C6 概率
##     调制（血量/周边友军两因子），是战术行为不是失控逃跑。
func _make_decision() -> void:
	# 压制避战（RA 压制式脱离）：被压制 → 立即脱离接火（优先找掩体，无掩体走
	# fallback 短距后撤）；号令挂起不清除，压制结束由命令覆盖段自动续行
	if _is_suppressed():
		# 压制 = 纯行为禁令（创始人裁决根除避战）：单位原地停滞不追不打
		#（行为层压制消费段执行），**永不脱离接火**——被压单位站桩吃伤害，
		# 惩罚来自模拟因果；守位者/普通兵同款，无任何逃离通道。
		# 命令撤离例外（既有裁决「命令撤离不受压制打断」的启动侧）：挂起中的
		# RETREAT 号令放行命令覆盖段立即执行撤离——压制拦自主行为，不拦命令
		# 路径撤离（TeamAi ROUT 撤仗在箭雨下也要走得了）
		if _ordered_behavior != "retreat":
			return
	# 0. 遇阻接战维护（打通态）：拦路者仍有效 → 持续锁定攻击（号令挂起不清不降级；
	# 被打断后经此重入，如压制解除）。击杀/脱离 → 清态，落回下方正常决策
	#（有号令走命令覆盖自动续行原 move，恢复目标 = 原号令目标）
	if _breach_tick():
		return
	# 0.5 命令覆盖（最高优先级）
	if not _ordered_behavior.is_empty():
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
		if _is_villager() and _dice() < villager_wander_probability:
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


# ─────────────────────────── 9h 卡死看门狗 ───────────────────────────

## 卡死看门狗（O(1)：只记上次采样位置 + 累计计时，不扫描邻居/列表——逐单位每拍
## 调用零额外分配）。判定 = 有移动意图（实体速度超阈值）但窗口内净位移低于下限
## （对齐缺陷表 9h"全员卡死"：意图在跑、实际钉死——典型于互相对穿卡位/分离力
## 对冲）。触发动作：战斗中重进 attack（enter 清目标/持瞄状态 → 下一拍重选目标 =
## "清当前目标/换目标"）+ 一次短分离推力（随机方向覆盖行为层意图，行为下一拍
## 收回控制权）；号令行军等非战斗行为只推力不清令（号令是玩家意图不归看门狗撤）。
## 无意图（站桩输出/压制/硬直/待命）即清零重计——不误伤合法静止。
func _watchdog_tick(delta: float) -> void:
	var profile: Dictionary = _get_behavior_profile()
	if not bool(profile.get("stuck_watchdog_enabled", true)):
		return
	# 分离推力期内先覆盖移动意图（本拍行为层已跑完，这里最后写=生效）
	if _world_time < _wd_nudge_until:
		if _entity.has_method("ai_move"):
			_entity.ai_move(_wd_nudge_dir, false)
	var pos: Vector2 = _entity.global_position
	var intent_min: float = maxf(float(profile.get("stuck_watchdog_intent_speed", 10.0)), 0.1)
	if _entity.velocity.length_squared() < intent_min * intent_min:
		_wd_timer = 0.0
		_wd_last_pos = pos
		return
	if _wd_timer <= 0.0:
		_wd_last_pos = pos
	_wd_timer += delta
	if _wd_timer < maxf(float(profile.get("stuck_watchdog_window", 2.0)), 0.1):
		return
	_wd_timer = 0.0
	var drift: float = pos.distance_to(_wd_last_pos)
	_wd_last_pos = pos
	if drift >= float(profile.get("stuck_watchdog_min_drift", 12.0)):
		return  # 窗口内确实挪动了：不算卡死
	_stuck_break(profile, pos)


## 卡死触发处置：换目标（战斗中重进 attack）+ 分离推力 + 可关调试日志。
func _stuck_break(profile: Dictionary, pos: Vector2) -> void:
	_wd_nudge_dir = Vector2(_dice_range(-1.0, 1.0), _dice_range(-1.0, 1.0)).normalized()
	_wd_nudge_until = _world_time + 0.25
	if _state_machine != null and _state_machine.get_current_behavior_name() == "attack":
		# 打通态卡死：重进 attack 保留 forced_target（否则 enter 清目标后自由选敌，
		# 拦路者插叙失效）；自由战斗卡死维持原样（enter 清目标 = 换目标）
		var p: Dictionary = {"forced_target": _breach_target} if is_breach_engaged() else {}
		_state_machine.travel("attack", p)  # enter 清 _target/_aim → 下一拍重选目标
	if bool(profile.get("stuck_watchdog_log", true)):
		var behavior: String = _state_machine.get_current_behavior_name() \
				if _state_machine != null else "?"
		print("[AIController] 卡死看门狗触发: pos=%v 行为=%s 换目标+分离推力" % [pos, behavior])



## 尝试战斗决策。当 entity 参战（有激活的 battle_instance）时返回 true 并切换到战斗行为。
## 决策优先级：C6 劣势掷骰 -> 避战；重伤且附近有掩体 -> seek_cover；默认 -> attack。
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
	# 状态调制（反编译参考实装 E）：低血狂暴 / 被围背墙背水一战
	var mods: Dictionary = _compute_state_modifiers(bi, health)
	if _should_rage(mods):
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
	var base: float = float(p.get("decision_interval", ScriptDecisionClock.DECISION_INTERVAL))
	var variance: float = maxf(float(p.get("decision_variance", 0.0)), 0.0)
	# 间隔方差掷骰走 _jitter_rng（决策时钟族专用 RNG——种子随装配注入，单测锁
	# 种子可复现间隔序列；旧全局 randf 是确定性收口的漏网点）
	return maxf(base + _jitter_rng.randf_range(-variance, variance),
			ScriptDecisionClock.MIN_DECISION_INTERVAL)


## 命运骰掷点（决策域概率：闲逛/推力方向；首掷按实体实例 id 派生种子）
func _dice() -> float:
	_seed_dice_once()
	return _dice_rng.randf()


func _dice_range(from: float, to: float) -> float:
	_seed_dice_once()
	return _dice_rng.randf_range(from, to)


func _seed_dice_once() -> void:
	if _dice_seeded:
		return
	_dice_seeded = true
	_dice_rng.seed = int(_entity.get_instance_id()) \
			if _entity != null and is_instance_valid(_entity) else 20261006


# ─────────────────── W2 决策时钟族壳转发（逻辑在 ai_decision_clock.gd）───────────────────
# 语义（WorldBox M4/Top2 错峰/域级冷却/读档序列化）与 6 常量见助手文件；
# 此处仅一行转发，保住测试与 save_handler 的直调面。

## 出生/读档错峰入口（装配完成、读档还原、首次启用时调用）：幂等——重复调用
## 即重新掷一次假偏移（读档场景 = 按当前时刻重新错峰）。测试可显式调用 +
## 注入 clock_override/jitter_seed_override 做确定性断言。
func apply_spawn_jitter() -> void:
	_decision_clock.apply_spawn_jitter()


## 决策时钟族导出（读档序列化出口）：主节拍与域级通道的剩余时长 + 当前间隔 +
## 错峰种子（字符串保精度）；未装配/无到期时刻给 -1.0 哨兵，导入侧跳过。
func export_timing_state() -> Dictionary:
	return _decision_clock.export_timing_state()


## 决策时钟族导入（读档序列化入口）：按剩余时长回填到期时刻，**不重掷错峰**；
## 老存档/字段缺失/类型不符 → 保持装配语义不报错。
func import_timing_state(d: Dictionary) -> void:
	_decision_clock.import_timing_state(d)


## 决策时钟推进（纯时钟，不决策）：时钟未装配则先装配（懒装配）；到点则记一拍、
## 重掷间隔、下次到期 = 当前时刻 + 新间隔，返回 true 由调用方执行 _make_decision。
func _advance_decision_clock(now: float) -> bool:
	return _decision_clock._advance_decision_clock(now)


## 域级探测是否到期（可探测）。两开关全关（默认）= 恒到期 = 逐拍探测（既有语义）。
func _probe_domain_due(ch: String) -> bool:
	return _decision_clock._probe_domain_due(ch)


## 记一次域级探测失败：失败冷却开 → 入该通道一个间隔的短冷却；关 → 不记。
func _note_probe_failure(ch: String) -> void:
	_decision_clock._note_probe_failure(ch)


## 决策时钟状态只读快照（W2 调试面板/单测出口）：主节拍 + 各域级通道的下次
## 到期世界时刻/当前间隔/是否已错峰。纯查询零副作用，档案缺载降级安全默认。
func get_decision_timing_state() -> Dictionary:
	return _decision_clock.get_decision_timing_state()


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


## 状态调制检测（反编译参考实装 E）：低血 / 避战 / 被围 / 背墙。
## 返回 {"low_hp", "disengaging", "surrounded", "backed_to_wall"} 布尔集。
func _compute_state_modifiers(bi: Node, health: Node) -> Dictionary:
	var mods := {
		"low_hp": false,
		"disengaging": false,
		"surrounded": false,
		"backed_to_wall": false,
	}
	if health != null:
		mods["low_hp"] = health.has_method("get_hp_ratio") and health.get_hp_ratio() < RAGE_LOW_HP
	# 避战中（裁决：溃逃退役后的行为态）不狂暴——脱离接火的单位不背水一战
	mods["disengaging"] = _disengaging
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
##   - 避战中 -> 不狂暴（脱离接火的单位不背水一战）
##   - 被围 + 背墙 -> 背水一战，强制狂暴
##   - 低血 -> 狂暴反击
##   - 其余 -> 不狂暴（走现有 seek_cover / attack 决策）
func _should_rage(mods: Dictionary) -> bool:
	if mods.get("disengaging", false):
		return false
	if mods.get("surrounded", false) and mods.get("backed_to_wall", false):
		return true
	return mods.get("low_hp", false)


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

## 是否避战中（裁决【删溃逃、立避战】的行为态查询口）：由 behavior_retreat
## enter/exit 置位清位。消费面：UI 状态角标/友军战线崩坏比例/狂暴抑制等
## "这个单位现在在不在脱离接火"的询问；由避战行为置位。
func is_disengaging() -> bool:
	return _disengaging


## 避战行为态置位/清位（behavior_retreat 专用；外部勿调——状态由执行行为拥有）
func set_disengaging(v: bool) -> void:
	_disengaging = v


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
	if OS.get_environment("STICK_TRACE_ORDER") == "1":
		var tgt = params.get("target", "—")
		print("[OrderTrace] iid=%d %s target=%s follow=%s f=%d"
				% [get_instance_id() % 10000, behavior_name, tgt,
						params.get("follow_order", false), Engine.get_process_frames()])
	# 守位者号令守卫（指挥官/阵地护卫）：守位者不接推进/撤离类号令——留守本方
	# 阵地，只做被近身自卫（行为层 LEASH 内迎击），任何来路的号令都拉不走。
	# idle（HOLD_POSITION）放行——留守语义兼容。
	if _holds_post() and behavior_name in ["move", "retreat", "seek_cover"]:
		return
	_ordered_behavior = behavior_name
	_ordered_params = params
	_breach_target = null  # 新号令显式接管：打通插叙作废（粘性只保原号令）
	if _state_machine != null:
		_state_machine.travel(behavior_name, params)


## 清除命令：恢复 AI 自主决策。
func clear_order() -> void:
	_ordered_behavior = ""
	_ordered_params = {}
	_breach_target = null


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

# （_is_routing 已随裁决【删溃逃】删除：溃逃布尔态退役；
#   撤离行为态走 is_disengaging()——由 behavior_retreat 置位。
#   自动避战链（C6 掷骰/压制脱离/还击窗）已随创始人根除裁决整体删除）


# ─────────────────────────────── 压制禁令（纯行为禁令：不追不打，永不脱战）────────────────────────────────

## 是否守位者（守位行为面 duck；多个消费点共用：压制豁免/C6 豁免/号令守卫）。
## 指挥官（rank>=3）与阵地护卫（guard_post）同款：留守+被近身自卫，不脱位。
func _holds_post() -> bool:
	return _entity != null and is_instance_valid(_entity) \
			and _entity.has_method("holds_post") and _entity.holds_post()


## 是否被压制：查询状态效果组件 SUPPRESSED 态（duck；组件缺失/压制未启用
## 返回 false = 零回归）。
func _is_suppressed() -> bool:
	var se: Node = _status_effects_of()
	return se != null and se.has_method("has_suppressed") and bool(se.has_suppressed())




# ─────────────────── 遇阻接战（打通态：任务路上攻击拦路者）───────────────────

## 是否处于打通接战态（观测面：调试/测试消费）。拦路者已死亡/失效 = 不在态。
func is_breach_engaged() -> bool:
	if _breach_target == null:
		return false
	return is_instance_valid(_breach_target) \
			and not (_breach_target.has_method("is_dead") and _breach_target.is_dead())


## 打通态维护拍（决策首位，压制分支之后）：拦路者有效（存活 + 未跑出脱离距离）
## → 保持/重入 attack（forced_target 锁定拦路者）；失效 → 清态返回 false，交还
## 正常决策流（命令覆盖段自动续行原号令）。返回 true = 本拍被打通态占用。
func _breach_tick() -> bool:
	if _breach_target == null:
		return false
	var valid: bool = is_instance_valid(_breach_target) \
			and not (_breach_target.has_method("is_dead") and _breach_target.is_dead())
	if valid and _entity != null and is_instance_valid(_entity):
		if _entity.global_position.distance_to(_breach_target.global_position) > BREACH_DROP_DIST:
			valid = false  # 拦路者脱离（被拉开/风筝远离），不再构成拦路
	if not valid:
		_breach_target = null
		return false
	var cur: String = _state_machine.get_current_behavior_name() \
			if _state_machine != null else ""
	if cur == "attack" and not _state_machine.is_current_finished():
		return true  # 攻击进行中，保持（不重入，保住持瞄/出手节奏）
	if _state_machine != null and _state_machine.has_behavior("attack"):
		_state_machine.travel("attack", {"forced_target": _breach_target})
	return true


## 遇阻接战请求（behavior_move 消费的 duck 调用面）：移动途中被拦且无法简单绕过
## 时临时转入攻击拦路者。门禁：战斗职责过滤（工人不接战，同避战还击门）+ 战斗
## 实例激活（attack 行为依赖）+ 拦路者有效。置位打通态并 travel attack
##（forced_target 锁定拦路者）；**原号令不动**——粘性保障的核心：
## _ordered_behavior/_ordered_params 原样保留。返回是否已切入。
func request_breach_engagement(blocker: Node) -> bool:
	if blocker == null or not is_instance_valid(blocker):
		return false
	if _entity == null or not is_instance_valid(_entity):
		return false
	if _entity.has_method("is_dead") and _entity.is_dead():
		return false
	if not _can_work(WorkTypeCombat):
		return false
	if _state_machine == null or not _state_machine.has_behavior("attack"):
		return false
	if _entity.has_method("get_battle_instance"):
		var bi: Node = _entity.get_battle_instance()
		if bi == null or not is_instance_valid(bi) or not bi.has_method("is_active") \
				or not bi.is_active():
			return false
	if not is_breach_engaged():
		_breach_target = blocker
	if _state_machine.get_current_behavior_name() != "attack" \
			or _state_machine.is_current_finished():
		_state_machine.travel("attack", {"forced_target": _breach_target})
	return true


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
