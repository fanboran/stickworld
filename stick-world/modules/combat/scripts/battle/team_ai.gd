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
## 真值声明（§七.9）：dump TeamAi 21 个行为函数均为 IL2CPP 签名级导出、**无方法体**，
## 所有数值阈值为语义推断初值（legend TeamAiParameters 字段结构参考），**均待实测校准**；
## 方法名保留 dump 原名蛇形化，便于执行计划 §三 审计逐函数对账。

## 同模块档案（显式 preload，headless 防御惯例 §七.3）
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 姿态枚举（0=GARRISON/1=DEFEND/2=ATTACK，对齐 dump Team.Stance 枚举序）
const STANCE_GARRISON: int = 0
const STANCE_DEFEND: int = 1
const STANCE_ATTACK: int = 2
## 自动号令发令层级（TeamAi 统一 tier=1；玩家手动号令 tier=0）
const SOURCE_TIER_AI: int = 1
## 玩家手动号令层级（EventBus.order_issued 的 source_tier 语义）
const SOURCE_TIER_PLAYER: int = 0

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

## 决策周期计时器
var _decision_timer: float = 0.0
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
## overrides 仅 setup 期消费一次（TeamAiProfiles.get_profile 浅合并，battle_sim 扫参用）。
func setup(battle: Node, faction: int, orders: Node, formation: Node, overrides: Dictionary = {}) -> void:
	_battle = battle
	_faction = faction
	_orders = orders
	_formation = formation
	_p = ScriptTeamAiProfiles.get_profile(overrides)
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


## 宿主 tick（BattleInstance._physics_process 内调用，每物理帧进入、内部低频节流）。
## 后置：至多完成一次决策周期；姿态变更时号令已受理或已跳过（不排队）。
func tick(delta: float) -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	# 决策门禁双保险（宿主已保证 ENGAGED + 未暂停，TeamAi 再自检一层）
	if not _battle.has_method("is_active") or not _battle.is_active():
		return
	if TimeManager != null and TimeManager.is_paused():
		return
	_decision_timer += delta
	if _decision_timer < float(_p["stance_decision_interval"]):
		return
	_decision_timer = 0.0
	update()


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


# ─────────────────────────────── 直译函数族（21 函数，按 dump 原名蛇形）────────────────────────────────

## [dump #1 Update] 编排入口：姿态决策 → 造兵桩（由宿主 tick 驱动）。
func update() -> void:
	stance_update()
	build_units_update()


## [dump #2 StanceUpdate] 姿态机决策编排（组合顺序无 dump 真值：驻守触发集 > 力量条件，
## 理由：驻守条件是生存开关，被力量条件压过会导致濒危阵营继续压上——设计决策，待实测校准）。
func stance_update() -> void:
	_refresh_snapshot()
	# 本方无军事单位：决策静默空转（无号令对象）
	if _num_military <= 0:
		return
	# 初始力量基线（首个有效快照登记，供 no_defender_floor 比例分母）
	if _initial_own_strength < 0.0:
		_initial_own_strength = _own_strength
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


## 开局攻击门禁（SecondsBeforeCanLeaveBase 语义近似）：时长未满即便力量占优不切 ATTACK
func _attack_gate_open() -> bool:
	return _now() >= float(_p["seconds_before_attack"])


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
## 防线坚守）；GARRISON → RALLY 己方锚点（围圈驻点，途中 engage_in_range 近身自卫）。
## 目标点取切换时刻快照；仅姿态切换时下发一次（维持期不重发，防号令风暴）。
func _issue_stance_orders() -> void:
	if _orders == null or not is_instance_valid(_orders) or not _orders.has_method("issue"):
		return
	var order_type: int = -1
	var target := Vector2.ZERO
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
		_orders.issue(order_type, squad_id, target, SOURCE_TIER_AI)


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