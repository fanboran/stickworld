extends Node
## 集成测试：多层级组织端到端全链路（批次 4 收口，架构文档 §六 e2e 场景）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_org_e2e.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 场景（§六 e2e：程序搭 军 L3 → 连 L2×2 → 排 L1×4 森林，断言宜宽、数据驱动）：
##   幕一「建军 + 全链路下令」：三层任命指挥官 → 对军根 issue_to_org(ADVANCE) →
##     快进（零距离 provider）断言全部 4 排执行 + order_issued 以军根为 target +
##     OrgPanel 树含全层级
##   幕二「伤亡补位 + 链路重发即达」：杀连长甲（org 侧死亡入口 remove_stickman）→
##     断言补位（子指挥官=排长顶上，cmd 属性定序）+ commander_lost 必报 +
##     面板树指挥官标记刷新 → 对军重发号令 → 全部 4 排再次收到（链路自愈）
##   幕三「群龙无首 + 面板同步」：连乙全排覆灭（小队解散上挂）→ 杀连长乙 →
##     候选池空 → 持续空缺（filled=false）→ 面板树无 ▲ 标记 + 详情「指挥官：（无）」

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位总数：4 排 × 3 人 = 12 + 军长/连长甲/连长乙 3 名独立指挥官
const UNIT_COUNT: int = 15
## 每排人数
const PER_SQUAD: int = 3

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
var _tactical: Node = null
var _api: Node = null
var _panel: Control = null
var _units: Array = []

# 军树节点 id（幕一搭建后填）
var _army: String = ""
var _company_a: String = ""
var _company_b: String = ""
var _platoons: Dictionary = {}  # name -> squad_id（甲1/甲2/乙1/乙2）

# 信号捕获
var _issued_org: String = ""
var _issued_type: int = -1
var _delivered_squads: Array = []
var _reports: Array = []          # [{org_id, report}]
var _assigned_events: Array = []  # [{org_id, unit_id}]


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: 军链五系统已就位（含 OrgPanel）", "fn": Callable(self, "_test_assembled"), "async": false})
	_tests.append({"name": "幕一: 建军树+三层任命", "fn": Callable(self, "_test_build_army"), "async": false})
	_tests.append({"name": "幕一: 对军下令全部4排执行", "fn": Callable(self, "_test_army_wide_advance"), "async": true})
	_tests.append({"name": "幕一: OrgPanel 树含全层级", "fn": Callable(self, "_test_panel_tree_full"), "async": false})
	_tests.append({"name": "幕二: 杀连长甲子指挥官顶上+必报", "fn": Callable(self, "_test_company_succession"), "async": true})
	_tests.append({"name": "幕二: 重发号令链路自愈", "fn": Callable(self, "_test_reissue_after_succession"), "async": true})
	_tests.append({"name": "幕三: 连乙覆灭候选空持续空缺", "fn": Callable(self, "_test_leaderless_persists"), "async": true})
	# 面板同步依赖异步幕三（解散+空缺）先行——须走异步序尾执行（同步用例会先于全部异步幕跑）
	_tests.append({"name": "幕三: OrgPanel 群龙无首标记同步", "fn": Callable(self, "_test_panel_leaderless_mark"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	_tactical = _helper.tactical
	_api = _helper.game_root.get_organization_api()
	_panel = _helper.game_root.get_org_panel()
	_connect_signals()
	# 生成测试单位
	_helper.spawn_test_units(UNIT_COUNT)
	for i in 2:
		await get_tree().process_frame
	_units = _helper.units.duplicate()
	# §六快进机制：零距离 provider → 每跳延迟 0 → 接力即时完成
	_inject_zero_distance()

	for t in _tests:
		if not t["async"]:
			_runner.add_test(t["name"], t["fn"])
	_runner.run()

	for t in _tests:
		if t["async"]:
			_runner.begin_test(t["name"])
			await t["fn"].call()
			_runner.end_test()
			print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 环境辅助 ────────────────────────────────

func _connect_signals() -> void:
	if _command_chain() != null:
		_command_chain().order_delivered.connect(_on_order_delivered)
	_tactical.order_issued.connect(_on_order_issued)
	_api.report_filed.connect(_on_report_filed)
	EventBus.commander_assigned.connect(_on_commander_assigned)


## CommandChain 引用（经 TacticalOrders 内部装配；e2e 只关心送达信号）
func _command_chain() -> Node:
	var cc: Node = _helper.game_root.get_command_chain()
	return cc


func _on_order_issued(order_type: int, target: String, _source_tier: int) -> void:
	_issued_type = order_type
	_issued_org = target


func _on_order_delivered(_order_type: int, squad_id: String, _unit_ids: Array) -> void:
	_delivered_squads.append(squad_id)


func _on_report_filed(org_id: String, report: Dictionary) -> void:
	_reports.append({"org_id": org_id, "report": report})


func _on_commander_assigned(org_id: String, unit_id: int) -> void:
	_assigned_events.append({"org_id": org_id, "unit_id": unit_id})


func _clear_captures() -> void:
	_issued_org = ""
	_issued_type = -1
	_delivered_squads.clear()
	_reports.clear()
	_assigned_events.clear()


## 注入零距离 provider（§六快进）：全坐标重合 → 每跳延迟 0 → 接力即时完成
func _inject_zero_distance() -> void:
	_api.set_transport_providers(
		func(_org_id: String) -> Variant: return Vector2.ZERO,
		func() -> Vector2: return Vector2.ZERO,
		func(_a: String, _b: String) -> float: return 0.0)


## 一击必杀（死亡清理在 FormationSystem._process 下一帧执行）
func _kill(unit: Node) -> void:
	if unit != null and is_instance_valid(unit) and unit.has_method("get_health"):
		var h: Node = unit.get_health()
		if h != null and h.has_method("take_damage"):
			h.take_damage(99999.0)


## 独立指挥官挂名：实体编入组织 + 任命（军长/连长口径，不在任何小队）
func _appoint_standalone(org_id: String, unit: Node) -> void:
	_api.assign_stickman(org_id, str(unit.get_instance_id()), "officer")
	_api.assign_commander(org_id, str(unit.get_instance_id()))


## 等待小队解散信号触发（帧推进）
func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_assembled() -> void:
	_runner.assert_true(_api != null and _formation != null and _tactical != null, "org_api/formation/tactical 应全部装配")
	_runner.assert_true(_command_chain() != null, "CommandChain 应装配")
	_runner.assert_true(_panel != null, "OrgPanel 应由 SystemSetup 装配（game_root.get_org_panel）")
	_runner.assert_true(_tactical.has_method("issue_to_org"), "TacticalOrders 应有 issue_to_org 入口")


## 幕一前置：搭 军 L3 → 连甲/连乙 L2 → 各 2 排 L1，三层任命指挥官。
## 排长 cmd 属性显式定序（甲1=5.0 > 甲2=1.0）——幕二补位断言确定性锚点。
func _test_build_army() -> void:
	var r: Dictionary = _api.create_organization("e2e军", "MILITARY", 3, "")
	_runner.assert_true(r.get("ok", false), "军根 L3 应建成")
	if not r.get("ok", false):
		return
	_army = String(r.data.org_id)
	for pair in [["e2e连甲", "_company_a"], ["e2e连乙", "_company_b"]]:
		var cr: Dictionary = _api.create_organization(String(pair[0]), "MILITARY", 2, _army)
		_runner.assert_true(cr.get("ok", false), "%s L2 应建成" % String(pair[0]))
		set(pair[1], String(cr.data.org_id))
	if _company_a.is_empty() or _company_b.is_empty():
		return
	# 4 排：units 0-11 每排 3 人；排长 = 首单位（assign_leader 同步任命排 org 指挥官）
	var keys: Array = ["甲1", "甲2", "乙1", "乙2"]
	var parents: Array = [_company_a, _company_a, _company_b, _company_b]
	var idx: int = 0
	for k_i in keys.size():
		var batch: Array = _units.slice(idx, idx + PER_SQUAD)
		idx += PER_SQUAD
		var sid: String = _formation.create_squad(batch, "e2e排" + String(keys[k_i]), "fp_combat_squad", String(parents[k_i]))
		_runner.assert_true(not sid.is_empty(), "排%s 应建成并挂连" % String(keys[k_i]))
		if sid.is_empty():
			return
		_formation.assign_leader(sid, batch[0])
		_platoons[String(keys[k_i])] = sid
	# 三层任命：军长 units[12] / 连长甲 units[13] / 连长乙 units[14]（独立实体挂名）
	_appoint_standalone(_army, _units[12])
	_appoint_standalone(_company_a, _units[13])
	_appoint_standalone(_company_b, _units[14])
	# 补位定序锚点：排甲1排长 cmd 最高（幕二连长甲阵亡时由其顶上）
	_units[0].attributes["cmd"] = 5.0   # 排甲1排长
	_units[3].attributes["cmd"] = 1.0   # 排甲2排长
	# 任命后核验（指挥官不变量：各层皆有主）
	_runner.assert_false(String(_api.get_organization(_army).data.commander_id).is_empty(), "军根应有指挥官")
	_runner.assert_false(String(_api.get_organization(_company_a).data.commander_id).is_empty(), "连甲应有指挥官")
	_runner.assert_false(String(_api.get_organization(_company_b).data.commander_id).is_empty(), "连乙应有指挥官")


func _test_army_wide_advance() -> void:
	if _army.is_empty():
		return
	_clear_captures()
	var target: Vector2 = _units[0].global_position + Vector2(500, 0)
	var ok: bool = _tactical.issue_to_org(_army, _tactical.OrderType.ADVANCE_ALL, target)
	_runner.assert_true(ok, "对军根下令应受理")
	_runner.assert_equal(_issued_org, _army, "order_issued 应以军根 id 为 target")
	_runner.assert_equal(_issued_type, _tactical.OrderType.ADVANCE_ALL, "order_issued 类型应为 ADVANCE_ALL")
	await _wait_frames(6)
	# 全部 4 排各送达一次（军→连→排 BFS 层序全展开）
	for key in ["甲1", "甲2", "乙1", "乙2"]:
		var sid: String = String(_platoons[key])
		_runner.assert_true(_delivered_squads.count(sid) == 1, "排%s 应送达恰一次" % key)
		for u in _formation.get_squad_units(sid):
			if not is_instance_valid(u):
				continue
			var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
			if ai != null:
				_runner.assert_true(ai.has_order(), "排%s成员应收到号令" % key)
				_runner.assert_equal(ai.get_ordered_behavior(), "move", "号令行为应为 move")


func _test_panel_tree_full() -> void:
	if _army.is_empty() or _panel == null:
		return
	_panel.open()
	_panel._refresh_tree()
	_runner.assert_true(_panel.visible, "面板应可打开")
	# 全链路 7 节点：军根 → 两连 → 四排
	var all_ids: Array = [_army, _company_a, _company_b]
	for key in ["甲1", "甲2", "乙1", "乙2"]:
		all_ids.append(String(_platoons[key]))
	for org_id in all_ids:
		_runner.assert_true(_find_item(String(org_id)) != null, "面板树应含组织节点 %s" % String(org_id))
	_panel.close()
	_runner.assert_false(_panel.visible, "close 后面板应隐藏")


# ─────────────────────────────── 幕二：伤亡补位 ────────────────────────────────

func _test_company_succession() -> void:
	if _company_a.is_empty():
		return
	_clear_captures()
	var chief: Node = _units[13]  # 连长甲（独立实体挂名）
	var successor: Node = _units[0]  # 排甲1排长（cmd=5.0 定序锚点）
	var before: Dictionary = _api.get_organization(_company_a)
	_runner.assert_equal(String(before.data.commander_id), str(chief.get_instance_id()), "前置：连长甲在任")
	# 杀连长甲：实体阵亡 + 死亡到组织的同一入口（manager.remove_stickman，§4.3.1 内聚触发）
	_kill(chief)
	var rm: Dictionary = _api.remove_stickman(_company_a, str(chief.get_instance_id()))
	_runner.assert_true(rm.get("ok", false), "死亡到组织入口应受理")
	for i in 3:
		await get_tree().process_frame
	var after: Dictionary = _api.get_organization(_company_a)
	_runner.assert_equal(String(after.data.commander_id), str(successor.get_instance_id()), "连长甲阵亡应由子指挥官（排甲1排长）顶上")
	_runner.assert_true(_assigned_events.any(func(e: Dictionary) -> bool: return e["org_id"] == _company_a and e["unit_id"] == successor.get_instance_id()), "补位应发射 commander_assigned（连甲→排甲1排长）")
	var lost: Array = _reports.filter(func(r: Dictionary) -> bool:
		return r["org_id"] == _company_a and String(r["report"].get("type", "")) == "commander_lost")
	_runner.assert_true(not lost.is_empty(), "commander_lost 应必报（§4.4 必报型）")
	if not lost.is_empty():
		var payload: Dictionary = lost[0]["report"].get("payload", {})
		_runner.assert_true(bool(payload.get("filled", false)), "补位成功 filled=true")
		_runner.assert_equal(String(payload.get("successor_id", "")), str(successor.get_instance_id()), "successor 应为排甲1排长")
	# 一实多职：排甲1排长同时升任连长，本排 leadership 不动（squad.leader 仍是他）
	_runner.assert_equal(_formation.get_squad_leader(String(_platoons["甲1"])), successor, "排甲1 leadership 不变（一实多职）")
	# 面板侧同步（宜宽）：树刷新后连甲节点指挥官标记应指向补位者（数据驱动断言）
	if _panel != null:
		_panel.open()
		_panel._refresh_tree()
		var item_a: TreeItem = _find_item(_company_a)
		_runner.assert_not_null(item_a, "面板树应仍含连甲")
		if item_a != null:
			_runner.assert_true(String(item_a.get_text(0)).contains("▲#%s" % str(successor.get_instance_id())), "补位后面板树应刷新连甲指挥官标记")
		_panel.close()


func _test_reissue_after_succession() -> void:
	if _army.is_empty():
		return
	_clear_captures()
	var target: Vector2 = _units[6].global_position + Vector2(-400, 0)
	var ok: bool = _tactical.issue_to_org(_army, _tactical.OrderType.ADVANCE_ALL, target)
	_runner.assert_true(ok, "补位后重发应受理")
	await _wait_frames(6)
	# 链路自愈：连甲新指挥官在任 → 命令照常透传，全部 4 排再次收到
	for key in ["甲1", "甲2", "乙1", "乙2"]:
		var sid: String = String(_platoons[key])
		_runner.assert_true(_delivered_squads.count(sid) == 1, "重发后排%s 应送达恰一次（链路仍可下达）" % key)


# ─────────────────────────────── 幕三：群龙无首 ────────────────────────────────

func _test_leaderless_persists() -> void:
	if _company_b.is_empty():
		return
	_clear_captures()
	# 连乙全排覆灭（排乙1 units 6-8、排乙2 units 9-11）：小队解散 → L1 org 上挂消失
	var squad_disbanded: Array = []
	var conn: Callable = func(sid: String) -> void: squad_disbanded.append(sid)
	_formation.squad_disbanded.connect(conn)
	for i in range(6, 12):
		_kill(_units[i])
	await _wait_frames(6)
	_formation.squad_disbanded.disconnect(conn)
	_runner.assert_true(squad_disbanded.size() >= 2, "连乙两排应全灭解散")
	_runner.assert_true(_api.get_child_orgs(_company_b).is_empty(), "连乙子组织应清空（解散上挂链路）")
	# 杀连长乙：候选池空（personnel 空余他本人被移除、子组织已散）→ 持续空缺
	_kill(_units[14])
	var rm: Dictionary = _api.remove_stickman(_company_b, str(_units[14].get_instance_id()))
	_runner.assert_true(rm.get("ok", false), "连长乙死亡到组织入口应受理")
	for i in 2:
		await get_tree().process_frame
	var d: Dictionary = _api.get_organization(_company_b)
	_runner.assert_true(String(d.data.commander_id).is_empty(), "无人可用应持续空缺（指挥官不变量：不造空框之外的假主）")
	var lost: Array = _reports.filter(func(r: Dictionary) -> bool:
		return r["org_id"] == _company_b and String(r["report"].get("type", "")) == "commander_lost")
	_runner.assert_true(not lost.is_empty(), "连乙 commander_lost 也应必报")
	if not lost.is_empty():
		_runner.assert_false(bool(lost[0]["report"].get("payload", {}).get("filled", true)), "候选空 filled=false")


func _test_panel_leaderless_mark() -> void:
	if _company_b.is_empty() or _panel == null:
		return
	# 树同步：解散信号已触发全量重建 → 排乙节点消失、连乙无 ▲ 标记（群龙无首）
	_panel.open()
	_panel._refresh_tree()
	_runner.assert_null(_find_item(String(_platoons.get("乙1", "_gone_"))), "面板树应不含已解散的排乙1")
	var item_b: TreeItem = _find_item(_company_b)
	_runner.assert_not_null(item_b, "面板树应仍含连乙（空架持续空缺）")
	if item_b != null:
		_runner.assert_false(String(item_b.get_text(0)).contains("▲"), "连乙树节点应无 ▲ 指挥官标记（群龙无首）")
	# 详情同步：选中连乙 → 指挥官：（无）
	_panel._selected_org = _company_b
	_panel._refresh_detail()
	var texts: Array = []
	for child in _panel._detail_box.get_children():
		if child is Label:
			texts.append((child as Label).text)
	_runner.assert_true("\n".join(texts).contains("指挥官：（无）"), "连乙详情应显示群龙无首（指挥官：（无））")
	_panel.close()


# ─────────────────────────────── 工具 ────────────────────────────────

## 面板树按 org_id 找节点（照 test_org_panel 手法）
func _find_item(org_id: String) -> TreeItem:
	if _panel == null or _panel._tree == null:
		return null
	var root_item: TreeItem = _panel._tree.get_root()
	if root_item == null:
		return null
	return _find_recursive(root_item, org_id)


func _find_recursive(item: TreeItem, org_id: String) -> TreeItem:
	var meta: Variant = item.get_metadata(0)
	if meta != null and String(meta) == org_id:
		return item
	for child in item.get_children():
		var hit := _find_recursive(child, org_id)
		if hit != null:
			return hit
	return null
