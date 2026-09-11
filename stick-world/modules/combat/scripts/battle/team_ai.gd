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
##   - C2 难度参数化：难度档（easy/standard/hard/hardest）经
##     TeamAiProfiles.load_personality_overlay 从 BalanceConfig 装载；
##     开局攻击门禁 = seconds_before_attack ± start_attack_variance 掷骰
##     （CoH standard 9min±4min 同构，难度=参数不=作弊）；默认种子固定
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
##     等价物，vp_rule_enabled 缺省关闭【提案/待定】）→ 基地威胁封顶 → 难度基调
##     （门禁未开 0；开门禁后 baseline + 每分钟递增，封顶 max）→ 军力优势递增；
##     "领先转防守"挂 VP 分支（随规则一同 dormant）。
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
## 难度档名（A1 · C2，setup 显式 overrides["difficulty"]，默认 standard）
var _difficulty: String = ""
## 开局攻击门禁截止时刻（战斗秒；setup 期按难度档案掷骰一次定局）
var _attack_deadline: float = 0.0
## 难度档案掷骰随机源（默认固定种子：确定性可测/可复现；overrides.random_seed 覆盖）
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


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配（BattleInstance.enable_team_ai 内调用）。
## battle 已 setup 且 faction ∈ {1,2}；orders/formation 允许 null（仅测试环境）；
## overrides 仅 setup 期消费一次——merge 序 = 代码默认 < 难度档案 < 显式 overrides
## （难度选择键 overrides["difficulty"]，随机种子键 overrides["random_seed"]，A1）。
func setup(battle: Node, faction: int, orders: Node, formation: Node, overrides: Dictionary = {}) -> void:
	_battle = battle
	_faction = faction
	_orders = orders
	_formation = formation
	# C2 难度档案：BalanceConfig 装载（缺载安全回退代码默认），显式 overrides 最高优先
	_difficulty = str(overrides.get("difficulty", ScriptTeamAiProfiles.DEFAULT_DIFFICULTY))
	var effective: Dictionary = {}
	effective.merge(ScriptTeamAiProfiles.load_personality_overlay(_difficulty))
	effective.merge(overrides)
	_p = ScriptTeamAiProfiles.get_profile(effective)
	# A4（追加）：default_behavior v2 参数经 personality.tres global 行装载——get_profile
	# 仅透传 DEFAULTS 既有键（档案文件键集不动），此处把 A4 新键补挂进 _p。
	# 优先序 = 显式 overrides > 难度档案（既有 effective.merge 为不改写语义，A4 键
	# 在此显式兑现 setup 文档承诺的覆盖序；overlay 缺载时键缺席 = 代码默认关）。
	for _a4_key in ["default_behavior_v2_enabled", "demand_increment"]:
		if overrides.has(_a4_key):
			_p[_a4_key] = overrides[_a4_key]
		elif effective.has(_a4_key):
			_p[_a4_key] = effective[_a4_key]
	# 开局攻击门禁掷骰：基准 ± 方差半宽一次定局（CoH standard 9min±4min 同构；
	# 默认固定种子 → 门禁确定性，单测可锁、battle_sim 可复现）
	_rng.seed = int(overrides.get("random_seed", ScriptTeamAiProfiles.DEFAULT_RANDOM_SEED))
	var base_time: float = float(_p["seconds_before_attack"])
	var variance: float = maxf(float(_p["start_attack_variance"]), 0.0)
	_attack_deadline = base_time + _rng.randf_range(-variance, variance)
	# A2 · C3 任务槽板（与 _p 同源档案引用：C4 权重/槽超时全档案化）
	_task_board = ScriptTaskBoard.new()
	_task_board.setup(_p)
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
	# 决策门禁双保险（宿主已保证 ENGAGED + 未暂停，TeamAi 再自检一层）
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


## 驻守锚点（GARRISON 号令目标 / 归队参照）
func get_garrison_anchor() -> Vector2:
	if _battle != null and is_instance_valid(_battle) and _battle.has_method("get_faction_side_anchor"):
		return _battle.get_faction_side_anchor(_faction)
	return Vector2.ZERO


## 最近一次姿态切换原因（battle_sim 采样 / 调试）
func get_stance_reason() -> String:
	return _stance_reason


## 难度档名（A1 · C2；调试 HUD / battle_sim 采样）
func get_difficulty() -> String:
	return _difficulty


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
## 门禁时刻 = seconds_before_attack ± start_attack_variance 掷骰（A1 · C2：难度=参数，
## setup 期一次定局；CoH standard 9min±4min 同构——开局节奏不可预测但难度差异全在参数）
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
	return _scan_faction_for_type(_faction, ScriptTeamAiProfiles.GIANT)


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

## 任务槽板只读访问（调试 HUD / 测试断言；setup 前为 null）
func get_task_board() -> ScriptTaskBoard:
	return _task_board


## 槽内核是否在决策位（咬合③：开关 + 板实例双检；false 走 SWL 退化路径）
func _task_board_enabled() -> bool:
	return _task_board != null and bool(_p.get("slot_kernel_enabled", true))


## C5 攻击百分比（CoH state_analysis.recalculate_attackpercentage 同构，四规则
## 优先级高→低；返回 0~1 = 应处进攻位的战斗小队比例）：
##   规则一 胜利目标危急（vp_rule_enabled，缺省关闭【提案/待定】——开放问题#1
##          战役域无 VP 等价物；旗/区域控制接入后实现"票数危急抬升、我方占优
##          翻转防守"语义，本批仅留参数开关位）
##   规则二 基地威胁封顶（硬帽，最后施加）：threat_at_base 超阈 →
##          pct ≤ max(100 - threat, floor)/100
##   规则三 难度基调：门禁未开 = 0；开门禁后 baseline + 每分钟递增，封顶 max
##   规则四 军力优势递增（hard/hardest 消费）：归一化优势超起点 → 按增益抬升，
##          同受 max 封顶
func recalculate_attack_percentage() -> float:
	# 规则三（基调）：开局攻击门禁未过 → 0（CoH start_attack_time 前攻击% = 0）
	if not _attack_gate_open():
		return 0.0
	var pct: float = float(_p["attack_pct_baseline"])
	var minutes: float = maxf(_now() - _attack_deadline, 0.0) / 60.0
	pct += float(_p["attack_pct_growth_per_min"]) * minutes
	pct = minf(pct, float(_p["max_attack_percentage"]))
	# 规则四（军力优势递增）：归一化优势 = (我-敌)/(我+敌)，超起点按增益抬升
	var total: float = _own_strength + _enemy_strength
	if total > 0.0:
		var adv: float = (_own_strength - _enemy_strength) / total
		if adv > float(_p["superiority_ratio_floor"]):
			pct += (adv - float(_p["superiority_ratio_floor"])) * float(_p["superiority_gain"])
			pct = minf(pct, float(_p["max_attack_percentage"]))
	# 规则二（基地威胁封顶）：硬帽最后施加，危巢之下不出兵
	var threat: float = threat_at_base()
	if threat > float(_p["base_threat_threshold"]):
		pct = minf(pct, maxf(100.0 - threat, float(_p["base_threat_floor"])) / 100.0)
	# 规则一（胜利目标危急）：开放问题#1 缺省关闭；开关位与实现钩子留待 VP 等价物
	if bool(_p.get("vp_rule_enabled", false)):
		pct = _apply_victory_objective_rule(pct)
	return clampf(pct, 0.0, 1.0)


## C5 规则一实现钩子（vp_rule_enabled=true 时消费）：本作战役域尚无 VP 等价物
## （开放问题#1【提案/待定】），接入旗/区域控制后在此映射"危急度抬升 / 我方占优
## 翻转防守"。当前恒返输入值（关闭语义）。
func _apply_victory_objective_rule(pct: float) -> float:
	return pct


## 基地威胁值（0-100 口径，CoH threat_at_base 语义映射）：锚点半径内（enemy_close_dist）
## 敌军力量 / 本方初始力量基线 × 100；基线缺失/为零 → 0（无基准不判威胁）。
func threat_at_base() -> float:
	if _initial_own_strength <= 0.0:
		return 0.0
	return _enemy_strength_near_base / _initial_own_strength * 100.0


## 攻击槽创建/维持门禁（SWL 比例条件的槽语义转写，咬合③）：
## 创建 = 开局门禁过 ∧ ratio ≥ attack_enter（SWL enter 条件，驻守期同判）；
## 维持 = ATTACK 态 ∧ ratio > attack_exit（SWL 滞回带——带内不塌槽，姿态不抖）。
func _slot_attack_intent_open() -> bool:
	if not _attack_gate_open():
		return false
	var ratio: float = balance_of_powers_ratio()
	if ratio >= float(_p["attack_enter"]):
		return true
	return _stance == STANCE_ATTACK and ratio > float(_p["attack_exit"])


## GARRISON 重评进攻条件（两内核同判入口）：槽内核 = 存在攻击槽（驻守期建槽
## 门禁 = SWL enter 条件，与旧 garrison_reeval 口径逐位一致）；退化路径 = 原逻辑。
func _garrison_reeval_attack_open() -> bool:
	if _task_board_enabled():
		return _task_board.has_attack_slots()
	return _attack_gate_open() and balance_of_powers_ratio() >= float(_p["attack_enter"])


## 槽同步 + 生命周期（每决策周期一次，CoH strategy_military.execute 同构）：
##   1) 目标超时杀槽/重评分（tick 先行——集结超时杀掉的槽当拍由 sync 重建，
##      无"攻击槽真空拍"窗口，防姿态振荡）；
##   2) 攻/防槽同步：期望进攻槽数 = ceil(attack% × 原子单元数)，防守 = 余量
##      （只增删空槽，从不指定小队——匹配归 match_groups 执行侧）；
##   3) 重定向脏槽重发号令（进攻小队向新目标推进）。
func _update_task_board() -> void:
	if _task_board == null:
		return
	var dirty: Array = _task_board.tick(_now(), _on_slot_retarget)
	var atomic: int = _count_atomic_units()
	var desired: int = 0
	if atomic > 0:
		var pct: float = recalculate_attack_percentage()
		if pct > 0.0 and _slot_attack_intent_open():
			desired = mini(int(ceil(pct * float(atomic))), atomic)
	# 攻击槽目标 = 评分最优敌位（新建槽定位用；现存槽不重定位，防逐拍振荡）
	var attack_target: Vector2 = _attack_slot_target(null)
	_task_board.sync_slots(ScriptTaskBoard.KIND_ATTACK, desired, attack_target, _own_centroid, _now())
	_task_board.sync_slots(ScriptTaskBoard.KIND_DEFEND, maxi(atomic - desired, 0), _own_centroid, get_garrison_anchor(), _now())
	if not dirty.is_empty() and _task_board_enabled():
		_issue_retarget_orders(dirty)


## 槽目标重定位回调（TaskBoard.tick 目标超时消费；slot 为 TaskBoard.TaskSlot）
func _on_slot_retarget(slot: Variant) -> Vector2:
	if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
		return _attack_slot_target(slot)
	return _own_centroid


## 攻击槽目标定位（C4 四因子 argmax）：候选 = 敌方存活军事单位位置 + 敌方质心
## （去重）；评分参照 = 本方质心（squad 口径）/ 本方锚点（base 口径）/ 敌方力量
## 快照；惯性参照 = 槽现目标（重评分防振荡）。无候选 → 敌方质心（旧 ATTACK 语义）。
func _attack_slot_target(slot: Variant) -> Vector2:
	var candidates: Array = []
	for e in _enemy_units_snapshot:
		var pos: Vector2 = e.get("pos", Vector2.INF)
		if pos.is_finite() and not candidates.has(pos):
			candidates.append(pos)
	if not _enemy_units_snapshot.is_empty() and not candidates.has(_enemy_centroid):
		candidates.append(_enemy_centroid)
	if candidates.is_empty():
		return _enemy_centroid
	var ctx := {
		"squad_pos": _own_centroid,
		"base_pos": get_garrison_anchor(),
		"enemies": _enemy_units_snapshot,
		"own_strength": _own_strength,
		"last_target": slot.target if slot != null else Vector2.INF,
	}
	return _task_board.pick_target(candidates, ctx)


## 原子单元数（槽期望数基数）：组织化编制作一处（编制行军原子）、散兵各一处；
## 编队系统缺失（测试环境）或本方暂无注册小队 → 退化 1（槽逻辑照跑，与 SWL
## 内核"无小队仍切姿态"行为一致；号令侧无小队可发，自然空转）。
func _count_atomic_units() -> int:
	if _formation == null or not is_instance_valid(_formation) \
			or not _formation.has_method("get_all_squads"):
		return 1
	var n := _atomic_groups().size()
	return n if n > 0 else 1


## 原子单元分组（下令路径与槽匹配共用）：组织化编制 = 同组织根的小队一组，
## 散兵各成一组。返回 [{key, squads}]（key = 组织根 id，散兵 = squad_id 自身）。
func _atomic_groups() -> Array:
	var groups: Array = []
	var by_root: Dictionary = {}
	for squad_id_v in _own_combat_squads():
		var squad_id := str(squad_id_v)
		var root := _org_root_of(squad_id)
		if root.is_empty():
			groups.append({"key": squad_id, "squads": [squad_id]})
			continue
		if not by_root.has(root):
			var g := {"key": root, "squads": []}
			by_root[root] = g
			groups.append(g)
		(by_root[root]["squads"] as Array).append(squad_id)
	return groups


## 小队所在组织根（号令系统代理查询；orders 缺失/无代理方法 → "" 散兵口径，
## combat 不直引 organization——模块契约，见 TacticalOrders.get_org_root_for_squad）
func _org_root_of(squad_id: String) -> String:
	if _orders == null or not is_instance_valid(_orders) \
			or not _orders.has_method("get_org_root_for_squad"):
		return ""
	return String(_orders.get_org_root_for_squad(squad_id))


## 本阵营战斗小队列表（执行侧匹配与号令的统一取数口；序 = 编队注册序，稳定可断言）
func _own_combat_squads() -> Array:
	if _formation == null or not is_instance_valid(_formation) \
			or not _formation.has_method("get_all_squads"):
		return []
	var result: Array = []
	for squad_id_v in _formation.get_all_squads():
		var squad_id := str(squad_id_v)
		if _is_own_combat_squad(squad_id):
			result.append(squad_id)
	return result


# ─────────────────────────────── 快照刷新（每决策周期重建，O(n)）────────────────────────────────

## 遍历双方存活单位各至多一次：军事单位数/力量值/质心/投射物威胁布尔。
## 不缓存跨周期单位引用（防 freed 悬挂）；逐引用 is_instance_valid 校验（BattleInstance 惯例）。
func _refresh_snapshot() -> void:
	var own_alive: int = 0
	var enemy_alive: int = 0
	var own_military: int = 0
	var enemy_military: int = 0
	var own_sum := Vector2.ZERO
	var enemy_sum := Vector2.ZERO
	var own_wsum: float = 0.0
	var enemy_wsum: float = 0.0
	var threatened: bool = false
	var now_real: float = Time.get_ticks_msec() / 1000.0
	var window: float = float(_p["projectile_window"])
	# A2 取数：敌方军事单位快照（C4 评分候选）+ 基地半径内敌军力量（C5 基地威胁）
	var enemy_snapshot: Array = []
	var near_base_strength: float = 0.0
	var base_dist: float = float(_p["enemy_close_dist"])
	var anchor: Vector2 = get_garrison_anchor()

	# 本方/敌方分别取数（faction 用 1/2 编码，非对称负数；get_enemies_of 取敌方）
	var own_units: Array = []
	var enemy_units: Array = []
	if _battle != null and is_instance_valid(_battle):
		if _battle.has_method("get_allies_of"):
			own_units = _battle.get_allies_of(_faction)
		if _battle.has_method("get_enemies_of"):
			enemy_units = _battle.get_enemies_of(_faction)
	for u in own_units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var pos: Vector2 = u.global_position if u is Node2D else Vector2.ZERO
		var weight: float = ScriptTeamAiProfiles.get_unit_weight(_p, _weapon_type_of(u))
		own_alive += 1
		own_sum += pos
		if weight > 0.0:
			own_military += 1
			own_wsum += weight
			# 投射物来袭登记（现实秒）：窗口内被瞄准即真（暂停期 TeamAi 不 tick，混源影响可忽略）
			if not threatened and "arrow_threat_time" in u \
					and now_real - float(u.get("arrow_threat_time")) < window:
				threatened = true
	for u in enemy_units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var pos: Vector2 = u.global_position if u is Node2D else Vector2.ZERO
		var weight: float = ScriptTeamAiProfiles.get_unit_weight(_p, _weapon_type_of(u))
		enemy_alive += 1
		enemy_sum += pos
		if weight > 0.0:
			enemy_military += 1
			enemy_wsum += weight
			# C4 评分候选（值拷贝，不持引用）；C5 基地威胁（锚点半径内敌军力量）
			enemy_snapshot.append({"pos": pos, "weight": weight})
			if pos.distance_to(anchor) < base_dist:
				near_base_strength += weight

	_num_military = own_military
	_num_enemy_military = enemy_military
	_own_centroid = own_sum / float(own_alive) if own_alive > 0 else Vector2.ZERO
	_enemy_centroid = enemy_sum / float(enemy_alive) if enemy_alive > 0 else Vector2.ZERO
	_own_strength = own_wsum
	_enemy_strength = enemy_wsum
	_own_threatened = threatened
	_enemy_units_snapshot = enemy_snapshot
	_enemy_strength_near_base = near_base_strength


## duck 读取单位武器类型（无武器挂载 → 返回 PICKAXE（权重 0，非军事），不影响力量统计）
func _weapon_type_of(u: Node) -> int:
	if u.has_method("get_weapon"):
		var w: Node = u.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w:
			return int(w.get("weapon_type"))
	return ScriptTeamAiProfiles.PICKAXE


## 扫描某阵营存活单位是否含指定类别（TeamHasAGiant 消费；P8 巨人落地前恒假属预期）
func _scan_faction_for_type(faction: int, wtype: int) -> bool:
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_allies_of"):
		return false
	for u in _battle.get_allies_of(faction):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		if _weapon_type_of(u) == wtype:
			return true
	return false


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


## 姿态→号令映射器（TeamAi 的唯一执行通道：只消费 TacticalOrders，不改号令系统行为）。
## A2 槽内核（ATTACK 态）：小队经 match_groups 匹配任务槽——攻击槽绑定小队 →
## ADVANCE_ALL 槽目标（评分最优敌位）；未绑定/防守槽 → ADVANCE_ALL 本方质心
## （防守位兜底）。DEFEND → ADVANCE_ALL 本方质心（回聚合防线坚守，不消费槽）；
## GARRISON → RALLY 己方锚点（围圈驻点，生存模式不走槽）；ROUT → RETREAT(evacuate)
## 全军战役撤离（撤至己方侧边缘登记 departed，C3 敌将撤仗）。
## 下令路径收敛（设计文档 §四）：组织化编制经 issue_to_org 逐跳传播（编制=原子，
## 同根一号令一轮内去重）；散兵经 issue 直令（现场电台零延迟）。玩家手动号令
## 保护期 > 姿态自动号令：散兵逐队避让；编制任一成员保护期内整组避让（玩家意图
## 压过编制号令，下轮姿态切换/槽重发恢复）。
## 常规姿态仅切换时下发一次（维持期不重发，防号令风暴）；ROUT 例外——维持期由
## stance_update 每决策周期重发（溃逃抢占兜底，见 §4.2）；攻击槽目标超时重定向
## 由 _issue_retarget_orders 重发绑定小队。
func _issue_stance_orders() -> void:
	if _stance == STANCE_ROUT:
		_issue_orders(_own_combat_squads(), {}, ScriptTacticalOrders.OrderType.RETREAT,
				Vector2.ZERO, {"evacuate": true})
		return
	var squads: Array = _own_combat_squads()
	if squads.is_empty():
		return
	# 执行侧小队匹配（A2 C3）：序位在前攻击槽数的原子单元组绑攻击槽，其余绑防守
	var mapping: Dictionary = {}
	if _task_board_enabled():
		mapping = _task_board.match_groups(_atomic_groups())
	var plan_of: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		match _stance:
			STANCE_ATTACK:
				var target: Vector2 = _enemy_centroid  # 退化语义（槽内核关闭时旧目标）
				if _task_board_enabled():
					# 槽驱动：攻击槽绑定 → 槽目标；未绑定/防守槽 → 本方质心防守位
					target = _own_centroid
					var slot: Variant = _task_board.get_slot(str(mapping.get(squad_id, "")))
					if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
						target = slot.target
				plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": target}
			STANCE_DEFEND:
				plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": _own_centroid}
			STANCE_GARRISON:
				plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.RALLY, "target": get_garrison_anchor()}
			_:
				pass
		# A4 default_behavior v2：无显式号令（防守兜底/未绑定）小队按效用打分选行为
		# （追加钩子，开关默认关 = 原样返回零回归；见 _apply_default_behavior_plans）
		plan_of = _apply_default_behavior_plans(plan_of, mapping)
	_issue_orders(squads, plan_of)


## 攻击槽目标重定向重发（TaskBoard.tick 目标超时 → 脏槽的绑定小队向新目标推进）
func _issue_retarget_orders(dirty_slot_ids: Array) -> void:
	var squads: Array = _own_combat_squads()
	if squads.is_empty() or dirty_slot_ids.is_empty():
		return
	var plan_of: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		var slot_id := _task_board.slot_of_squad(squad_id)
		if slot_id.is_empty() or not dirty_slot_ids.has(slot_id):
			continue
		var slot: Variant = _task_board.get_slot(slot_id)
		if slot == null:
			continue
		plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": slot.target}
	if not plan_of.is_empty():
		_issue_orders(squads, plan_of)


## 号令下发执行（唯一出口）：逐小队查计划 → 手动号令保护期避让 → 路径分流。
## plan_of 为空且给定 order_type 时全员同令（ROUT 撤离路径）。
## 保护期语义：散兵逐队避让；编制组（同组织根）任一成员在保护期内 → 整组避让。
## 路径分流：有组织根 ∧ 号令系统支持 issue_to_org → 编制根一号令（同根去重）；
## 否则散兵 issue 直令。issue 拒绝（职责校验/空队）→ 跳过不重试，下一决策周期
## 随姿态重评自然恢复（既有口径）。
func _issue_orders(squads: Array, plan_of: Dictionary, order_type: int = -1,
		target: Vector2 = Vector2.ZERO, extra_params: Dictionary = {}) -> void:
	if _orders == null or not is_instance_valid(_orders) or not _orders.has_method("issue"):
		return
	var issued_roots: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		# 玩家手动号令保护期：玩家手动号令 > 姿态自动号令（硬约束，spec §5.2.1.2a）
		if _is_manual_order_active(squad_id):
			continue
		var root := _org_root_of(squad_id)
		if not root.is_empty():
			# 编制原子性守卫：组内任一成员保护期内 → 整组本轮避让
			var group_guarded: bool = false
			for other_v in squads:
				var other := str(other_v)
				if other != squad_id and _is_manual_order_active(other) and _org_root_of(other) == root:
					group_guarded = true
					break
			if group_guarded:
				continue
			# 同根一号令（编制行军原子；issue_to_org 计划天然覆盖组内全部 L1）
			if issued_roots.has(root):
				continue
			issued_roots[root] = true
		var p_order: int = order_type
		var p_target: Vector2 = target
		var p_extra: Dictionary = extra_params
		if not plan_of.is_empty():
			var plan: Dictionary = plan_of.get(squad_id, {})
			if plan.is_empty():
				continue
			p_order = int(plan.get("order_type", order_type))
			p_target = plan.get("target", target)
			p_extra = plan.get("extra", {})
		if p_order < 0:
			continue
		if not root.is_empty() and _orders.has_method("issue_to_org"):
			# 组织化编制：走 org 入口逐跳传播（号令语义参数增量随计划透传）
			_orders.issue_to_org(root, p_order, p_target, p_extra)
		else:
			_orders.issue(p_order, squad_id, p_target, SOURCE_TIER_AI, p_extra)


## 本阵营战斗小队判定：成员 get_faction 多数派 == 本阵营 ∧ is_combat_squad。
## 小队无阵营归属字段（FormationSystem 全局单例），多数派判定稳定（战斗中 faction 固定）。
func _is_own_combat_squad(squad_id: String) -> bool:
	if _formation == null or not is_instance_valid(_formation):
		return false
	if _formation.has_method("is_combat_squad") and not _formation.is_combat_squad(squad_id):
		return false
	if not _formation.has_method("get_squad_units"):
		return false
	var units: Array = _formation.get_squad_units(squad_id)
	if units.is_empty():
		return false
	var own: int = 0
	var total: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("get_faction"):
			continue
		total += 1
		if int(u.get_faction()) == _faction:
			own += 1
	if total <= 0:
		return false
	return own * 2 > total


## 小队是否有存活战斗成员（空队/全灭队不调 issue，避免号令系统 push_warning 噪音）
func _squad_has_alive_combatant(squad_id: String) -> bool:
	if _formation == null or not is_instance_valid(_formation) or not _formation.has_method("get_squad_units"):
		return false
	for u in _formation.get_squad_units(squad_id):
		if u != null and is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			return true
	return false


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


# ─────────────────────────────── default_behavior v2 效用打分（A4 · C7，非 dump 直译）────────────────────────────────
## CoH tactics.ai demand 系统同构（docs/审计/英雄连AI逆向_2026-09-11.md §3.5，评分实现
## 归 UtilityScorer，本段只做组织配置取数 / 小队上下文快照 / 接入点门禁）。

## 组织 API 引用显式注入（测试/宿主装配出口；不调用时走 _resolve_org_api 同模块探测）
func set_org_api(api: Node) -> void:
	_org_api = api


## 组织 API 同模块 duck 探测：号令系统（TacticalOrders）装配时已持 _org_api 引用，
## 本文件不动禁碰面，经 Object.get 同模块反射读取（combat 域内私有桥；TacticalOrders
## 未来开放组织代理方法时迁移）。探测失败保持现状（散兵/测试环境 = 无组织消费）。
func _resolve_org_api() -> Node:
	if _org_api != null and is_instance_valid(_org_api):
		return _org_api
	if _orders != null and is_instance_valid(_orders):
		var api: Variant = _orders.get("_org_api")
		if api is Node and is_instance_valid(api):
			return api
	return null


## 组织 default_behavior 只读查询（org API get_organization 快照；失败/缺字段 = {}）
## 禁改组织存储格式——本方法纯消费（模块契约：combat 不直引 organization，经 duck api）
func _org_default_behavior(org_id: String) -> Dictionary:
	if _org_api == null or not is_instance_valid(_org_api) \
			or not _org_api.has_method("get_organization"):
		return {}
	var info: Dictionary = _org_api.get_organization(org_id)
	if not info.get("ok", false):
		return {}
	var data: Dictionary = info.get("data", {})
	var behavior: Variant = data.get("default_behavior", {})
	return behavior if behavior is Dictionary else {}


## 小队行为上下文（UtilityScorer 消费口径；敌人取决策周期值拷贝快照，防 freed 悬挂）
func _squad_behavior_ctx(squad_id: String) -> Dictionary:
	return {
		"squad_pos": _squad_centroid(squad_id),
		"enemies": _enemy_units_snapshot,
		"own_centroid": _own_centroid,
		"enemy_centroid": _enemy_centroid,
		"anchor": get_garrison_anchor(),
		"threatened": _own_threatened,
		"own_strength": _own_strength,
		"initial_own_strength": _initial_own_strength,
		"now": _now(),
	}


## 小队存活成员质心（编队缺失/空队退化本方质心——与防守兜底目标语义一致）
func _squad_centroid(squad_id: String) -> Vector2:
	if _formation == null or not is_instance_valid(_formation) \
			or not _formation.has_method("get_squad_units"):
		return _own_centroid
	var sum := Vector2.ZERO
	var n: int = 0
	for u in _formation.get_squad_units(squad_id):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		sum += u.global_position if u is Node2D else Vector2.ZERO
		n += 1
	return sum / float(n) if n > 0 else _own_centroid


## default_behavior 扰动种子（按小队错峰的 base；同 setup 显式 random_seed，确定性可锁）
func _behavior_seed() -> int:
	return int(_rng.seed)


## default_behavior v2 接入点（追加钩子，不改既有号令语义）：
## 只接管「无显式号令」的小队——攻/防姿态下未绑攻击槽、落防守兜底（ADVANCE_ALL
## 本方质心）的原子单元小队；攻击槽绑定小队有任务槽号令不接管；GARRISON（生存模式
## RALLY）与 ROUT（战役撤离）不经本钩子（ROUT 路径在 stance_update 提前返回）。
## 开关关（default_behavior_v2_enabled 默认关）/ 组织无配置 / 打分无候选 → 原样返回
## （零回归）。组织根经 _org_root_of 查询（同既有号令分流口径），root 缺失 = 散兵不消费。
func _apply_default_behavior_plans(plan_of: Dictionary, mapping: Dictionary) -> Dictionary:
	if _utility_scorer == null or not bool(_p.get("default_behavior_v2_enabled", false)):
		return plan_of
	if _stance != STANCE_ATTACK and _stance != STANCE_DEFEND:
		return plan_of
	for squad_id_v in plan_of.keys():
		var squad_id := str(squad_id_v)
		var plan: Dictionary = plan_of[squad_id]
		# 只接管防守兜底小队（ADVANCE_ALL 语义）；RALLY 等其他号令一律不碰
		if int(plan.get("order_type", -1)) != ScriptTacticalOrders.OrderType.ADVANCE_ALL:
			continue
		# 攻击槽绑定 = 显式任务号令，不接管
		var slot_id := str(mapping.get(squad_id, ""))
		if not slot_id.is_empty() and _task_board != null:
			var slot: Variant = _task_board.get_slot(slot_id)
			if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
				continue
		var root := _org_root_of(squad_id)
		if root.is_empty():
			continue
		var behavior := _org_default_behavior(root)
		if behavior.is_empty():
			continue
		var choice := _utility_scorer.pick_behavior(behavior, _squad_behavior_ctx(squad_id),
				squad_id, _behavior_seed())
		if choice.is_empty():
			continue
		plan_of[squad_id] = {
			"order_type": int(choice["order_type"]),
			"target": choice["target"],
		}
		_default_behavior_choices[squad_id] = str(choice.get("name", ""))
	return plan_of


## 最近一轮 default_behavior 选择快照（只读副本；调试 HUD / 测试断言）
func get_default_behavior_choices() -> Dictionary:
	return _default_behavior_choices.duplicate()


# ─────────────────────────────── 内部工具 ────────────────────────────────

## 战斗秒时钟（battle.get_duration()：暂停冻结、随宿主；battle 失效返回 -inf 不推进）
func _now() -> float:
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_duration"):
		return -1.0e9
	return float(_battle.get_duration())