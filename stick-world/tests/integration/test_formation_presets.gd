extends Node
## 集成测试：队伍类型编制（FormationPreset + 职责过滤）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_formation_presets.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 编制预设加载（战斗班/建造队/工人队）
##   - 按预设创建编队（组织标签映射 + 成员角色写入）
##   - 职责范围查询 / 调整（set_squad_work_types）
##   - is_work_allowed 行为过滤（编队单位受限，未编队全能）
##   - is_combat_squad 战斗职责判定
##   - TacticalOrders 拒绝非战斗职责小队的号令
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位数量
const UNIT_COUNT: int = 6

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
var _org_api: Node = null
var _tactical: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "预设: 三模板已加载", "fn": Callable(self, "_test_presets_loaded"), "async": false})
	_tests.append({"name": "预设: 按预设建队映射组织标签", "fn": Callable(self, "_test_create_with_preset"), "async": true})
	_tests.append({"name": "职责: 工作类型查询与过滤", "fn": Callable(self, "_test_work_types_and_filter"), "async": true})
	_tests.append({"name": "职责: 调整职责范围", "fn": Callable(self, "_test_set_work_types"), "async": true})
	_tests.append({"name": "号令: 非战斗小队被拒绝", "fn": Callable(self, "_test_tactical_reject"), "async": true})
	_tests.append({"name": "角色: 编队写入与移出清除", "fn": Callable(self, "_test_role_write_clear"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	_org_api = _helper.game_root.get_organization_api() if _helper.game_root != null and _helper.game_root.has_method("get_organization_api") else null
	_tactical = _helper.tactical
	# 生成测试单位
	_helper.spawn_test_units(UNIT_COUNT)
	for i in 1:
		await get_tree().process_frame
	# 注入 FormationSystem 引用（模拟 GameRoot spawn 注入）
	for u in _helper.units:
		if u != null and u.has_method("set_formation_system"):
			u.set_formation_system(_formation)

	# 运行同步测试
	for t in _tests:
		if not t["async"]:
			_runner.add_test(t["name"], t["fn"])
	_runner.run()

	# 运行异步测试
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


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_presets_loaded() -> void:
	_runner.assert_true(_formation != null, "FormationSystem 应已装配")
	if _formation == null:
		return
	_runner.assert_true(_formation.has_method("get_all_presets"), "应提供 get_all_presets")
	var presets: Array = _formation.get_all_presets()
	_runner.assert_true(presets.size() >= 3, "应至少有 3 个预设（战斗班/建造队/工人队）")
	var ids: Array = []
	for p in presets:
		ids.append(p.get("id", ""))
	_runner.assert_true("fp_combat_squad" in ids, "应包含 fp_combat_squad")
	_runner.assert_true("fp_builder_crew" in ids, "应包含 fp_builder_crew")
	_runner.assert_true("fp_worker_crew" in ids, "应包含 fp_worker_crew")
	# 校验战斗班预设字段
	var combat: Dictionary = _formation.get_preset("fp_combat_squad")
	_runner.assert_equal(combat.get("tag", ""), "MILITARY", "战斗班标签应为 MILITARY")
	_runner.assert_true("WORK_COMBAT" in combat.get("work_types", []), "战斗班职责应含 WORK_COMBAT")


# ─────────────────────────────── 异步测试 ────────────────────────────────

## 按预设创建编队：组织标签映射 + 成员角色写入
func _test_create_with_preset() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 建造队
	var squad_id: String = _formation.create_squad([_helper.units[0], _helper.units[1]], "", "fp_builder_crew")
	_runner.assert_true(not squad_id.is_empty(), "建造队应创建成功")
	# 组织标签映射
	if _org_api != null:
		var org: Dictionary = _org_api.get_organization(squad_id)
		_runner.assert_true(org.get("ok", false), "组织应存在")
		_runner.assert_equal(org.get("data", {}).get("tag", -1), OrganizationState.Tag.ENGINEERING, "建造队组织标签应为 ENGINEERING")
	# 成员角色写入
	_runner.assert_equal(_helper.units[0].get_role(), "builder", "成员 role 应为 builder")
	_runner.assert_equal(_formation.get_squad_preset(squad_id), "fp_builder_crew", "squad preset 应记录")
	# 工人队（LABOR 标签）
	var worker_id: String = _formation.create_squad([_helper.units[2]], "", "fp_worker_crew")
	_runner.assert_true(not worker_id.is_empty(), "工人队应创建成功")
	if _org_api != null:
		var worg: Dictionary = _org_api.get_organization(worker_id)
		_runner.assert_equal(worg.get("data", {}).get("tag", -1), OrganizationState.Tag.LABOR, "工人队组织标签应为 LABOR")
	# 战斗班（默认预设）
	var combat_id: String = _formation.create_squad([_helper.units[3], _helper.units[4]])
	_runner.assert_true(not combat_id.is_empty(), "默认预设战斗班应创建成功")
	if _org_api != null:
		var corg: Dictionary = _org_api.get_organization(combat_id)
		_runner.assert_equal(corg.get("data", {}).get("tag", -1), OrganizationState.Tag.MILITARY, "战斗班组织标签应为 MILITARY")


## 职责范围查询与过滤：编队单位受限，未编队全能
func _test_work_types_and_filter() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var builder_id: String = _formation.get_unit_squad(_helper.units[0])
	_runner.assert_true(not builder_id.is_empty(), "unit 0 应在建造队")
	# 建造队职责
	var wts: Array = _formation.get_squad_work_types(builder_id)
	_runner.assert_true("WORK_BUILD" in wts, "建造队应含 WORK_BUILD")
	_runner.assert_true("WORK_HAUL" in wts, "建造队应含 WORK_HAUL")
	# 过滤：建造队允许建造/搬运，禁止战斗
	_runner.assert_true(_formation.is_work_allowed(_helper.units[0], "WORK_BUILD"), "建造队允许建造")
	_runner.assert_true(_formation.is_work_allowed(_helper.units[0], "WORK_HAUL"), "建造队允许搬运")
	_runner.assert_true(not _formation.is_work_allowed(_helper.units[0], "WORK_COMBAT"), "建造队禁止战斗")
	# 战斗班：允许战斗，禁止建造
	var combat_id: String = _formation.get_unit_squad(_helper.units[3])
	_runner.assert_true(not combat_id.is_empty(), "unit 3 应在战斗班")
	_runner.assert_true(_formation.is_work_allowed(_helper.units[3], "WORK_COMBAT"), "战斗班允许战斗")
	_runner.assert_true(not _formation.is_work_allowed(_helper.units[3], "WORK_BUILD"), "战斗班禁止建造")
	# 未编队单位全能
	_runner.assert_true(_formation.is_work_allowed(_helper.units[5], "WORK_BUILD"), "未编队单位应允许建造")
	_runner.assert_true(_formation.is_work_allowed(_helper.units[5], "WORK_COMBAT"), "未编队单位应允许战斗")
	# 战斗职责判定
	_runner.assert_true(_formation.is_combat_squad(combat_id), "战斗班 is_combat_squad 应为 true")
	_runner.assert_true(not _formation.is_combat_squad(builder_id), "建造队 is_combat_squad 应为 false")


## 调整职责范围
func _test_set_work_types() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var combat_id: String = _formation.get_unit_squad(_helper.units[3])
	if combat_id.is_empty():
		_runner.assert_true(false, "找不到战斗班")
		return
	# 给战斗班加搬运职责（"职责可调整"）
	var ok: bool = _formation.set_squad_work_types(combat_id, ["WORK_COMBAT", "WORK_HAUL"])
	_runner.assert_true(ok, "调整职责应成功")
	var wts: Array = _formation.get_squad_work_types(combat_id)
	_runner.assert_true("WORK_HAUL" in wts, "职责应包含 WORK_HAUL")
	_runner.assert_true(_formation.is_work_allowed(_helper.units[3], "WORK_HAUL"), "调整后应允许搬运")
	# 恢复原状（后续测试依赖）
	_formation.set_squad_work_types(combat_id, ["WORK_COMBAT"])


## TacticalOrders 拒绝非战斗职责小队
func _test_tactical_reject() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "TacticalOrders 或 FormationSystem 为空")
		return
	var builder_id: String = _formation.get_unit_squad(_helper.units[0])
	if builder_id.is_empty():
		_runner.assert_true(false, "找不到建造队")
		return
	# 对建造队下达前进号令应被拒绝
	var rejected: bool = _tactical.issue(0, builder_id, Vector2(2000, 500))
	_runner.assert_true(not rejected, "建造队号令应被拒绝")
	# 对战斗班下达应成功
	var combat_id: String = _formation.get_unit_squad(_helper.units[3])
	if combat_id.is_empty():
		_runner.assert_true(false, "找不到战斗班")
		return
	var accepted: bool = _tactical.issue(0, combat_id, Vector2(2000, 500))
	_runner.assert_true(accepted, "战斗班号令应成功")


## 角色写入与移出清除
func _test_role_write_clear() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var worker_id: String = _formation.get_unit_squad(_helper.units[2])
	if worker_id.is_empty():
		_runner.assert_true(false, "找不到工人队")
		return
	var u: Node = _helper.units[2]
	_runner.assert_equal(u.get_role(), "worker", "工人队成员 role 应为 worker")
	# 移出后角色清除
	_formation.remove_unit(u)
	_runner.assert_equal(u.get_role(), "", "移出后 role 应清空")
	_runner.assert_true(_formation.get_unit_squad(u).is_empty(), "移出后应不在小队中")
