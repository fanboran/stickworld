class_name TeamAi
extends RefCounted
## 阵营 AI 姿态机 -- SWL TeamAi 逐函数直译（P6 · 批次 7c+11c）。
##
## 上游：.codeartsdoer/specs/team_ai_direct/（spec/design/tasks）｜总计划：docs/项目/AI复刻执行计划.md §二 P6
## 定位：每阵营一个 RefCounted 组件，挂 BattleInstance（注册制 enable_team_ai，不注册零开销），
## 按力量对比（BalanceOfPowers）自动切换三姿态（GARRISON/DEFEND/ATTACK），
## 经 TacticalOrders.issue(source_tier=1) 对本阵营战斗小队下发号令。
## 不碰单位级决策与编队槽位；玩家手动号令 > 姿态自动号令 >（单位溃逃例外由 AIController 既有保障）。
##
## C3 敌将撤仗扩展（出征与领地架构 §4.2）：第四姿态 ROUT（单向终态）——
## 战役评估三阈值（伤亡率/战损比/相持超时，retreat_* 参数，据点战经 overrides 注入
## territories.commander.retreat_thresholds；默认全负 = 不评估，普通战斗维持全灭判定）
## 任一满足即全军 RETREAT(evacuate) 有序撤至己方侧边缘离场（单位 departed 计非存活）。
## ROUT 维持期每决策周期重发撤离号令（单位溃逃会清空命令，重发保撤离不中断）。
##
## 真值声明（§七.9）：dump TeamAi 21 个行为函数均为 IL2CPP 签名级导出、**无方法体**，
## 所有数值阈值为语义推断初值（legend TeamAiParameters 字段结构参考），**均待实测校准**；
## 方法名保留 dump 原名蛇形化，便于执行计划 §三 审计逐函数对账。
##
## A1（设计文档12号 C1/C2，AI集大成）：
##   - C1 节拍分帧：宿主 tick 改固定节拍调度（beat_interval=0.5s，CoH
##     TimeRule_AddInterval 0.5 真值），双相位轮转一跳一类事——DECIDE（快照+姿态
##     决策）/ BUILD（造兵桩），有效决策周期 = 2×beat = 1.0s（与旧
##     stance_decision_interval 默认等价，零回归）。
##   - C2 参数档案化：行为参数收敛为单一 personality 档案（难度分档维度已裁决
##     移除·开放问题#3，机制参数保留），经 TeamAiProfiles.load_personality_overlay
##     从 BalanceConfig 装载；开局攻击门禁 = seconds_before_attack ±
##     start_attack_variance 掷骰（CoH 9min±4min 同构）；默认种子固定
##     （确定性可测/可复现），显式 overrides.random_seed 可逐局随机。
##
## A2（设计文档12号 C3/C4/C5，AI集大成）：
##   - C3 任务槽：TaskBoard（攻/防槽）——本类只创建/杀槽（sync_slots，期望进攻
##     槽数 = ceil(attack% × 原子单元数)，CoH strategy_military 同构），小队匹配
##     归执行侧（match_groups：组织化编制作一组/散兵各一组）；槽带集结点/集结
##     超时（到点杀槽由 sync 重建）/目标超时（到点重评分重定向+重发号令）。
##   - C4 目标评分四因子：threat / avoid_clumps / distance / inertia（防振荡），
##     权重 CoH 真值（5/10/5/5/1.4）进 personality 档案；攻击槽目标 = 候选敌位
##     （敌方军事单位 + 敌质心）argmax，重评分以槽现目标为惯性参照。
##   - C5 攻击百分比四规则（优先级高→低）：胜利目标危急（开放问题#1 无 VP
##     等价物，vp_rule_enabled 缺省关闭【提案/待定】）→ 基地威胁封顶 → 基调
##     （单一参数曲线：门禁未开 0；开门禁后 baseline + 每分钟递增，封顶 max）
##     → 军力优势递增；"领先转防守"挂 VP 分支（随规则一同 dormant）。
##   - 咬合③：CoH 槽内核为主决策内核（姿态由槽驱动：有攻击槽→ATTACK，槽清空
##     →DEFEND；SWL 比例条件转写为槽创建/维持门禁——enter=attack_enter，
##     维持=ATTACK 态 ratio>attack_exit 滞回带）；SWL 决策函数（should_attack/
##     should_defend 签名与节流接口）保留为退化路径（slot_kernel_enabled=false
##     或任务板缺失时走原逻辑）。
##   - 下令路径收敛（§四）：组织化编制经 issue_to_org 逐跳传播（编制=原子，
##     整组一号令），散兵经 issue 现场直令；玩家手动号令保护期仍高于自动号令
##     （散兵逐队避让 / 编制任一成员保护期内整组避让，下轮槽重发/姿态切换恢复）。

## 同模块档案（显式 preload，headless 防御惯例 §七.3）
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")
const ScriptUtilityScorer := preload("res://modules/combat/scripts/battle/utility_scorer.gd")
## 拆分助手（W2 胖文件拆分：状态留本类，逻辑进 RefCounted 助手，持宿主回引；
## 依赖链无环：slot_kernel → order_emitter → behavior_hooks → squad_query）
const ScriptTeamAiSquadQuery := preload("res://modules/combat/scripts/battle/team_ai_squad_query.gd")
const ScriptTeamAiSnapshot := preload("res://modules/combat/scripts/battle/team_ai_snapshot.gd")
const ScriptTeamAiSlotKernel := preload("res://modules/combat/scripts/battle/team_ai_slot_kernel.gd")
const ScriptTeamAiOrderEmitter := preload("res://modules/combat/scripts/battle/team_ai_order_emitter.gd")
const ScriptTeamAiBehaviorHooks := preload("res://modules/combat/scripts/battle/team_ai_behavior_hooks.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 姿态枚举（0=GARRISON/1=DEFEND/2=ATTACK，对齐 dump Team.Stance 枚举序；
## 3=ROUT 敌将撤仗终态，本作扩展——出征与领地架构 §4.2）
const STANCE_GARRISON: int = 0
const STANCE_DEFEND: int = 1
const STANCE_ATTACK: int = 2
const STANCE_ROUT: int = 3
## 自动号令发令层级（TeamAi 统一 tier=1；玩家手动号令 tier=0）
const SOURCE_TIER_AI: int = 1
## 玩家手动号令层级（EventBus.order_issued 的 source_tier 语义）
const SOURCE_TIER_PLAYER: int = 0
## 分帧相位（C1：0.5s 基础节拍上一跳一类事，CoH AI_Think/Analyze 分帧同构）
const PHASE_DECIDE: int = 0
const PHASE_BUILD: int = 1

# ─────────────────────────────── 状态 ────────────────────────────────
## 宿主战斗实例（duck 引用，RefCounted 持 Node 用 Variant 语义注解）
var _battle: Node = null
## 本阵营 ID（1=进攻方 / 2=防守方）
var _faction: int = 0
## 号令系统引用（允许 null：测试环境姿态决策照跑、号令跳过）
var _orders: Node = null
## 编队系统引用（允许 null：同上）
var _formation: Node = null
## 参数档案（TeamAiProfiles.get_profile 合并产物）
var _p: Dictionary = {}
## 当前姿态（初始 DEFEND，对应 SecondsBeforeCanLeaveBase 语义）
var _stance: int = STANCE_DEFEND
## 最近一次姿态切换原因（调试 HUD / battle_sim 采样）
var _stance_reason: String = "init"

## 节拍累积器（C1：beat_interval 粒度调度，while 兼容 delta 尖峰不丢拍）
var _beat_acc: float = 0.0
## 当前分帧相位（DECIDE/BUILD 轮转，起始 DECIDE 保证首拍即决策）
var _phase: int = PHASE_DECIDE
## 开局攻击门禁截止时刻（战斗秒；setup 期按档案掷骰一次定局）
var _attack_deadline: float = 0.0
## 档案掷骰随机源（默认固定种子：确定性可测/可复现；overrides.random_seed 覆盖）
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## 快照：本方军事单位数（权重>0 的存活单位）
var _num_military: int = 0
## 快照：敌方军事单位数
var _num_enemy_military: int = 0
## 快照：本方/敌方存活单位质心（号令目标点）
var _own_centroid: Vector2 = Vector2.ZERO
var _enemy_centroid: Vector2 = Vector2.ZERO
## 快照：本方/敌方军事力量值（按兵种权重加权求和）
var _own_strength: float = 0.0
var _enemy_strength: float = 0.0
## 快照：本方正遭投射物袭击（arrow_threat_time 窗口内有登记）
var _own_threatened: bool = false
## 首次快照的本方力量基线（no_defender_floor 比例分母；每战斗恒定）
var _initial_own_strength: float = -1.0
## A2 快照：敌方存活军事单位 [{pos, weight}]（C4 攻击目标候选/评分取数；
## 不持单位引用只留值拷贝，防 freed 悬挂，与快照口径一致）
var _enemy_units_snapshot: Array = []
## A2 快照：敌军在本方锚点 enemy_close_dist 半径内的力量值（C5 基地威胁取数）
var _enemy_strength_near_base: float = 0.0
## A2 · C3 任务槽板实例（setup 装配；权重/超时与 _p 同源档案；
## slot_kernel_enabled=false 时决策不走槽，板仍同步保持观测面一致）
var _task_board: ScriptTaskBoard = null
## W1 观测缓存：最近一次决策周期重算的攻击百分比（get_attack_percentage 消费；
## 决策节拍刷新而非查询时重算——HUD 轮询不重跑四规则，方案 §2.6）
var _cached_attack_pct: float = 0.0

## 节流计时器三件套（dump 字段直译：_lastStanceChangeTime/_lastGarrisonTime/_lastBuildUpdate；
## 时钟源 = battle.get_duration() 战斗秒：暂停冻结、随宿主）
var _last_stance_change_time: float = -1.0e9
var _last_garrison_time: float = -1.0e9
var _last_build_update: float = -1.0e9

## 手动号令保护期：squad_id -> 保护截止时刻（战斗秒）
var _manual_order_until: Dictionary = {}

## A4 效用打分器（default_behavior v2 消费端；setup 装配，开关默认关 = 不参与决策零开销）
var _utility_scorer: ScriptUtilityScorer = null
## A4 组织 API duck 引用（default_behavior 只读消费；经 _orders 同模块探测，见 _resolve_org_api）
var _org_api: Node = null
## A4 观测面：squad_id -> 最近一次 default_behavior 选择名（调试 HUD / 测试断言）
var _default_behavior_choices: Dictionary = {}

## 拆分助手实例（W2；setup 装配，dispose 置空。逻辑在助手、状态留本类）：
var _squad_query: ScriptTeamAiSquadQuery = null   ## 小队/编制视图取数（formation/orders duck 读）
var _snapshot: ScriptTeamAiSnapshot = null        ## 战场快照刷新（回写本类快照字段）
var _slot_kernel: ScriptTeamAiSlotKernel = null   ## 任务槽内核（C5 评分/门禁/槽同步/目标定位）
var _order_emitter: ScriptTeamAiOrderEmitter = null  ## 姿态号令下发（映射+保护期+org 分流）
var _behavior_hooks: ScriptTeamAiBehaviorHooks = null  ## default_behavior v2 接入（组织 duck+打分门禁）


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配（BattleInstance.enable_team_ai 内调用）。
## battle 已 setup 且 faction ∈ {1,2}；orders/formation 允许 null（仅测试环境）；
## overrides 仅 setup 期消费一次——merge 序 = 代码默认 < personality 单一档案 <
## 显式 overrides（随机种子键 overrides["random_seed"]，A1；遗留键
## overrides["difficulty"] 宽容忽略——难度分档维度已裁决移除·开放问题#3，
## get_profile 仅透传档案既有键集，未知键静默丢弃）。
func setup(battle: Node, faction: int, orders: Node, formation: Node, overrides: Dictionary = {}) -> void:
	_battle = battle
	_faction = faction
	_orders = orders
	_formation = formation
	# C2 单一档案：BalanceConfig 装载（缺载安全回退代码默认），显式 overrides 最高优先
	# （merge overwrite=true 兑现 setup 文档承诺的覆盖序：代码默认 < 档案 < overrides）；
	# 遗留键 overrides["difficulty"] 宽容忽略（get_profile 档案键集过滤静默丢弃）
	var effective: Dictionary = {}
	effective.merge(ScriptTeamAiProfiles.load_personality_overlay())
	effective.merge(overrides, true)
	_p = ScriptTeamAiProfiles.get_profile(effective)
	# A4（追加）：default_behavior v2 参数经 personality.tres global 行装载——get_profile
	# 仅透传 DEFAULTS 既有键（档案文件键集不动），此处把 A4 新键补挂进 _p。
	# 优先序 = 显式 overrides > personality 单一档案（effective 已按覆盖序合并，
	# A4 键不在 DEFAULTS 键集、须在此显式补挂；overlay 缺载时键缺席 = 代码默认关）。
	for _a4_key in ["default_behavior_v2_enabled", "demand_increment"]:
		if overrides.has(_a4_key):
			_p[_a4_key] = overrides[_a4_key]
		elif effective.has(_a4_key):
			_p[_a4_key] = effective[_a4_key]
	# W1（追加）：WorldBox 效用选优内核参数同法补挂——softmax 选择规则/量纲归一/温度/
	# 权重委托/冷却判定五键。缺载时键缺席 = 消费侧代码默认（与档案默认同值）。
	for _w1_key in ["softmax_enabled", "softmax_weight_scale", "softmax_temperature",
			"weight_calculate_enabled", "cooldown_enabled"]:
		if overrides.has(_w1_key):
			_p[_w1_key] = overrides[_w1_key]
		elif effective.has(_w1_key):
			_p[_w1_key] = effective[_w1_key]
	# 开局攻击门禁掷骰：基准 ± 方差半宽一次定局（CoH standard 9min±4min 同构；
	# 默认固定种子 → 门禁确定性，单测可锁、battle_sim 可复现）
	_rng.seed = int(overrides.get("random_seed", ScriptTeamAiProfiles.DEFAULT_RANDOM_SEED))
	var base_time: float = float(_p["seconds_before_attack"])
	var variance: float = maxf(float(_p["start_attack_variance"]), 0.0)
	_attack_deadline = base_time + _rng.randf_range(-variance, variance)
	# A2 · C3 任务槽板（与 _p 同源档案引用：C4 权重/槽超时全档案化）
	_task_board = ScriptTaskBoard.new()
	_task_board.setup(_p)
	# W2 拆分助手装配（仅持引用无副作用；依赖链无环：query → hooks → emitter → kernel）
	_squad_query = ScriptTeamAiSquadQuery.new()
	_squad_query.setup(self)
	_snapshot = ScriptTeamAiSnapshot.new()
	_snapshot.setup(self)
	_behavior_hooks = ScriptTeamAiBehaviorHooks.new()
	_behavior_hooks.setup(self, _squad_query)
	_order_emitter = ScriptTeamAiOrderEmitter.new()
	_order_emitter.setup(self, _squad_query, _behavior_hooks)
	_slot_kernel = ScriptTeamAiSlotKernel.new()
	_slot_kernel.setup(self, _squad_query, _order_emitter)
	# W1 观测缓存首算（门禁未开 = 0.0；定义初始值，查询侧不依赖首次决策到达）
	_cached_attack_pct = recalculate_attack_percentage()
	# 手动号令保护期守卫：订阅全局号令事件（tier=0 玩家直令刷新保护时间戳）
	if EventBus != null and EventBus.has_signal("order_issued") \
			and not EventBus.order_issued.is_connected(_on_order_issued):
		EventBus.order_issued.connect(_on_order_issued)
	# A4 效用打分器装配（default_behavior v2；开关关时纯闲置，号令路径不消费）
	_utility_scorer = ScriptUtilityScorer.new()
	_utility_scorer.setup(_p)
	_org_api = _resolve_org_api()


## 消亡钩子（宿主 _end 调用）：断开 EventBus 订阅，防 freed 悬空连接。
func dispose() -> void:
	_task_board = null
	_utility_scorer = null
	_org_api = null
	_slot_kernel = null
	_order_emitter = null
	_behavior_hooks = null
	_snapshot = null
	_squad_query = null
	if EventBus != null and EventBus.has_signal("order_issued") \
			and EventBus.order_issued.is_connected(_on_order_issued):
		EventBus.order_issued.disconnect(_on_order_issued)


## 装配引用补注入（宿主 set_order_refs 转发；orders/formation 允许 null）
func set_order_refs(orders: Node, formation: Node) -> void:
	_orders = orders
	_formation = formation
	# A4（追加）：orders 补注入后重探组织 API（"先注册 TeamAi 后补引用"兼容路径）
	_org_api = _resolve_org_api()


## 宿主 tick（BattleInstance._physics_process 内调用，每物理帧进入）。
## C1 固定节拍分帧：按 beat_interval 累积，每拍只跑一个相位（DECIDE=快照+姿态决策 /
## BUILD=造兵桩），轮转推进——决策不逐帧思考，单拍峰值成本减半。
## 后置：相位推进完整（while 兼容 delta 尖峰）；姿态变更时号令已受理或已跳过（不排队）。
func tick(delta: float) -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	# 决策门禁（宿主已保证 ENGAGED；暂停/倍速由引擎总闸与 sim_delta 全局负责）
	if not _battle.has_method("is_active") or not _battle.is_active():
		return
	if TimeManager != null and TimeManager.is_paused():
		return
	_beat_acc += delta
	var beat: float = float(_p["beat_interval"])
	while _beat_acc >= beat:
		_beat_acc -= beat
		_run_beat()


## 执行一个节拍相位并轮转（DECIDE 起拍：首拍即决策，与旧调度首周期一致）
func _run_beat() -> void:
	match _phase:
		PHASE_DECIDE:
			stance_update()
		PHASE_BUILD:
			build_units_update()
		_:
			pass
	_phase = PHASE_BUILD if _phase == PHASE_DECIDE else PHASE_DECIDE


# ─────────────────────────────── 只读查询（稳定接口）────────────────────────────────

## 当前姿态（9i+ 消费端 / 调试 HUD）
func get_stance() -> int:
	return _stance


## 攻击百分比缓存查询（W1 · 方案 §2.6 接口缺口补齐）：返回最近一次决策周期
## 重算的 recalculate_attack_percentage() 结果（0~1）。缓存随 _update_task_board
## 按决策节拍刷新（含 setup 期首算），查询侧零重算零副作用——调试 HUD/观测
## 采样可高频轮询。门禁未开/尚无快照 = 0.0。
func get_attack_percentage() -> float:
	return _cached_attack_pct


## 驻守锚点（GARRISON 号令目标 / 归队参照）
func get_garrison_anchor() -> Vector2:
	if _battle != null and is_instance_valid(_battle) and _battle.has_method("get_faction_side_anchor"):
		return _battle.get_faction_side_anchor(_faction)
	return Vector2.ZERO


## 最近一次姿态切换原因（battle_sim 采样 / 调试）
func get_stance_reason() -> String:
	return _stance_reason


## 开局攻击门禁截止时刻（A1 · C2 掷骰产物；调试 HUD / 观测采样）
func get_attack_deadline() -> float:
	return _attack_deadline


# ─────────────────────────────── 直译函数族（21 函数，按 dump 原名蛇形）────────────────────────────────

## [dump #1 Update] 编排入口：姿态决策 → 造兵桩（直译锚点保留；生产调度走
## tick 固定节拍分帧（A1 C1：DECIDE/BUILD 双相位各占一拍），本函数供测试/审计直调）。
func update() -> void:
	stance_update()
	build_units_update()


## [dump #2 StanceUpdate] 姿态机决策编排（组合顺序无 dump 真值：撤仗评估 > 驻守触发集 > 力量条件，
## 理由：驻守条件是生存开关，被力量条件压过会导致濒危阵营继续压上——设计决策，待实测校准；
## 撤仗是战役级终局决策（C3），一切战术姿态之上的"这仗不能打了"）。
func stance_update() -> void:
	_refresh_snapshot()
	# ROUT 单向终态：撤仗不回头，维持期每决策周期重发撤离号令
	# （单位溃逃例外会清空命令，重发保撤离不中断直至全员离场/全灭）
	if _stance == STANCE_ROUT:
		_issue_stance_orders()
		return
	# 本方无军事单位：决策静默空转（无号令对象）
	if _num_military <= 0:
		return
	# 初始力量基线（首个有效快照登记，供 no_defender_floor 比例分母）
	if _initial_own_strength < 0.0:
		_initial_own_strength = _own_strength
	# 敌将撤仗评估（C3，最高优先）：三阈值任一满足即全军 ROUT；
	# 阈值未注入（默认全负）恒假——普通战斗零回归闸门在此兑现
	if should_rout():
		_set_stance(STANCE_ROUT, _rout_reason())
		return
	# A2 · C3/C4/C5 CoH 内核先行：攻击百分比重算 + 任务槽同步/超时（决策数据）
	_update_task_board()
	# 驻守触发集优先于力量条件（非 GARRISON 态；受全姿态切换冷却节流；
	# 生存开关，槽内核亦不得压过——两内核共享同一优先序）
	if _stance != STANCE_GARRISON:
		if _can_change_stance() and should_garrison():
			_set_stance(STANCE_GARRISON, "garrison_triggers")
			_last_garrison_time = _now()
			return
	# GARRISON 维持与重评（WeRecentlyDecidedToGarrison 语义：驻守冷却内不重评）
	if _stance == STANCE_GARRISON:
		if not should_garrison() and not we_recently_decided_to_garrison():
			# 触发集全假 ∧ 驻守冷却满 → 按内核重评（此处不受"非 GARRISON"门禁，
			# 重评本身就是解除驻守的决策；开局门禁仍然生效）
			if _garrison_reeval_attack_open():
				_set_stance(STANCE_ATTACK, "garrison_reeval_attack")
			else:
				_set_stance(STANCE_DEFEND, "garrison_reeval_defend")
		return
	# 力量条件（受切换冷却节流；迟滞带内维持现态）
	if not _can_change_stance():
		return
	# 决策内核分派（咬合③）：CoH 槽内核为主（姿态由攻击槽驱动），
	# SWL 比例条件保留为退化路径（签名不变，slot_kernel_enabled=false 时消费）
	if _task_board_enabled():
		if _task_board.has_attack_slots():
			if _stance != STANCE_ATTACK:
				_set_stance(STANCE_ATTACK, "slots_attack")
		elif _stance == STANCE_ATTACK:
			_set_stance(STANCE_DEFEND, "slots_defend")
	elif should_attack():
		_set_stance(STANCE_ATTACK, "ratio_attack")
	elif should_defend():
		_set_stance(STANCE_DEFEND, "ratio_defend")


## [dump #3 IsAttacking] 姿态谓词
func is_attacking() -> bool:
	return _stance == STANCE_ATTACK


## [dump #4 IsDefending] 姿态谓词
func is_defending() -> bool:
	return _stance == STANCE_DEFEND


## [dump #5 IsGarrisoned] 姿态谓词
func is_garrisoned() -> bool:
	return _stance == STANCE_GARRISON


## [dump #6 ShouldAttack] ratio ≥ attack_enter ∧ 开局门禁过 ∧ 非 GARRISON（阈值待实测校准）
func should_attack() -> bool:
	if _stance == STANCE_GARRISON:
		return false
	return _attack_gate_open() and balance_of_powers_ratio() >= float(_p["attack_enter"])


## 开局攻击门禁（SecondsBeforeCanLeaveBase 语义近似）：时长未满即便力量占优不切 ATTACK。
## 门禁时刻 = seconds_before_attack ± start_attack_variance 掷骰（A1 · C2，
## setup 期一次定局；CoH 9min±4min 同构——开局节奏不可预测，参数档案可调）
func _attack_gate_open() -> bool:
	return _now() >= _attack_deadline


## [dump #7 ShouldDefend] 进攻中回落（ratio ≤ attack_exit）或防守恶化（≤ defend_enter）。
## DEFEND 是 GARRISON 之下的最低力量姿态：恶化判定返回 true 时无迁移动作（维持），由
## 驻守触发集兜底升级 GARRISON（阈值待实测校准）。
func should_defend() -> bool:
	var ratio: float = balance_of_powers_ratio()
	if _stance == STANCE_ATTACK:
		return ratio <= float(_p["attack_exit"])
	return ratio <= float(_p["defend_enter"])


## [dump #8 ShouldGarrison] 5 触发条件 OR 组合（EnemyHasNoMilitaryUnits 排除逻辑
## 内嵌在 #15 前置中；触发顺序无真值，任一成立即驻守）。
func should_garrison() -> bool:
	return enemy_army_is_close_to_us() \
			or enemy_is_shooting_projectiles_at_us() \
			or we_recently_decided_to_garrison() \
			or we_have_no_defenders_and_the_enemy_units_are_close()


## [dump #9 CompareUnitTypes] 兵种优先级比较器：type_priority 序 GIANT>STAFF>SPEAR>BOW>SWORD
## （排序真值来自签名语义，权重值待校准）。返回 -1（a 优先）/ 0（同级）/ 1（b 优先），
## 对齐 C# IComparer 语义。
func compare_unit_types(a: int, b: int) -> int:
	var ia: int = (_p["type_priority"] as Array).find(a)
	var ib: int = (_p["type_priority"] as Array).find(b)
	if ia < 0:
		ia = (_p["type_priority"] as Array).size()
	if ib < 0:
		ib = (_p["type_priority"] as Array).size()
	return 0 if ia == ib else (-1 if ia < ib else 1)


## [dump #10 BalanceOfPowers] 本方与敌方 MilitaryStrength 之差（公式无 dump 真值，待实测校准）
func balance_of_powers() -> float:
	return _own_strength - _enemy_strength


## [dump #11 BalanceOfPowersRatio] 本方/敌方归一化力量比值（公式无 dump 真值）：
## 镜像兵力 = 1.0；敌方力量 0（全歼/无军事单位）→ 哨兵值 10.0（绝对优势）。
func balance_of_powers_ratio() -> float:
	if _enemy_strength <= 0.0:
		return float(_p["ratio_empty_enemy_sentinel"])
	return _own_strength / _enemy_strength


## [dump #12 EnemyArmyIsCloseToUs] 敌军质心距本方锚点 < enemy_close_dist
func enemy_army_is_close_to_us() -> bool:
	return _enemy_centroid.distance_to(get_garrison_anchor()) < float(_p["enemy_close_dist"])


## [dump #13 EnemyIsShootingProjectilesAtUs] 本方存活单位 arrow_threat_time 在窗口内有登记即真
## （数据源 = WeaponMount 出手瞄准登记，"来袭登记"口径，spec §5.3.1.2 允许；零新事件）。
func enemy_is_shooting_projectiles_at_us() -> bool:
	return _own_threatened


## [dump #14 WeRecentlyDecidedToGarrison] battle.duration - _last_garrison_time < garrison_cool
## （驻守维持防抖：刚驻守过 garrison_cool 秒内视为"仍倾向驻守"）
func we_recently_decided_to_garrison() -> bool:
	return _now() - _last_garrison_time < float(_p["garrison_cool"])


## [dump #15 WeHaveNoDefendersAndTheEnemyUnitsAreClose] 本方力量占初始基线比例低于
## no_defender_floor ∧ 敌近（#12）。前置：敌方存在军事单位（#17 排除——敌全灭不触发驻守）。
func we_have_no_defenders_and_the_enemy_units_are_close() -> bool:
	if enemy_has_no_military_units():
		return false
	if _initial_own_strength <= 0.0:
		return false
	var ratio: float = _own_strength / _initial_own_strength
	return ratio < float(_p["no_defender_floor"]) and enemy_army_is_close_to_us()


## [dump #16 TeamHasAGiant] 本方存活单位类别含 GIANT（P8 前恒假属预期，占位类别可验真）
func team_has_a_giant() -> bool:
	return _snapshot.scan_faction_for_type(_faction, ScriptTeamAiProfiles.GIANT)


## [dump #17 EnemyHasNoMilitaryUnits] 敌方存活军事单位数 == 0（供 #15 排除与重评逻辑）
func enemy_has_no_military_units() -> bool:
	return _num_enemy_military <= 0


## [dump #18 BarricadeExists] 桩：恒 false（路障玩法挂翻译缺口总账，批次 11e）
func barricade_exists() -> bool:
	return false


## [dump #19 StatueIsLowHealth] 桩：恒 false（雕像玩法与本作大世界定位冲突，玩法决策后回填）
func statue_is_low_health() -> bool:
	return false


## [dump #20 HasDesperationGroupThatSpawned] 桩：恒 false（dump 无方法体且语义不完全明确，
## 待玩法对应后回填）
func has_desperation_group_that_spawned() -> bool:
	return false


## [dump #21 BuildUnitsUpdate] 空转桩：保留调用位与函数边界，仅刷计时 + compare_unit_types
## 结构占位（不消费）。本作战场无金币经济（gold 仅存在于战略图资源层，spec §5.4.1），
## 原版依赖 Team.gold + buildQueue + castle 出生建筑全缺——经济系统落地后补全
## （翻译缺口总账：docs/项目/待办事项.md）。
func build_units_update() -> void:
	_last_build_update = _now()
	# 结构占位：兵种优先序比较器已在快照侧可用（compare_unit_types），造兵决策待经济联动
	if _num_enemy_military > 0:
		compare_unit_types(ScriptTeamAiProfiles.SWORD, ScriptTeamAiProfiles.SPEAR)


# ─────────────────────────────── 战役撤仗评估（C3 扩展，非 dump 直译）────────────────────────────────

## 三阈值任一满足即应撤仗（"这仗不能打了"）：should_rout 的谓词形态（调试/测试断言用）。
## 阈值未注入（retreat_* 全默认负）恒假 = 普通战斗维持全灭判定的注册制闸门。
func should_rout() -> bool:
	return not _rout_reason().is_empty()


## 撤仗原因（空串 = 不撤）：
##   retreat_casualty_rate  伤亡率 = 本方伤亡/初始兵力超阈（守军打光了）
##   retreat_loss_ratio     战损比 = 本方伤亡/敌方伤亡超阈（打不动对面，换命亏）
##   retreat_timeout        相持超时 = 战斗持续秒数超阈（拿不下据点，无意义消耗）
## 评估通过后由调用方切 ROUT；本方法纯查询无副作用。
func _rout_reason() -> String:
	var casualty_rate_th: float = float(_p["retreat_casualty_rate"])
	var loss_ratio_th: float = float(_p["retreat_loss_ratio"])
	var timeout_th: float = float(_p["retreat_timeout"])
	if casualty_rate_th <= 0.0 and loss_ratio_th <= 0.0 and timeout_th <= 0.0:
		return ""
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_casualties"):
		return ""
	var enemy_faction: int = 2 if _faction == 1 else 1
	var own_losses: int = int(_battle.get_casualties(_faction))
	var enemy_losses: int = int(_battle.get_casualties(enemy_faction))
	if casualty_rate_th > 0.0:
		var total: int = _own_initial_count()
		if total > 0 and float(own_losses) / float(total) > casualty_rate_th:
			return "retreat_casualty_rate"
	if loss_ratio_th > 0.0 and own_losses > 0 and enemy_losses > 0 \
			and float(own_losses) / float(enemy_losses) > loss_ratio_th:
		return "retreat_loss_ratio"
	if timeout_th > 0.0 and _now() > timeout_th:
		return "retreat_timeout"
	return ""


## 初始参战兵力（伤亡率分母）：本方当前存活军事单位 + 累计伤亡 = 开局基数。
## 动态重算而非首快照登记（首个决策周期在开战 1s 后，先减员会低估基数）；
## P0 据点战无中途增援，值恒定；增援接入后改为 add_unit 时点登记。
func _own_initial_count() -> int:
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_casualties"):
		return 0
	return _num_military + int(_battle.get_casualties(_faction))


# ─────────────────────────────── 任务槽内核（A2 · C3/C4/C5，非 dump 直译）────────────────────────────────
## 决策逻辑在拆分助手 team_ai_slot_kernel.gd（W2），本节只留公共/内部访问壳——
## 状态（任务槽板实例/观测缓存）留本类，签名与行为逐位不变。

## 任务槽板只读访问（调试 HUD / 测试断言；setup 前为 null）
func get_task_board() -> ScriptTaskBoard:
	return _task_board


## 槽内核是否在决策位（咬合③：开关 + 板实例双检；false 走 SWL 退化路径）
func _task_board_enabled() -> bool:
	return _slot_kernel.is_enabled()


## C5 攻击百分比（四规则评分体在 team_ai_slot_kernel.recalculate_attack_pct；W2 壳）
func recalculate_attack_percentage() -> float:
	return _slot_kernel.recalculate_attack_pct()


## 基地威胁值（0-100 口径；评分体在 team_ai_slot_kernel.threat_at_base；W2 壳）
func threat_at_base() -> float:
	return _slot_kernel.threat_at_base()


## GARRISON 重评进攻条件（两内核同判入口；体在 team_ai_slot_kernel；W2 壳）
func _garrison_reeval_attack_open() -> bool:
	return _slot_kernel.garrison_reeval_attack_open()


## 槽同步 + 生命周期（体在 team_ai_slot_kernel.update_task_board；W2 壳）
func _update_task_board() -> void:
	_slot_kernel.update_task_board()


# ─────────────────────────────── 快照刷新（每决策周期重建，O(n)）────────────────────────────────

## 快照刷新体在拆分助手 team_ai_snapshot.gd（W2）：遍历双方存活单位各至多一次，
## 回写本类快照字段（军事单位数/力量值/质心/威胁/敌方值拷贝/基地半径内敌力）。
func _refresh_snapshot() -> void:
	_snapshot.refresh()


# ─────────────────────────────── 姿态切换与号令下发 ────────────────────────────────

## 全姿态切换统一节流（dump _lastStanceChangeTime；60s 理论上限 12 次防号令风暴）
func _can_change_stance() -> bool:
	return _now() - _last_stance_change_time >= float(_p["stance_change_cooldown"])


## 执行姿态切换：记录时间戳/原因 → 广播事件 → 号令映射下发（仅切换时一次，维持期不重发）
func _set_stance(to: int, reason: String) -> void:
	if to == _stance:
		return
	var from: int = _stance
	_stance = to
	_stance_reason = reason
	_last_stance_change_time = _now()
	if EventBus != null and EventBus.has_signal("team_ai_stance_changed"):
		var bid: String = _battle.get_battle_id() if _battle != null \
				and is_instance_valid(_battle) and _battle.has_method("get_battle_id") else ""
		EventBus.team_ai_stance_changed.emit(bid, _faction, from, to, reason)
	_issue_stance_orders()


## 姿态→号令映射器（体在拆分助手 team_ai_order_emitter.gd，W2 壳；姿态切换事件
## 发射点在本类 _set_stance，号令映射与下发在 emitter——决策/执行分离）。
func _issue_stance_orders() -> void:
	_order_emitter.issue_stance_orders()


# ─────────────────────────────── 手动号令保护期守卫 ────────────────────────────────

## EventBus.order_issued 订阅回调：玩家手动号令（tier=0）刷新该小队保护时间戳；
## 连续手动号令从最后一次起算（spec §5.2.3.1）。
func _on_order_issued(_order_type: int, squad_id: String, source_tier: int) -> void:
	if source_tier != SOURCE_TIER_PLAYER:
		return
	if _battle == null or not is_instance_valid(_battle):
		return
	_manual_order_until[squad_id] = _now() + float(_p["manual_order_guard"])


## 小队是否处于手动号令保护期内
func _is_manual_order_active(squad_id: String) -> bool:
	if not _manual_order_until.has(squad_id):
		return false
	return _now() < float(_manual_order_until[squad_id])


## 手动号令保护期查询出口（编队侧权威值跳槽守卫复用，语义同 _is_manual_order_active）：
## 保护期状态唯一真相源在本类（订阅 EventBus.order_issued tier=0 刷新），
## 消费方经 battle_instance.get_team_ai(faction) 取用，不各自维护时间戳副本。
func is_manual_order_guarded(squad_id: String) -> bool:
	return _is_manual_order_active(squad_id)


# ─────────────────────────────── default_behavior v2 效用打分（A4 · C7，非 dump 直译）────────────────────────────────
## CoH tactics.ai demand 系统同构（docs/审计/英雄连AI逆向_2026-09-11.md §3.5，评分实现
## 归 UtilityScorer）。接入逻辑在拆分助手 team_ai_behavior_hooks.gd（W2）：组织配置
## 取数 / 小队上下文快照 / 接入点门禁；状态（_org_api/_utility_scorer/选择观测面）
## 留本类，公共出口留本节。

## 组织 API 引用显式注入（测试/宿主装配出口；不调用时走 _resolve_org_api 同模块探测）
func set_org_api(api: Node) -> void:
	_org_api = api


## 组织 API 同模块 duck 探测（体在 team_ai_behavior_hooks.resolve_org_api；W2 壳）
func _resolve_org_api() -> Node:
	return _behavior_hooks.resolve_org_api()


## 最近一轮 default_behavior 选择快照（只读副本；调试 HUD / 测试断言）
func get_default_behavior_choices() -> Dictionary:
	return _default_behavior_choices.duplicate()


# ─────────────────────────────── 内部工具 ────────────────────────────────

## 战斗秒时钟（battle.get_duration()：暂停冻结、随宿主；battle 失效返回 -inf 不推进）
func _now() -> float:
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_duration"):
		return -1.0e9
	return float(_battle.get_duration())