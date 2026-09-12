extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：小队相位计划（A5 · 设计文档12号 C8，CoH squadai infantry-plan 简化直译）。
## 角色分派（位置×素质双维）+ 相位切换（核心跃进→随机等待→两翼跟进→循环推进）
## + 末跳完成 + 接敌反应（背敌/被压制代理 → 既有 seek_cover）+ 守卫不打断
## + 缺省关闭零回归 + 计划=数据资源装载。
## 不进场景树（_process 不触发，直接调 _tick_phase_plans），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")
const ScriptSquadPhasePlan := preload("res://modules/combat/scripts/command/squad_phase_plan.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


class FakeOrgApi:
	extends Node
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass

	## 独立 L1 桩：每个组织自身即根（无 parent_org），供组织号令通知路径解析
	func get_organization(org_id: String) -> Dictionary:
		return {"ok": true, "data": {"id": org_id, "parent_org": ""}}


## AI 控制器桩：记录号令，行为状态可强制（守卫测试用）
class FakeAI:
	extends Node
	var orders: Array = []  ## [{behavior, params}] 全量下发记录
	var _ordered_behavior: String = ""
	var _ordered_params: Dictionary = {}
	var cur_behavior: String = "idle"

	func set_order(b: String, p: Dictionary = {}) -> void:
		orders.append({"behavior": b, "params": p.duplicate()})
		_ordered_behavior = b
		_ordered_params = p.duplicate()
		cur_behavior = b

	func clear_order() -> void:
		_ordered_behavior = ""
		_ordered_params = {}

	func has_order() -> bool:
		return not _ordered_behavior.is_empty()

	func get_ordered_behavior() -> String:
		return _ordered_behavior

	func get_ordered_params() -> Dictionary:
		return _ordered_params

	func get_current_behavior() -> String:
		return cur_behavior

	## 强制行为状态（不产生号令记录；守卫测试用）
	func force_behavior(b: String) -> void:
		cur_behavior = b

	## 强制他人号令（不产生号令记录；玩家号令不覆盖测试用）
	func force_order(b: String, p: Dictionary) -> void:
		_ordered_behavior = b
		_ordered_params = p.duplicate()

	func orders_for(b: String) -> int:
		var n := 0
		for o in orders:
			if o.behavior == b:
				n += 1
		return n


## 单位桩：faction + battle + ai + 素质代理（max_hp 挂自身，get_health 返回 self）
class FakeUnit:
	extends Node2D
	var faction_id: int = 1
	var battle: Node = null
	var ai: Node = null
	var _dead: bool = false
	var max_hp: float = 100.0
	var arrow_threat_time: float = -1000.0  ## 被瞄准登记（现实秒；默认久远 = 未被压制）

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_ai_controller() -> Node:
		return ai

	func get_health() -> Node:
		return self


class FakeEnemy:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead


## 战斗桩：get_enemies_of + is_active
class FakeBattle:
	extends Node
	var enemies: Array = []

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func is_active() -> bool:
		return true


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("角色分派: 同质 9 人 → 前列 4 核心 + 素质并列首员侦察 + 右翼余员", _test_roles_baseline)
	_runner.add_test("角色分派: 素质维——高血量夺侦察但夺不了核心（位置维优先）", _test_roles_quality)
	_runner.add_test("角色分派: 侧翼按锚朝向横向分左右", _test_roles_flank_sides)
	_runner.add_test("相位切换: 核心组先行→随机等待→两翼跟进→循环推进跃进线", _test_phase_cycle)
	_runner.add_test("W1 观测信号: phase_changed / roles_reassigned（§2.6 接口缺口）", _test_w1_signals)
	_runner.add_test("相位切换: 末跳（跃进线=终点）全员到位后计划完成", _test_final_leg_done)
	_runner.add_test("接敌反应: 背敌成员 → seek_cover（既有行为接入）", _test_back_enemy_cover)
	_runner.add_test("接敌反应: 被瞄准（被压制代理）成员 → seek_cover", _test_suppressed_cover)
	_runner.add_test("守卫: 士气行为/玩家号令/接战成员不被相位号令打断", _test_guards)
	_runner.add_test("零回归: 缺省关闭无计划；其余号令撤销计划", _test_default_off)
	_runner.add_test("触发: 组织号令通知整编制入计划", _test_org_notify)
	_runner.add_test("计划=数据: 资源装载与缺省关闭（config/ai/squad_phase_plan.tres）", _test_resource)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造：formation + n 个带 AI 桩的单位（同点出生 → 槽位序 = 入队序，确定性）。
## 返回 {"fs", "units", "sid"}
func _make_world(n: int, pos: Vector2 = Vector2(200, 500)) -> Dictionary:
	var fs: Node = ScriptFormationSystem.new()
	var org: Node = FakeOrgApi.new()
	fs.setup(org)
	var units: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "U%d" % i
		u.position = pos
		u.ai = FakeAI.new()
		units.append(u)
	var sid: String = fs.create_squad(units, "相位队")
	return {"fs": fs, "units": units, "sid": sid}


## 开启相位计划（固定种子保确定；生产缺省关闭）
func _enable(fs: Node) -> void:
	fs.set_phase_plan_params({"phase_plan_enabled": true, "rng_seed": 42})


## 推进 n 个 L2 节拍（计划节拍固定 0.5s，与生产 _process 驱动一致；不透传大 delta）
func _beat(fs: Node, times: int = 1) -> void:
	for i in times:
		fs._tick_phase_plans(0.5)


func _roles_of(plan_v: Variant, units: Array) -> Dictionary:
	var result: Dictionary = {}
	for i in units.size():
		result[i] = plan_v.get_role_of(units[i])
	return result


func _test_roles_baseline() -> void:
	var w: Dictionary = _make_world(9)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	_runner.assert_true(fs._squad_phase_plans.has(sid), "推进号令应激活相位计划")
	var plan: Variant = fs._squad_phase_plans[sid]
	var roles := _roles_of(plan, units)
	# core_count = round(9×0.4) = 4：前列优先（slot.x 升序=入队序），同点无素质差
	_runner.assert_equal(roles[0], ScriptSquadPhasePlan.ROLE_CORE, "u0 应为核心")
	_runner.assert_equal(roles[1], ScriptSquadPhasePlan.ROLE_CORE, "u1 应为核心")
	_runner.assert_equal(roles[2], ScriptSquadPhasePlan.ROLE_CORE, "u2 应为核心")
	_runner.assert_equal(roles[3], ScriptSquadPhasePlan.ROLE_CORE, "u3 应为核心")
	# 侦察：余员素质并列 → 槽位靠前者（u4）
	_runner.assert_equal(roles[4], ScriptSquadPhasePlan.ROLE_SCOUT, "u4 应为侦察（余员槽位最靠前）")
	# 双翼：同点出生横向位置全 0（≥0）→ 全右翼（确定性退化）
	for i in range(5, 9):
		_runner.assert_equal(roles[i], ScriptSquadPhasePlan.ROLE_RFLANK, "u%d 应为右翼" % i)


func _test_roles_quality() -> void:
	var w: Dictionary = _make_world(9)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	# u8 在末列（slot.x=2）：高血量夺侦察，但夺不了核心（位置维优先于素质维）
	units[8].max_hp = 500.0
	_enable(fs)
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	var plan: Variant = fs._squad_phase_plans[sid]
	var roles := _roles_of(plan, units)
	_runner.assert_equal(roles[8], ScriptSquadPhasePlan.ROLE_SCOUT, "素质最高者应任侦察")
	for i in range(0, 4):
		_runner.assert_equal(roles[i], ScriptSquadPhasePlan.ROLE_CORE, "高血量末列成员不应挤掉前列核心（u%d）" % i)


func _test_roles_flank_sides() -> void:
	var w: Dictionary = _make_world(5)
	var fs: Node = w["fs"]
	var sid: String = w["sid"]
	# 横向摆位：u3 在质心上方（lat<0 → 左翼）、u4 在下方（lat>0 → 右翼）
	w["units"][3].position = Vector2(200, 400)
	w["units"][4].position = Vector2(200, 600)
	var plan: Variant = ScriptSquadPhasePlan.new()
	plan.setup(fs, ScriptSquadPhasePlan.DEFAULTS.duplicate())
	var slots: Dictionary = fs.get_squad_slots(sid)
	var anchor: Dictionary = fs.get_squad_anchor(sid)
	var roles: Dictionary = plan.assign_roles(w["units"], slots, anchor, Callable(fs, "get_unit_quality"))
	# core_count = round(5×0.4) = 2：u0,u1（槽位列 0，入队序）
	_runner.assert_equal(str(roles[w["units"][0].get_instance_id()]), ScriptSquadPhasePlan.ROLE_CORE, "u0 应为核心")
	_runner.assert_equal(str(roles[w["units"][1].get_instance_id()]), ScriptSquadPhasePlan.ROLE_CORE, "u1 应为核心")
	_runner.assert_equal(str(roles[w["units"][2].get_instance_id()]), ScriptSquadPhasePlan.ROLE_SCOUT, "u2 应为侦察")
	_runner.assert_equal(str(roles[w["units"][3].get_instance_id()]), ScriptSquadPhasePlan.ROLE_LFLANK, "u3（横向负侧）应为左翼")
	_runner.assert_equal(str(roles[w["units"][4].get_instance_id()]), ScriptSquadPhasePlan.ROLE_RFLANK, "u4（横向正侧）应为右翼")


func _test_phase_cycle() -> void:
	var w: Dictionary = _make_world(6)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	var plan: Variant = fs._squad_phase_plans[sid]
	# 第一拍：核心组（u0,u1 核心 + u2 侦察）跃进，两翼不动
	fs._tick_phase_plans(0.5)
	_runner.assert_true(plan.is_active(), "计划应激活")
	_runner.assert_equal(plan.get_phase_name(), "core_leap", "首相应为核心跃进")
	_runner.assert_gt(units[0].ai.orders_for("move"), 0, "核心成员应收到跃进号令")
	_runner.assert_gt(units[1].ai.orders_for("move"), 0, "核心成员应收到跃进号令")
	_runner.assert_gt(units[2].ai.orders_for("move"), 0, "侦察应随核心组前出")
	_runner.assert_equal(units[3].ai.orders_for("move"), 0, "两翼不应在核心相位收到号令")
	_runner.assert_true(units[0].ai.get_ordered_params().get("phase_order", false), "跃进号令应带 phase_order 标记")
	# 核心组到位 → 全队还击等待（随机 2~4s 去同步）
	for i in range(3):
		units[i].global_position = units[i].ai.get_ordered_params().get("target", Vector2.ZERO)
	fs._tick_phase_plans(0.5)
	_runner.assert_equal(plan.get_phase_name(), "core_wait", "核心到位后应进还击等待")
	_runner.assert_true(plan._wait_duration >= 2.0, "核心等待应 ≥ wait_core_min（CoH 2s 真值）")
	_runner.assert_true(plan._wait_duration <= 4.0, "核心等待应 ≤ wait_core_max（CoH 4s 真值）")
	# 等待耗尽 → 两翼跟进相位（多拍耗尽 2~4s 随机等待）
	_beat(fs, 12)
	_runner.assert_equal(plan.get_phase_name(), "flank_leap", "等待耗尽应进两翼跟进")
	_beat(fs)
	_runner.assert_gt(units[3].ai.orders_for("move"), 0, "右翼应收到跟进号令")
	_runner.assert_gt(units[4].ai.orders_for("move"), 0, "左翼应收到跟进号令")
	_runner.assert_gt(units[5].ai.orders_for("move"), 0, "右翼应收到跟进号令")
	# 两翼到位 → 跟进等待 → 新循环：跃进线朝终点推进
	for i in range(3, 6):
		units[i].global_position = units[i].ai.get_ordered_params().get("target", Vector2.ZERO)
	fs._tick_phase_plans(0.5)
	_runner.assert_equal(plan.get_phase_name(), "flank_wait", "两翼到位后应进跟进等待")
	var before: int = units[0].ai.orders_for("move")
	_beat(fs, 12)
	_runner.assert_equal(plan.get_phase_name(), "core_leap", "跟进等待耗尽应进下一轮核心跃进")
	var line_x: float = plan.get_leap_line().x
	_runner.assert_gt(line_x, 480.0, "跃进线应越过首轮位置（交替推进）")
	_runner.assert_lt(line_x, 1000.0, "跃进线不应越过终点")
	# 新循环核心组应收到推进后的新跃进号令（剩余路程 > arrive_tolerance）
	_beat(fs)
	_runner.assert_gt(units[0].ai.orders_for("move"), before, "新循环核心组应收到推进后的新跃进号令")


## W1（组织界面与AI状态接线 §2.6）：相位/角色变更信号。
## 激活首跳（IDLE→CORE_LEAP）与循环相位边界都发射 phase_changed；角色重排
## （新循环核心跃进入口）发射 roles_reassigned，均携带小队 id。
func _test_w1_signals() -> void:
	var w: Dictionary = _make_world(6)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	# 激活首跳（直构计划在激活前连接，验证 IDLE→CORE_LEAP 边界）
	var plan2: Variant = ScriptSquadPhasePlan.new()
	plan2.setup(fs, ScriptSquadPhasePlan.DEFAULTS.duplicate())
	var first_events: Array = []
	plan2.phase_changed.connect(func(s: String, f: int, t: int) -> void:
		first_events.append([s, f, t]))
	plan2.activate(sid, Vector2(1000, 500))
	_runner.assert_equal(first_events.size(), 1, "激活首跳应发射一次 phase_changed")
	_runner.assert_equal(str(first_events[0][0]), sid, "信号应携带小队 id")
	_runner.assert_equal(int(first_events[0][1]), ScriptSquadPhasePlan.PH_IDLE, "首跳 from = IDLE")
	_runner.assert_equal(int(first_events[0][2]), ScriptSquadPhasePlan.PH_CORE_LEAP, "首跳 to = 核心跃进")
	plan2.deactivate()
	# 循环相位边界（宿主激活路径；连接晚于激活，观测后续边界）
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	var plan: Variant = fs._squad_phase_plans[sid]
	var phase_events: Array = []
	var role_events: Array = []
	plan.phase_changed.connect(func(s: String, f: int, t: int) -> void:
		phase_events.append({"squad": s, "from": f, "to": t}))
	plan.roles_reassigned.connect(func(s: String) -> void:
		role_events.append(s))
	# 首拍：核心组获跃进号令 → 到位 → CORE_WAIT（phase_changed，无角色信号）
	fs._tick_phase_plans(0.5)
	for i in range(3):
		if units[i].ai.has_order():
			units[i].global_position = units[i].ai.get_ordered_params().get("target", units[i].global_position)
	fs._tick_phase_plans(0.5)
	_runner.assert_equal(phase_events.size(), 1, "进入等待应发射一次 phase_changed")
	_runner.assert_equal(int(phase_events[0]["from"]), ScriptSquadPhasePlan.PH_CORE_LEAP, "from = 核心跃进")
	_runner.assert_equal(int(phase_events[0]["to"]), ScriptSquadPhasePlan.PH_CORE_WAIT, "to = 还击等待")
	_runner.assert_equal(role_events.size(), 0, "等待相位不重排角色")
	# 推进至新循环核心跃进入口（等待→两翼→跟进等待→重排角色；循环节拍逐拍推进）
	for i in range(120):
		fs._tick_phase_plans(0.5)
		if not role_events.is_empty():
			break
	_runner.assert_true(not role_events.is_empty(), "新循环应发射 roles_reassigned（掉员自愈重排）")
	_runner.assert_equal(str(role_events[0]), sid, "角色信号应携带小队 id")
	var last: Dictionary = phase_events[phase_events.size() - 1]
	_runner.assert_equal(int(last["from"]), ScriptSquadPhasePlan.PH_FLANK_WAIT, "角色重排应发生在两翼等待→新循环边界")
	_runner.assert_equal(int(last["to"]), ScriptSquadPhasePlan.PH_CORE_LEAP, "新循环入口 = 核心跃进")
	_runner.assert_true(phase_events.size() >= 3,
			"多相位边界应发射多次 phase_changed（实测 %d）" % phase_events.size())


func _test_final_leg_done() -> void:
	var w: Dictionary = _make_world(4, Vector2(900, 500))
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	# 终点近在 100px（< leap_min_dist）→ 跃进线直接钉终点（末跳）
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	var plan: Variant = fs._squad_phase_plans[sid]
	_runner.assert_true(plan.get_leap_line().distance_to(Vector2(1000, 500)) <= 1.0, "近距目标跃进线应即终点")
	# 核心跃进 → 等待 → 两翼跟进 → 全员到位 → 计划完成
	fs._tick_phase_plans(0.5)
	for i in range(3):
		if units[i].ai.has_order():
			units[i].global_position = units[i].ai.get_ordered_params().get("target", units[i].global_position)
	fs._tick_phase_plans(0.5)
	_beat(fs, 12)
	_beat(fs)
	for i in range(3, 4):
		if units[i].ai.has_order():
			units[i].global_position = units[i].ai.get_ordered_params().get("target", units[i].global_position)
	fs._tick_phase_plans(0.5)
	_runner.assert_false(plan.is_active(), "末跳全员到位后计划应完成")
	_runner.assert_false(fs._squad_phase_plans.has(sid), "完成的计划应从宿主注销")


func _test_back_enemy_cover() -> void:
	var w: Dictionary = _make_world(2)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	# 背敌：敌人(+x 推进方向的反半平面)距 140px（<背敌半径 260，>武器射程 100 不算接战）
	var battle: Node = FakeBattle.new()
	var enemy := FakeEnemy.new()
	enemy.position = Vector2(60, 500)  # 单位在 (200,500)，敌在其背后
	battle.enemies = [enemy]
	for u in units:
		u.battle = battle
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	fs._tick_phase_plans(0.5)
	_runner.assert_gt(units[0].ai.orders_for("seek_cover"), 0, "背敌成员应被派去找掩体")
	_runner.assert_gt(units[1].ai.orders_for("seek_cover"), 0, "背敌成员应被派去找掩体")
	# 找掩体中（士气行为）不被跃进号令打断
	_runner.assert_equal(units[0].ai.orders_for("move"), 0, "找掩体成员不应同时收到跃进号令")


func _test_suppressed_cover() -> void:
	var w: Dictionary = _make_world(2)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	# 被压制代理：u0 刚被瞄准（arrow_threat_time 新鲜）、u1 无登记 → 只 u0 找掩体
	units[0].arrow_threat_time = Time.get_ticks_msec() / 1000.0 - 1.0
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	fs._tick_phase_plans(0.5)
	_runner.assert_gt(units[0].ai.orders_for("seek_cover"), 0, "被瞄准成员应被派去找掩体")
	_runner.assert_equal(units[1].ai.orders_for("seek_cover"), 0, "未被瞄准成员不应找掩体")
	_runner.assert_gt(units[1].ai.orders_for("move"), 0, "未被瞄准成员应正常跃进")


func _test_guards() -> void:
	var w: Dictionary = _make_world(6)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_enable(fs)
	# 角色：核心 u0,u1 + 侦察 u2 + 两翼 u3,u4,u5
	# u0 溃逃中（士气行为）、u1 玩家号令在身、u2 接战中（射程内敌、前方不触发找掩体）
	units[0].ai.force_behavior("retreat")
	units[1].ai.force_order("move", {"target": Vector2(9999, 0)})
	units[4].ai.force_order("move", {"target": Vector2(9999, 0)})  # 两翼侧玩家号令
	var battle: Node = FakeBattle.new()
	var enemy := FakeEnemy.new()
	enemy.position = Vector2(250, 500)  # u2 在 (200,500)：50px < 射程 100 = 接战，且在推进方向前方
	battle.enemies = [enemy]
	units[2].battle = battle
	units[5].battle = battle  # u5 两翼同敌接战（跟进相位守卫用）
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	fs._tick_phase_plans(0.5)
	_runner.assert_equal(units[0].ai.orders_for("move"), 0, "溃逃成员不应被相位号令打断")
	_runner.assert_equal(units[1].ai.orders_for("move"), 0, "玩家号令不应被相位号令覆盖")
	_runner.assert_equal(units[2].ai.orders_for("move"), 0, "接战成员应交还战斗行为")
	_runner.assert_equal(units[2].ai.orders_for("seek_cover"), 0, "前方接战不应触发找掩体")
	# 守卫成员不可下令 → 直接挪到跃进线落点（公共 API 取槽位落点）驱动相位前进
	for i in range(3):
		units[i].global_position = fs.get_squad_dest(sid, units[i], fs._squad_phase_plans[sid].get_leap_line(), "formation")
	fs._tick_phase_plans(0.5)
	_runner.assert_equal(fs._squad_phase_plans[sid].get_phase_name(), "core_wait", "核心波次全员到位应进等待")
	_beat(fs, 12)
	_beat(fs)
	# 跟进相位：u3 无守卫应获号令；u4 玩家号令 / u5 接战不打断
	_runner.assert_gt(units[3].ai.orders_for("move"), 0, "无守卫两翼应正常收到跟进号令")
	_runner.assert_equal(units[4].ai.orders_for("move"), 0, "玩家号令两翼不应被覆盖")
	_runner.assert_equal(units[5].ai.orders_for("move"), 0, "接战两翼不应被拽离战斗")
	_runner.assert_equal(units[5].ai.orders_for("seek_cover"), 0, "前方接战两翼不应触发找掩体")


func _test_default_off() -> void:
	# 缺省关闭：推进号令不建计划、节拍空转、无号令下发（零回归基线）
	var w: Dictionary = _make_world(3)
	var fs: Node = w["fs"]
	var units: Array = w["units"]
	var sid: String = w["sid"]
	_runner.assert_false(bool(fs._phase_plan_params.get("phase_plan_enabled", true)), "缺省应关闭（零回归基线）")
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	_runner.assert_true(fs._squad_phase_plans.is_empty(), "关闭态推进号令不应建计划")
	fs._tick_phase_plans(0.5)
	for u in units:
		_runner.assert_equal(u.ai.orders.size(), 0, "关闭态不应有任何相位号令")
	# 开启态：非推进号令撤销计划（计划不与号令打架）
	_enable(fs)
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	_runner.assert_true(fs._squad_phase_plans.has(sid), "开启态推进号令应建计划")
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.HOLD_POSITION, sid, Vector2.ZERO)
	_runner.assert_true(fs._squad_phase_plans.is_empty(), "坚守号令应撤销计划")
	_enable(fs)
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	fs.notify_squad_order(ScriptTacticalOrders.OrderType.RETREAT, sid, Vector2.ZERO)
	_runner.assert_true(fs._squad_phase_plans.is_empty(), "撤退号令应撤销计划")


func _test_org_notify() -> void:
	var w: Dictionary = _make_world(3)
	var fs: Node = w["fs"]
	var sid: String = w["sid"]
	_enable(fs)
	# FakeOrgApi：L1 独立根（root = 自身）→ 组织号令通知应入计划
	fs.notify_org_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(1000, 500))
	_runner.assert_true(fs._squad_phase_plans.has(sid), "组织号令通知应激活该编制小队计划")
	# 非本编制根的通知不误建
	fs.notify_org_order(ScriptTacticalOrders.OrderType.ADVANCE_ALL, "别的编制", Vector2(1000, 500))
	_runner.assert_true(fs._squad_phase_plans.has(sid), "无关节点通知不应影响已有计划")


func _test_resource() -> void:
	# 计划=数据资源：BalanceConfig 类型路径 ai.squad_phase_plan 装载 + 缺省关闭
	var res: Resource = load("res://config/ai/squad_phase_plan.tres")
	_runner.assert_not_null(res, "计划参数资源应可加载")
	if res == null:
		return
	var rows: Array = res.get("variables").get("data", [])
	_runner.assert_equal(rows.size(), 1, "应含 global 行")
	var row: Dictionary = rows[0]
	_runner.assert_equal(str(row.get("id", "")), "global", "行 id 应为 global")
	_runner.assert_equal(bool(row.get("phase_plan_enabled", true)), false, "资源缺省应关闭（零回归基线）")
	# CoH 真值等待窗（infantry-plan 2~4s / 2~3.5s）
	_runner.assert_approx(float(row.get("wait_core_min", 0.0)), 2.0, 0.001, "核心等待下限 = CoH 真值 2s")
	_runner.assert_approx(float(row.get("wait_core_max", 0.0)), 4.0, 0.001, "核心等待上限 = CoH 真值 4s")
	_runner.assert_approx(float(row.get("wait_flank_min", 0.0)), 2.0, 0.001, "两翼等待下限 = CoH 真值 2s")
	_runner.assert_approx(float(row.get("wait_flank_max", 0.0)), 3.5, 0.001, "两翼等待上限 = CoH 真值 3.5s")
	# 代码默认档同步缺省关闭（BalanceConfig 缺载兜底）
	_runner.assert_equal(bool(ScriptSquadPhasePlan.DEFAULTS.get("phase_plan_enabled", true)), false,
			"代码默认档应缺省关闭")
