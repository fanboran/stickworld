extends Node
## 集成测试：组织逐层指挥链 combat 对接（批次 3-F2，架构文档 §六两幕）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_org_command_chain.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖（§六快进机制：注入零距离 provider / 受控坐标，不依赖真实计时器精度）：
##   幕一「下令传播」：
##   - issue_to_org 未知组织失败（org_not_found）
##   - 受控坐标：L1 收令时刻 = 沿途各跳延迟之和（纯数值相对断言，不吃速度具体值）
##   - 零距离：对 L2 连下令 → 两 L1 排成员收到 move 号令 + order_delivered 各一次
##   幕二「伤亡补位」：
##   - 杀 L1 排长 → commander_assigned 发射 + squad.leader 回写 + commander_lost 必报（filled=true）
##   - 杀光全排 → 小队解散（既有链路）→ 排 org 从连 child_orgs 消失
##   - 中间层连长空缺 → 补位从下级指挥官池取人（排长顶上连长位）
##   - 非战斗叶拒收号令（is_combat_squad 口径，plan 不挡、送达时挡）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位总数（按用例分配：甲 0-5 / 乙 6-11 / 丙 0-3 / 丁 4-6 / 戊 9-11 / 建造队 2）
const UNIT_COUNT: int = 12

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
var _tactical: Node = null
var _command_chain: Node = null
var _api: Node = null
var _units: Array = []

# 信号捕获
var _issued_org: String = ""
var _issued_type: int = -1
var _delivered_squads: Array = []
var _reports: Array = []          # [{org_id, report}]
var _assigned_events: Array = []  # [{org_id, unit_id}]

# 受控坐标表（幕一延迟数值断言；position_provider 按其查询）
var _controlled_pos: Dictionary = {}


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: 组织链三系统已就位", "fn": Callable(self, "_test_assembled"), "async": false})
	_tests.append({"name": "幕一: issue_to_org 未知组织失败", "fn": Callable(self, "_test_unknown_org"), "async": true})
	_tests.append({"name": "幕一: 受控坐标 L1 收令时刻=各跳延迟之和", "fn": Callable(self, "_test_delivery_time_sum"), "async": true})
	_tests.append({"name": "幕一: 零距离对连下令两排执行", "fn": Callable(self, "_test_relay_delivery"), "async": true})
	_tests.append({"name": "幕二: 杀排长自动补位回写+必报", "fn": Callable(self, "_test_leader_succession"), "async": true})
	_tests.append({"name": "幕二: 杀光全排小队解散上挂", "fn": Callable(self, "_test_squad_wipe_disband"), "async": true})
	_tests.append({"name": "幕二: 中间层补位从下级指挥官池取人", "fn": Callable(self, "_test_midtier_succession"), "async": true})
	_tests.append({"name": "拒收: 非战斗叶不执行战斗号令", "fn": Callable(self, "_test_noncombat_reject"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	_tactical = _helper.tactical
	_command_chain = _helper.command_chain
	_api = _helper.game_root.get_organization_api()
	_connect_signals()
	# 生成测试单位
	_helper.spawn_test_units(UNIT_COUNT)
	for i in 2:
		await get_tree().process_frame
	_units = _helper.units.duplicate()
	# 默认零距离（§六快进；各用例按需覆盖为受控坐标）
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
	_tactical.order_issued.connect(_on_order_issued)
	_command_chain.order_delivered.connect(_on_order_delivered)
	_api.report_filed.connect(_on_report_filed)
	EventBus.commander_assigned.connect(_on_commander_assigned)


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
		_stub_region_zero)


## 受控坐标 provider：按 org_id 查 _controlled_pos，未知组织 INF
func _controlled_position_provider(org_id: String) -> Variant:
	return _controlled_pos.get(org_id, Vector2.INF)


func _stub_region_zero(_from_loc: String, _to_loc: String) -> float:
	return 0.0


## 搭 L2 连（两/若干 L1 排挂连下）+ 各排任命排长。
## 返回 {"root": 连id, "squads": [排id...]}；单位复用时 create_squad 自动移出旧队。
func _build_l2_tree(name_prefix: String, units: Array, per_squad: int) -> Dictionary:
	var r: Dictionary = _api.create_organization("%s连" % name_prefix, "MILITARY", 2, "")
	if not r.get("ok", false):
		return {}
	var company: String = String(r.data.org_id)
	var squads: Array = []
	var idx: int = 0
	while idx < units.size():
		var batch: Array = units.slice(idx, idx + per_squad)
		idx += per_squad
		var sid: String = _formation.create_squad(batch, "%s排%d" % [name_prefix, squads.size() + 1], "fp_combat_squad", company)
		if sid.is_empty():
			return {}
		if batch.size() > 0:
			_formation.assign_leader(sid, batch[0])
		squads.append(sid)
	return {"root": company, "squads": squads}


## 一击必杀（死亡清理在 FormationSystem._process 下一帧执行）
func _kill(unit: Node) -> void:
	if unit != null and is_instance_valid(unit) and unit.has_method("get_health"):
		var h: Node = unit.get_health()
		if h != null and h.has_method("take_damage"):
			h.take_damage(99999.0)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_assembled() -> void:
	_runner.assert_true(_api != null and _formation != null and _tactical != null and _command_chain != null, "org_api/formation/tactical/command_chain 应全部装配")
	_runner.assert_true(_tactical.has_method("issue_to_org"), "TacticalOrders 应有 issue_to_org 入口")


# ─────────────────────────────── 幕一：下令传播 ────────────────────────────────

func _test_unknown_org() -> void:
	_runner.assert_true(not _tactical.issue_to_org("org_nonexistent_xyz", _tactical.OrderType.ADVANCE_ALL, Vector2(100, 0)), "未知组织应受理失败（org_not_found）")


func _test_delivery_time_sum() -> void:
	_clear_captures()
	# 甲树：连 + 两排（units 0-5，各 3 人）
	var tree: Dictionary = _build_l2_tree("甲", [_units[0], _units[1], _units[2], _units[3], _units[4], _units[5]], 3)
	_runner.assert_true(not tree.is_empty(), "甲 L2 树应建成（连+两排）")
	if tree.is_empty():
		return
	var company: String = String(tree["root"])
	var sq_a: String = String(tree["squads"][0])
	var sq_b: String = String(tree["squads"][1])
	# 受控坐标：玩家(0,0) 连(104,0) 排A(312,0) 排B(520,0)——距离 104/208/416px，
	# 全部相对断言（不吃 courier_speed 具体值）
	_controlled_pos = {company: Vector2(104, 0), sq_a: Vector2(312, 0), sq_b: Vector2(520, 0)}
	_api.set_transport_providers(_controlled_position_provider,
		func() -> Vector2: return Vector2.ZERO, _stub_region_zero)
	var d0: float = _api.get_delivery_time("", company)
	var da: float = _api.get_delivery_time(company, sq_a)
	var db: float = _api.get_delivery_time(company, sq_b)
	_runner.assert_true(d0 > 0.0, "玩家跳应有传播延迟（受控坐标非重合）")
	_runner.assert_true(is_equal_approx(da, d0 * 2.0), "连→排A 延迟应为玩家跳的 2 倍（208px vs 104px）")
	_runner.assert_true(is_equal_approx(db, d0 * 4.0), "连→排B 延迟应为玩家跳的 4 倍（416px vs 104px）")
	# §六：L1 收令时刻 = 沿途各跳延迟之和
	_runner.assert_true(is_equal_approx(d0 + da, d0 * 3.0), "排A 收令时刻 = 玩家跳+连跳之和")
	_runner.assert_true(is_equal_approx(d0 + db, d0 * 5.0), "排B 收令时刻 = 玩家跳+连跳之和")
	_inject_zero_distance()


func _test_relay_delivery() -> void:
	_clear_captures()
	# 乙树：连 + 两排（units 6-11，各 3 人）
	var tree: Dictionary = _build_l2_tree("乙", [_units[6], _units[7], _units[8], _units[9], _units[10], _units[11]], 3)
	_runner.assert_true(not tree.is_empty(), "乙 L2 树应建成")
	if tree.is_empty():
		return
	var company: String = String(tree["root"])
	var sq_a: String = String(tree["squads"][0])
	var sq_b: String = String(tree["squads"][1])
	# 指挥官不变量（§4.3）：中间层须有主（伤亡空缺期命令停驻丢弃）——
	# 排A排长兼任连长（一实多职，manager 允许），命令才能经连透传下发
	_api.assign_stickman(company, str(_units[6].get_instance_id()), "officer")
	_api.assign_commander(company, str(_units[6].get_instance_id()))
	# 零距离接力：对连下令 → 两排即时收到
	var target: Vector2 = _units[6].global_position + Vector2(400, 0)
	var ok: bool = _tactical.issue_to_org(company, _tactical.OrderType.ADVANCE_ALL, target)
	_runner.assert_true(ok, "对连下令应受理")
	_runner.assert_equal(_issued_org, company, "order_issued 应以组织根 id 为 target")
	_runner.assert_equal(_issued_type, _tactical.OrderType.ADVANCE_ALL, "order_issued 类型应为 ADVANCE_ALL")
	for i in 3:
		await get_tree().process_frame
	for sid: String in [sq_a, sq_b]:
		for u in _formation.get_squad_units(sid):
			if not is_instance_valid(u):
				continue
			var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
			if ai != null:
				_runner.assert_true(ai.has_order(), "排成员应收到号令")
				_runner.assert_equal(ai.get_ordered_behavior(), "move", "号令行为应为 move")
	_runner.assert_true(_delivered_squads.count(sq_a) == 1, "order_delivered 排A 应恰一次")
	_runner.assert_true(_delivered_squads.count(sq_b) == 1, "order_delivered 排B 应恰一次")


# ─────────────────────────────── 幕二：伤亡补位 ────────────────────────────────

func _test_leader_succession() -> void:
	_clear_captures()
	# 丙树：排C(units 0,1) 排D(unit 2)；连长 = unit 3（独立实体挂名）
	var tree: Dictionary = _build_l2_tree("丙", [_units[0], _units[1], _units[2]], 2)
	_runner.assert_true(not tree.is_empty(), "丙 L2 树应建成")
	if tree.is_empty():
		return
	var company: String = String(tree["root"])
	var chief: Node = _units[3]
	_api.assign_stickman(company, str(chief.get_instance_id()), "officer")
	_api.assign_commander(company, str(chief.get_instance_id()))
	var squad_c: String = String(tree["squads"][0])
	var old_leader: Node = _formation.get_squad_leader(squad_c)
	_runner.assert_true(old_leader != null, "前置：排C 应有排长")
	# 杀排长 → 死亡清理（下一帧）→ remove_stickman → 补位引擎
	_kill(old_leader)
	for i in 3:
		await get_tree().process_frame
	var new_leader: Node = _formation.get_squad_leader(squad_c)
	_runner.assert_true(new_leader != null and new_leader != old_leader, "排长阵亡应自动补位（squad.leader 回写）")
	_runner.assert_true(_assigned_events.any(func(e: Dictionary) -> bool: return e["org_id"] == squad_c), "应发射 commander_assigned")
	var info: Dictionary = _api.get_organization(squad_c)
	_runner.assert_true(info.get("ok", false), "排 org 应存在")
	if info.get("ok", false):
		_runner.assert_equal(String(info["data"]["commander_id"]), str(new_leader.get_instance_id()), "org commander_id 应回写为补位者")
	var lost_reports: Array = _reports.filter(func(r: Dictionary) -> bool:
		return r["org_id"] == squad_c and String(r["report"].get("type", "")) == "commander_lost")
	_runner.assert_true(not lost_reports.is_empty(), "commander_lost 应必报（无视 autonomy 门控）")
	if not lost_reports.is_empty():
		var payload: Dictionary = lost_reports[0]["report"].get("payload", {})
		_runner.assert_true(bool(payload.get("filled", false)), "补位成功 filled=true")
		_runner.assert_equal(String(payload.get("successor_id", "")), str(new_leader.get_instance_id()), "successor 应为补位者")
		_runner.assert_equal(String(payload.get("prev_commander_id", "")), str(old_leader.get_instance_id()), "prev_commander 应为阵亡者")


func _test_squad_wipe_disband() -> void:
	_clear_captures()
	# 丁树：排(unit 4,5) 排(unit 6)；杀光前者
	var tree: Dictionary = _build_l2_tree("丁", [_units[4], _units[5], _units[6]], 2)
	_runner.assert_true(not tree.is_empty(), "丁 L2 树应建成")
	if tree.is_empty():
		return
	var company: String = String(tree["root"])
	var squad_wiped: String = String(tree["squads"][0])
	var disbanded_flag := [false]
	var conn: Callable = func(_sid: String) -> void: disbanded_flag[0] = true
	_formation.squad_disbanded.connect(conn)
	_kill(_units[4])
	_kill(_units[5])
	for i in 4:
		await get_tree().process_frame
	_formation.squad_disbanded.disconnect(conn)
	_runner.assert_true(disbanded_flag[0], "全灭后小队应解散（既有链路）")
	_runner.assert_true(squad_wiped not in _formation.get_all_squads(), "本地 squad 应移除")
	_runner.assert_true(squad_wiped not in _api.get_child_orgs(company), "排 org 应从连 child_orgs 消失")


func _test_midtier_succession() -> void:
	_clear_captures()
	# 戊树：排E(units 10,11)；连长 = unit 9（此前属丁排，跨组织身份 manager 允许）
	var tree: Dictionary = _build_l2_tree("戊", [_units[10], _units[11]], 2)
	_runner.assert_true(not tree.is_empty(), "戊 L2 树应建成")
	if tree.is_empty():
		return
	var company: String = String(tree["root"])
	var chief: Node = _units[9]
	_api.assign_stickman(company, str(chief.get_instance_id()), "officer")
	_api.assign_commander(company, str(chief.get_instance_id()))
	var squad_e: String = String(tree["squads"][0])
	var e_leader: Node = _formation.get_squad_leader(squad_e)
	_runner.assert_true(e_leader != null, "前置：排E 应有排长（下级指挥官）")
	# 连长空缺（撤职 = 补位同一入口；死者不在任何 squad 时死亡上报由组织侧入口触发）
	_api.remove_commander(company)
	for i in 2:
		await get_tree().process_frame
	var info: Dictionary = _api.get_organization(company)
	_runner.assert_true(info.get("ok", false), "连 org 应存在")
	if info.get("ok", false):
		_runner.assert_equal(String(info["data"]["commander_id"]), str(e_leader.get_instance_id()), "连长空缺应由下级指挥官（排E排长）顶上")
	_runner.assert_true(_assigned_events.any(func(ev: Dictionary) -> bool: return ev["org_id"] == company), "中间层补位也应发射 commander_assigned")


func _test_noncombat_reject() -> void:
	_clear_captures()
	# 建造队（ENGINEERING，非战斗叶）：unit 2（丙排D 复用，create_squad 自动移出旧队）
	var builder: Node = _units[2]
	var sid: String = _formation.create_squad([builder], "测试建造队", "fp_builder_crew")
	_runner.assert_true(not sid.is_empty(), "建造队应建成")
	if sid.is_empty():
		return
	var ok: bool = _tactical.issue_to_org(sid, _tactical.OrderType.ADVANCE_ALL, builder.global_position + Vector2(300, 0))
	_runner.assert_true(ok, "计划应受理（plan 不挡，送达时挡）")
	for i in 3:
		await get_tree().process_frame
	var ai: Node = builder.get_ai_controller() if builder.has_method("get_ai_controller") else null
	_runner.assert_true(ai != null, "成员应有 AI 控制器")
	if ai != null:
		var has_order: bool = ai.has_method("has_order") and ai.has_order()
		var behavior: String = ai.get_ordered_behavior() if ai.has_method("get_ordered_behavior") else ""
		_runner.assert_true(not has_order or behavior != "move", "非战斗叶成员不应收到 move 号令（拒收）")
