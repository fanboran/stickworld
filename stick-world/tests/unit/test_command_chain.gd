extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：指挥链纯逻辑（CommandChain 送达执行 + TacticalOrders 号令映射）。
##
## 3-F2 职责重划（架构文档 §4.2.4）：旧 base_delay × tier_diff 抽象公式已退役，
## 延迟唯一来源 = 传输层物理传播（数值断言归 test_transport_layer）；
## 本文件断言 deliver 恒即时送达 + 签名兼容 + 防御守卫 + 号令映射 + 在途接力登记
## （UI-W3 前置：relay_started/relay_arrived 信号、在途清单与抵达留痕）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptCommandChain := preload("res://modules/combat/scripts/command/command_chain.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")
const ScriptBoard := preload("res://modules/organization/ui/command_chain_board.gd")
const TestHelpers := preload("res://tests/core/test_helpers.gd")

var _runner: TestRunner


## 桩 AI 控制器（set_order 捕获；_execute_delivery 的 ai 形参类型注解为 Node，桩须同型）
class StubAI extends Node:
	var behavior: String = ""
	var params: Dictionary = {}
	var ordered: bool = false

	func set_order(behavior_name: String, p: Dictionary) -> void:
		behavior = behavior_name
		params = p
		ordered = true

	func has_order() -> bool:
		return ordered

	func get_ordered_behavior() -> String:
		return behavior


## 桩单位（足够 _execute_delivery 消费）
class StubUnit:
	var ai: StubAI = StubAI.new()

	func is_dead() -> bool:
		return false

	func get_ai_controller() -> StubAI:
		return ai

	func free_ai() -> void:
		if ai != null:
			ai.free()

## 接力夹具：组织结构桩（get_organization / get_delivery_time）
class RelayOrgApi extends Node:
	var orgs: Dictionary = {}
	var delays: Dictionary = {}

	func get_organization(id: String) -> Dictionary:
		if not orgs.has(id):
			return {"ok": false}
		return {"ok": true, "data": orgs[id]}

	func get_delivery_time(from_org: String, to_org: String) -> float:
		return float(delays.get(from_org + ">" + to_org, 0.0))


## 接力夹具：编队桩（战斗职责 + 小队成员）
class RelayFormation extends Node:
	var combat: Dictionary = {}
	var squads: Dictionary = {}

	func is_combat_squad(org_id: String) -> bool:
		return bool(combat.get(org_id, false))

	func get_squad_units(org_id: String) -> Array:
		return squads.get(org_id, [])


## 沙盘夹具：organization api 桩（CommandChainBoard.build_tree 的三个只读查询）
class BoardOrgApi extends Node:
	var roots: Array = []
	var orgs: Dictionary = {}
	var candidates: Dictionary = {}

	func list_root_orgs() -> Array:
		return roots

	func get_organization(id: String) -> Dictionary:
		if not orgs.has(id):
			return {"ok": false}
		return {"ok": true, "data": orgs[id]}

	func get_succession_candidates(id: String) -> Array:
		return candidates.get(id, [])


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("CommandChain: deliver 恒即时送达（撤抽象公式，签名兼容）", _test_deliver_instant)
	_runner.add_test("CommandChain: 死亡单位跳过、活体照常送达", _test_deliver_skips_dead)
	_runner.add_test("CommandChain: deliver_via_orgs 缺 org_api 安全返回", _test_relay_guard)
	_runner.add_test("TacticalOrders: 号令类型到行为名映射", _test_order_to_behavior)
	_runner.add_test("TacticalOrders: 号令类型到参数映射", _test_order_to_params)
	_runner.add_test("接力在途: 零距离两跳信号成对/序位/结局/留痕", _test_relay_two_hop, true)
	_runner.add_test("接力在途: 带延迟跳 eta 语义与在途清单生命周期", _test_relay_eta_inflight, true)
	_runner.add_test("接力在途: 中间层群龙无首=停驻丢弃且不达 L1", _test_relay_leaderless, true)
	_runner.add_test("接力在途: L1 非战斗拒收= rejected_noncombat", _test_relay_reject, true)
	_runner.add_test("事件镜像: 逐跳接力镜像转发到 EventBus（UI-W3 跨模块观测）", _test_relay_eventbus_mirror, true)
	_runner.add_test("指挥链沙盘: 树构建/布局/群龙无首/补位候选/统辖规模", _test_board_tree_and_layout)
	_runner.add_test("指挥链沙盘: 在途跳 eta 倒计时与停驻态生命周期", _test_board_hop_ledger)
	await _runner.run_async()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_deliver_instant() -> void:
	var cc := ScriptCommandChain.new()
	var unit := StubUnit.new()
	var delivered: Array = []
	cc.order_delivered.connect(func(_t: int, sid: String, ids: Array) -> void: delivered.append([sid, ids]))
	# source_tier/squad_tier/spread_mode 照旧传参（签名兼容，不再参与任何延迟计算）
	cc.deliver(0, "squad_x", [unit], "move", {"target": Vector2(1, 2)}, 3, 1, "line")
	_runner.assert_equal(unit.ai.behavior, "move", "deliver 应即时送达（延迟由传输层承担）")
	_runner.assert_equal(unit.ai.params.get("target", Vector2.ZERO), Vector2(1, 2), "行为参数应透传")
	_runner.assert_equal(delivered.size(), 1, "order_delivered 应同步发射一次")
	unit.free_ai()


func _test_deliver_skips_dead() -> void:
	var cc := ScriptCommandChain.new()
	var alive := StubUnit.new()
	var dead_unit := DeadStubUnit.new()
	last_delivered_ids = []
	cc.order_delivered.connect(_capture_delivered)
	cc.deliver(1, "squad_y", [alive, dead_unit], "idle", {}, 0, 1, "")
	_runner.assert_equal(alive.ai.behavior, "idle", "活体单位应收到号令")
	_runner.assert_equal(dead_unit.ai.behavior, "", "死亡单位应跳过（不设置行为）")
	_runner.assert_equal(last_delivered_ids.size(), 1, "unit_ids 应只含送达的活体单位（死者跳过）")
	alive.free_ai()


func _test_relay_guard() -> void:
	var cc := ScriptCommandChain.new()
	var plan := {"hops": [{"from_org": "", "to_org": "org_a", "order": {}}]}
	# org_api 缺失 → push_warning + return（守卫在 await 之前，无场景树也安全）
	cc.deliver_via_orgs(plan, null, 0, "move", {}, "")
	_runner.assert_true(true, "缺 org_api 应安全返回不崩溃")


## 死亡桩单位
class DeadStubUnit:
	var ai: StubAI = StubAI.new()

	func is_dead() -> bool:
		return true

	func get_ai_controller() -> StubAI:
		return ai


## order_delivered 捕获（connect 成员方法形态，避免用例间闭包状态残留）
var last_delivered_ids: Array = []

func _capture_delivered(_t: int, _sid: String, ids: Array) -> void:
	last_delivered_ids = ids.duplicate()


func _test_order_to_behavior() -> void:
	var to := ScriptTacticalOrders.new()
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.ADVANCE_ALL), "move", "ADVANCE_ALL -> move")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.SPRINT), "move", "SPRINT -> move")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.HOLD_POSITION), "idle", "HOLD_POSITION -> idle")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.RETREAT), "retreat", "RETREAT -> retreat")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.TAKE_COVER), "seek_cover", "TAKE_COVER -> seek_cover")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.RALLY), "move", "RALLY -> move")


func _test_order_to_params() -> void:
	var to := ScriptTacticalOrders.new()
	var target := Vector2(100, 200)
	var adv: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.ADVANCE_ALL, target)
	_runner.assert_equal(adv.get("target", Vector2.ZERO), target, "ADVANCE_ALL 携带目标点")
	var sprint: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.SPRINT, target)
	_runner.assert_equal(sprint.get("run", false), true, "SPRINT 应跑步")
	_runner.assert_equal(sprint.get("target", Vector2.ZERO), target, "SPRINT 携带目标点")
	var hold: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.HOLD_POSITION, target)
	_runner.assert_true(hold.is_empty(), "HOLD_POSITION 无参数")
	var retreat: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.RETREAT, target)
	_runner.assert_true(retreat.is_empty(), "RETREAT 无参数（battle 由 behavior 自取）")


# ─────────────────────── 接力在途登记（UI-W3 前置）───────────────────────

func _mk_relay_chain(formation: RelayFormation) -> ScriptCommandChain:
	var chain: ScriptCommandChain = ScriptCommandChain.new()
	chain.setup_formation(formation)
	chain.add_child(formation)  # 归 chain 之下：测试收尾 chain.free 一并回收
	add_child(chain)
	return chain


## 收尾：桩单位 AI（Node）显式释放 + api/chain 释放，防 ObjectDB 退出泄漏告警
func _teardown_relay(chain: ScriptCommandChain, formation: RelayFormation, api: RelayOrgApi) -> void:
	for sid in formation.squads:
		for u in formation.squads[sid]:
			u.free_ai()
	api.free()
	chain.free()


func _capture_relay_signals(chain: ScriptCommandChain) -> Dictionary:
	var cap := {"started": [], "arrived": []}
	chain.relay_started.connect(func(_rid: String, _ot: int, _fo: String, to: String, hop: int, eta: float) -> void:
		(cap["started"] as Array).append({"to": to, "hop": hop, "eta": eta}))
	chain.relay_arrived.connect(func(_rid: String, _ot: int, _fo: String, to: String, hop: int, outcome: String) -> void:
		(cap["arrived"] as Array).append({"to": to, "hop": hop, "outcome": outcome}))
	return cap


func _relay_plan(root: String, leaves: Array) -> Dictionary:
	var hops: Array = [{"from_org": "", "to_org": root}]
	for leaf in leaves:
		hops.append({"from_org": root, "to_org": leaf})
	return {"root_org": root, "leaf_orgs": leaves, "hops": hops}


func _await_relays_settled(chain: ScriptCommandChain) -> bool:
	return await TestHelpers.await_condition(
			func() -> bool: return chain.get_relays_in_flight().is_empty(), 3.0, "接力全部落账")


func _test_relay_two_hop() -> void:
	var formation := RelayFormation.new()
	formation.combat = {"l1a": true, "l1b": true}
	formation.squads = {"l1a": [StubUnit.new()], "l1b": [StubUnit.new()]}
	var chain := _mk_relay_chain(formation)
	var cap := _capture_relay_signals(chain)
	var api := RelayOrgApi.new()
	api.orgs = {"root": {"tier": 2, "commander_id": "c1"}, "l1a": {"tier": 1, "commander_id": ""}, "l1b": {"tier": 1, "commander_id": ""}}
	chain.deliver_via_orgs(_relay_plan("root", ["l1a", "l1b"]), api,
			ScriptTacticalOrders.OrderType.ADVANCE_ALL, "move", {"target": Vector2.ZERO}, "")
	_runner.assert_true(await _await_relays_settled(chain), "零距离两跳应在超时内全部落账")
	_runner.assert_equal((cap["started"] as Array).size(), 3, "三跳各发一次 relay_started")
	_runner.assert_equal((cap["arrived"] as Array).size(), 3, "三跳各发一次 relay_arrived")
	var hop_by_org: Dictionary = {}
	for e in cap["started"]:
		hop_by_org[String(e["to"])] = int(e["hop"])
	_runner.assert_equal(int(hop_by_org.get("root", -1)), 0, "玩家跳序位 0")
	_runner.assert_equal(int(hop_by_org.get("l1a", -1)), 1, "root→l1a 序位 1")
	_runner.assert_equal(int(hop_by_org.get("l1b", -1)), 1, "root→l1b 序位 1（并行分支同层）")
	var outcome_by_org: Dictionary = {}
	for e in cap["arrived"]:
		outcome_by_org[String(e["to"])] = String(e["outcome"])
	_runner.assert_equal(String(outcome_by_org.get("root", "")), "relayed", "中间层结局=relayed")
	_runner.assert_equal(String(outcome_by_org.get("l1a", "")), "delivered", "l1a 结局=delivered")
	_runner.assert_equal(String(outcome_by_org.get("l1b", "")), "delivered", "l1b 结局=delivered")
	var history: Array = chain.get_relay_history(8)
	_runner.assert_true(history.size() >= 3, "留痕应含全部三跳（实际 %d）" % history.size())
	_teardown_relay(chain, formation, api)


func _test_relay_eta_inflight() -> void:
	var formation := RelayFormation.new()
	formation.combat = {"l1": true}
	formation.squads = {"l1": [StubUnit.new()]}
	var chain := _mk_relay_chain(formation)
	var cap := _capture_relay_signals(chain)
	var api := RelayOrgApi.new()
	api.orgs = {"root": {"tier": 2, "commander_id": "c1"}, "l1": {"tier": 1, "commander_id": ""}}
	api.delays = {">root": 0.4, "root>l1": 0.2}
	chain.deliver_via_orgs(_relay_plan("root", ["l1"]), api,
			ScriptTacticalOrders.OrderType.ADVANCE_ALL, "move", {"target": Vector2.ZERO}, "")
	# 起跑即登记：玩家跳在延迟期内必须可查（UI 的"逐跳跑秒"数据源）
	_runner.assert_equal(chain.get_relays_in_flight().size(), 1, "延迟期内玩家跳应在途")
	_runner.assert_approx(float(chain.get_relays_in_flight()[0]["eta"]), 0.4, 0.0001, "玩家跳 eta=传输层真值 0.4")
	_runner.assert_true(await _await_relays_settled(chain), "带延迟两跳应全部落账")
	var etas: Array = []
	for e in cap["started"]:
		etas.append(float(e["eta"]))
	_runner.assert_true(0.2 in etas, "子跳 eta 应含传输层 0.2（实测 %s）" % str(etas))
	_runner.assert_equal(chain.get_relays_in_flight().size(), 0, "落账后在途清单应清空")
	_teardown_relay(chain, formation, api)


func _test_relay_leaderless() -> void:
	var formation := RelayFormation.new()
	formation.combat = {"l1": true}
	formation.squads = {"l1": [StubUnit.new()]}
	var chain := _mk_relay_chain(formation)
	var cap := _capture_relay_signals(chain)
	var api := RelayOrgApi.new()
	api.orgs = {"root": {"tier": 2, "commander_id": ""}, "l1": {"tier": 1, "commander_id": ""}}
	chain.deliver_via_orgs(_relay_plan("root", ["l1"]), api,
			ScriptTacticalOrders.OrderType.ADVANCE_ALL, "move", {"target": Vector2.ZERO}, "")
	_runner.assert_true(await _await_relays_settled(chain), "停驻丢弃也应落账（在途清空）")
	_runner.assert_equal((cap["arrived"] as Array).size(), 1, "群龙无首=只有玩家跳一跳")
	_runner.assert_equal(String((cap["arrived"][0] as Dictionary)["outcome"]), "dropped_leaderless", "结局=停驻丢弃")
	_teardown_relay(chain, formation, api)


func _test_relay_reject() -> void:
	var formation := RelayFormation.new()
	formation.combat = {"l1": false}
	formation.squads = {"l1": [StubUnit.new()]}
	var chain := _mk_relay_chain(formation)
	var delivered: Array = []
	chain.order_delivered.connect(func(_ot: int, _sid: String, _ids: Array) -> void: delivered.append(1))
	var cap := _capture_relay_signals(chain)
	var api := RelayOrgApi.new()
	api.orgs = {"root": {"tier": 2, "commander_id": "c1"}, "l1": {"tier": 1, "commander_id": ""}}
	chain.deliver_via_orgs(_relay_plan("root", ["l1"]), api,
			ScriptTacticalOrders.OrderType.ADVANCE_ALL, "move", {"target": Vector2.ZERO}, "")
	_runner.assert_true(await _await_relays_settled(chain), "拒收路径也应落账")
	# 子跳在父跳销账前同步完成，arrived 顺序是「先 l1 后 root」——按 org 查，不按序
	var outcome_by_org: Dictionary = {}
	for e in cap["arrived"]:
		outcome_by_org[String(e["to"])] = String(e["outcome"])
	_runner.assert_equal(String(outcome_by_org.get("l1", "")), "rejected_noncombat", "非战斗叶结局=拒收")
	_runner.assert_equal(String(outcome_by_org.get("root", "")), "relayed", "中间层结局=relayed")
	_runner.assert_true(delivered.is_empty(), "拒收不应发出 order_delivered")
	_teardown_relay(chain, formation, api)


# ─────────────────── EventBus 镜像（UI-W3 指挥链视图跨模块观测）───────────────────

## 镜像口径：链信号原样转发到 EventBus（同 relay_id/from/to/hop/eta/outcome），
## 视图侧只订阅 EventBus——本用例守住「转发确实发生且字段一致」。
func _test_relay_eventbus_mirror() -> void:
	if EventBus == null or not EventBus.has_signal("relay_started") or not EventBus.has_signal("relay_arrived"):
		_runner.assert_true(false, "EventBus 应登记 relay_started/relay_arrived 镜像信号")
		return
	var started: Array = []
	var arrived: Array = []
	var cb_started := func(rid: String, _ot: int, from: String, to: String, hop: int, eta: float) -> void:
		started.append({"rid": rid, "from": from, "to": to, "hop": hop, "eta": eta})
	var cb_arrived := func(rid: String, _ot: int, from: String, to: String, hop: int, outcome: String) -> void:
		arrived.append({"rid": rid, "from": from, "to": to, "hop": hop, "outcome": outcome})
	EventBus.relay_started.connect(cb_started)
	EventBus.relay_arrived.connect(cb_arrived)
	var formation := RelayFormation.new()
	formation.combat = {"l1": true}
	formation.squads = {"l1": [StubUnit.new()]}
	var chain := _mk_relay_chain(formation)
	var api := RelayOrgApi.new()
	api.orgs = {"root": {"tier": 2, "commander_id": "c1"}, "l1": {"tier": 1, "commander_id": ""}}
	api.delays = {">root": 0.3, "root>l1": 0.1}
	chain.deliver_via_orgs(_relay_plan("root", ["l1"]), api,
			ScriptTacticalOrders.OrderType.ADVANCE_ALL, "move", {"target": Vector2.ZERO}, "")
	var settled: bool = await _await_relays_settled(chain)
	# 先断开再断言：断言失败也不把事件残留到其他用例
	EventBus.relay_started.disconnect(cb_started)
	EventBus.relay_arrived.disconnect(cb_arrived)
	_runner.assert_true(settled, "接力应在超时内落账")
	_runner.assert_equal(started.size(), (chain.get_relay_history(8) as Array).size(), "镜像 started 数与留痕一致")
	_runner.assert_equal(started.size(), 2, "两跳各镜像一次 relay_started")
	_runner.assert_equal(arrived.size(), 2, "两跳各镜像一次 relay_arrived")
	var started_by_to: Dictionary = {}
	for e in started:
		started_by_to[String(e["to"])] = e
	_runner.assert_approx(float((started_by_to["root"] as Dictionary)["eta"]), 0.3, 0.0001,
			"镜像 eta 应透传传输层真值（玩家跳 0.3）")
	_runner.assert_equal(String((started_by_to["root"] as Dictionary)["from"]), "", "镜像 from 空串=玩家跳")
	_runner.assert_equal(int((started_by_to["l1"] as Dictionary)["hop"]), 1, "镜像跳序位透传")
	var arrived_by_to: Dictionary = {}
	for e in arrived:
		arrived_by_to[String(e["to"])] = String(e["outcome"])
	_runner.assert_equal(String(arrived_by_to.get("root", "")), "relayed", "镜像结局=relayed")
	_runner.assert_equal(String(arrived_by_to.get("l1", "")), "delivered", "镜像结局=delivered")
	for e in started:
		_runner.assert_true(String(e["rid"]).begins_with("relay_"), "镜像 relay_id 与在途登记同源")
	_teardown_relay(chain, formation, api)


# ─────────────────────── 指挥链沙盘（UI-W3 视图纯逻辑）───────────────────────

## 树构建：玩家源 + 组织节点、群龙无首口径、补位候选前、统辖规模、层级布局坐标
func _test_board_tree_and_layout() -> void:
	var api := BoardOrgApi.new()
	api.roots = ["root"]
	api.orgs = {
		"root": {"id": "root", "name": "第三团", "tier": 3, "tag": 0,
				"commander_id": "c0", "personnel": [], "child_orgs": ["co"]},
		"co": {"id": "co", "name": "第一连", "tier": 2, "tag": 0,
				"commander_id": "", "personnel": ["p1"], "child_orgs": ["l1"]},
		"l1": {"id": "l1", "name": "一排", "tier": 1, "tag": 0,
				"commander_id": "p1", "personnel": ["p1", "p2"], "child_orgs": []},
	}
	api.candidates = {"co": [{"id": "p1", "cmd": 3.0}, {"id": "p2", "cmd": 2.0}]}
	var board: CommandChainBoard = ScriptBoard.new()
	board.build_tree(api)
	_runner.assert_equal(board.get_node_count(), 4, "玩家源 + 三组织 = 4 节点")
	var co: Dictionary = board.get_node_snapshot("co")
	_runner.assert_true(bool(co.get("leaderless", false)), "L2 指挥官空缺 = 群龙无首")
	_runner.assert_equal((co.get("candidates") as Array).size(), 2, "补位候选序透传（上限前三）")
	_runner.assert_equal(String((co.get("candidates") as Array)[0]), "p1", "候选第一序原文透出")
	_runner.assert_equal(int(co.get("people", 0)), 2, "统辖规模 = 子树去重人数（p1/p2）")
	var l1: Dictionary = board.get_node_snapshot("l1")
	_runner.assert_true(not bool(l1.get("leaderless", false)), "L1 空缺不算群龙无首（可空架招兵）")
	var unit: Dictionary = board.get_unit_positions()
	_runner.assert_approx(float((unit[""] as Vector2).y), 0.0, 0.0001, "玩家源在第 0 层")
	_runner.assert_approx(float((unit["root"] as Vector2).y), 1.0, 0.0001, "根组织第 1 层")
	_runner.assert_approx(float((unit["co"] as Vector2).y), 2.0, 0.0001, "连第 2 层")
	_runner.assert_approx(float((unit["l1"] as Vector2).y), 3.0, 0.0001, "排第 3 层")
	_runner.assert_approx(float((unit["co"] as Vector2).x), float((unit["l1"] as Vector2).x), 0.0001,
			"单子节点的父节点居中于子")
	board.free()
	api.free()


## 在途跳账本：起跑登记 eta → 动画时钟递减 → 抵达销账/留档；停驻态随送达清除
func _test_board_hop_ledger() -> void:
	var api := BoardOrgApi.new()
	api.roots = ["root"]
	api.orgs = {
		"root": {"id": "root", "name": "第三团", "tier": 3, "tag": 0,
				"commander_id": "c0", "personnel": [], "child_orgs": ["co"]},
		"co": {"id": "co", "name": "第一连", "tier": 2, "tag": 0,
				"commander_id": "", "personnel": [], "child_orgs": ["l1"]},
		"l1": {"id": "l1", "name": "一排", "tier": 1, "tag": 0,
				"commander_id": "p1", "personnel": ["p1"], "child_orgs": []},
	}
	var board: CommandChainBoard = ScriptBoard.new()
	board.build_tree(api)
	board.notify_relay_started("r1", 0, "", "root", 0, 2.0)
	_runner.assert_equal(board.get_active_hop_ids().size(), 1, "起跑即在途（连线点亮）")
	_runner.assert_approx(board.get_hop_remaining("r1"), 2.0, 0.0001, "剩余秒数起点 = eta")
	board.tick(0.5)
	_runner.assert_approx(board.get_hop_remaining("r1"), 1.5, 0.0001, "动画时钟推进 → 剩余递减")
	board.notify_relay_arrived("r1", 0, "", "root", 0, "relayed")
	_runner.assert_equal(board.get_active_hop_ids().size(), 0, "抵达销账（流光收束）")
	_runner.assert_equal(board.get_hop_remaining("r1"), -1.0, "不在途剩余查询返回 -1")
	_runner.assert_equal(board.get_last_outcome("r1"), "relayed", "结局留档")
	# 停驻：中间层群龙无首被停驻丢弃 → 该节点亮「命令停驻」
	board.notify_relay_arrived("r2", 0, "root", "co", 1, "dropped_leaderless")
	_runner.assert_true(board.has_hold("co"), "dropped_leaderless → 该组织节点停驻态")
	board.notify_relay_started("r3", 0, "root", "co", 1, 0.0)
	_runner.assert_true(not board.has_hold("co"), "新一跳起跑清除停驻")
	board.notify_relay_arrived("r3", 0, "root", "co", 1, "delivered")
	_runner.assert_equal(board.get_last_outcome("r3"), "delivered", "L1/L2 送达结局留档")
	board.free()
	api.free()
