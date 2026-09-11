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

## 同模块档案（显式 preload，headless 防御惯例 §七.3）
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

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

## 节流计时器三件套（dump 字段直译：_lastStanceChangeTime/_lastGarrisonTime/_lastBuildUpdate；
## 时钟源 = battle.get_duration() 战斗秒：暂停冻结、随宿主）
var _last_stance_change_time: float = -1.0e9
var _last_garrison_time: float = -1.0e9
var _last_build_update: float = -1.0e9

## 手动号令保护期：squad_id -> 保护截止时刻（战斗秒）
var _manual_order_until: Dictionary = {}


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
	# 开局攻击门禁掷骰：基准 ± 方差半宽一次定局（CoH standard 9min±4min 同构；
	# 默认固定种子 → 门禁确定性，单测可锁、battle_sim 可复现）
	_rng.seed = int(overrides.get("random_seed", ScriptTeamAiProfiles.DEFAULT_RANDOM_SEED))
	var base_time: float = float(_p["seconds_before_attack"])
	var variance: float = maxf(float(_p["start_attack_variance"]), 0.0)
	_attack_deadline = base_time + _rng.randf_range(-variance, variance)
	# 手动号令保护期守卫：订阅全局号令事件（tier=0 玩家直令刷新保护时间戳）
	if EventBus != null and EventBus.has_signal("order_issued") \
			and not EventBus.order_issued.is_connected(_on_order_issued):
		EventBus.order_issued.connect(_on_order_issued)


## 消亡钩子（宿主 _end 调用）：断开 EventBus 订阅，防 freed 悬空连接。
func dispose() -> void:
	if EventBus != null and EventBus.has_signal("order_issued") \
			and EventBus.order_issued.is_connected(_on_order_issued):
		EventBus.order_issued.disconnect(_on_order_issued)


## 装配引用补注入（宿主 set_order_refs 转发；orders/formation 允许 null）
func set_order_refs(orders: Node, formation: Node) -> void:
	_orders = orders
	_formation = formation


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
	# 驻守触发集优先于力量条件（非 GARRISON 态；受全姿态切换冷却节流）
	if _stance != STANCE_GARRISON:
		if _can_change_stance() and should_garrison():
			_set_stance(STANCE_GARRISON, "garrison_triggers")
			_last_garrison_time = _now()
			return
	# GARRISON 维持与重评（WeRecentlyDecidedToGarrison 语义：驻守冷却内不重评）
	if _stance == STANCE_GARRISON:
		if not should_garrison() and not we_recently_decided_to_garrison():
			# 触发集全假 ∧ 驻守冷却满 → 按力量条件重评（此处不受"非 GARRISON"门禁，
			# 重评本身就是解除驻守的决策；开局门禁仍然生效）
			if _attack_gate_open() and balance_of_powers_ratio() >= float(_p["attack_enter"]):
				_set_stance(STANCE_ATTACK, "garrison_reeval_attack")
			else:
				_set_stance(STANCE_DEFEND, "garrison_reeval_defend")
		return
	# 力量条件（受切换冷却节流；迟滞带内维持现态）
	if not _can_change_stance():
		return
	if should_attack():
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

	_num_military = own_military
	_num_enemy_military = enemy_military
	_own_centroid = own_sum / float(own_alive) if own_alive > 0 else Vector2.ZERO
	_enemy_centroid = enemy_sum / float(enemy_alive) if enemy_alive > 0 else Vector2.ZERO
	_own_strength = own_wsum
	_enemy_strength = enemy_wsum
	_own_threatened = threatened


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


## 姿态→号令映射器（TeamAi 的唯一执行通道：只消费 TacticalOrders.issue，不改号令系统行为）。
## ATTACK → ADVANCE_ALL 敌军质心（formation 散开）；DEFEND → ADVANCE_ALL 本方质心（回聚合
## 防线坚守）；GARRISON → RALLY 己方锚点（围圈驻点，途中 engage_in_range 近身自卫）；
## ROUT → RETREAT(evacuate) 全军战役撤离（撤至己方侧边缘登记 departed，C3 敌将撤仗）。
## 目标点取切换时刻快照；常规姿态仅切换时下发一次（维持期不重发，防号令风暴），
## ROUT 例外——维持期由 stance_update 每决策周期重发（溃逃抢占兜底，见 §4.2）。
func _issue_stance_orders() -> void:
	if _orders == null or not is_instance_valid(_orders) or not _orders.has_method("issue"):
		return
	var order_type: int = -1
	var target := Vector2.ZERO
	var extra_params: Dictionary = {}
	match _stance:
		STANCE_ATTACK:
			order_type = ScriptTacticalOrders.OrderType.ADVANCE_ALL
			target = _enemy_centroid
		STANCE_DEFEND:
			order_type = ScriptTacticalOrders.OrderType.ADVANCE_ALL
			target = _own_centroid
		STANCE_GARRISON:
			order_type = ScriptTacticalOrders.OrderType.RALLY
			target = get_garrison_anchor()
		STANCE_ROUT:
			order_type = ScriptTacticalOrders.OrderType.RETREAT
			extra_params = {"evacuate": true}
		_:
			return
	if _formation == null or not is_instance_valid(_formation) or not _formation.has_method("get_all_squads"):
		return
	for squad_id_v in _formation.get_all_squads():
		var squad_id: String = str(squad_id_v)
		# 预过滤：本阵营多数派 ∧ 战斗职责 ∧ 存活战斗成员（空队不调 issue，避免 push_warning 噪音）
		if not _is_own_combat_squad(squad_id):
			continue
		# 手动号令保护期：玩家手动号令 > 姿态自动号令（硬约束，spec §5.2.1.2a）
		if _is_manual_order_active(squad_id):
			continue
		# issue 拒绝（职责校验/空队）→ 跳过不重试，下一决策周期随姿态重评自然恢复
		_orders.issue(order_type, squad_id, target, SOURCE_TIER_AI, extra_params)


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


# ─────────────────────────────── 内部工具 ────────────────────────────────

## 战斗秒时钟（battle.get_duration()：暂停冻结、随宿主；battle 失效返回 -inf 不推进）
func _now() -> float:
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_duration"):
		return -1.0e9
	return float(_battle.get_duration())