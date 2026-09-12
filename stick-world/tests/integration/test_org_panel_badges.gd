extends Node
## 集成测试：OrgPanel 树节点状态徽标与组织概览卡（UI-W2-B ①）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_org_panel_badges.tscn -- --fresh-start
##
## 覆盖：
##   - 状态徽标（org state 字段 → 中文）
##   - 士气均值徽标（聚合成员实体 health.morale；取不到则不显示）
##   - 「群龙无首」空缺标记（L2+ 指挥官空缺；L1 空架不算）
##   - 补位候选序（悬停提示 + 详情卡只读展示）
##   - 既有主干文案不变（[L1] 名称 · 标签 N人 ▲#id）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptFakeRoot := preload("res://tests/helpers/org_panel_test_game_root.gd")
const ScriptOrgPanel := preload("res://modules/organization/ui/org_panel.gd")
const HealthScript := preload("res://modules/units/scripts/entity/health_component.gd")


## 测试桩单位：只需 duck 出 get_health / is_dead（面板经在场实体索引反查，零类型耦合）
class StubUnit extends Node:
	var health: Node = null

	func get_health() -> Node:
		return health

	func is_dead() -> bool:
		return false


## 测试桩地图：面板经 get_current_map().get_entities() 取在场实体（士气聚合口径）
class StubMap extends Node:
	var entities: Array = []

	func get_entities() -> Array:
		return entities


var _runner: TestRunner
var _api: Node = null
var _panel: Control = null
var _stub_map: StubMap = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("树: 主干文案不回归 + 状态徽标", _test_trunk_and_state)
	_runner.add_test("树: 士气均值徽标（聚合成员实体）", _test_morale_badge)
	_runner.add_test("树: 群龙无首标记（L2+ 空缺，红字）", _test_leaderless_mark)
	_runner.add_test("树: 补位候选序进悬停提示（只读）", _test_tooltip_candidates)
	_runner.add_test("详情: 概览卡含空缺警示 + 补位候选序", _test_detail_vitals)
	_setup_env()
	_runner.run()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 环境搭建 ────────────────────────────────

func _setup_env() -> void:
	var mgr = ScriptOrgManager.new()
	var api := Node.new()
	api.set_script(load("res://modules/organization/api.gd"))
	api.name = "OrganizationApi"
	add_child(api)
	api.setup(mgr)
	_api = api
	var fake := Node.new()
	fake.name = "FakeGameRoot"
	fake.set_script(ScriptFakeRoot)
	add_child(fake)
	_stub_map = StubMap.new()
	_stub_map.name = "StubMap"
	add_child(_stub_map)
	fake.map = _stub_map
	var panel: Control = ScriptOrgPanel.new()
	add_child(panel)
	panel.setup(fake)
	_panel = panel


## 造一个可解析士气的桩单位（health.morale / max_morale → ratio）
func _make_unit(morale_ratio: float) -> StubUnit:
	var health := HealthScript.new()
	health.max_morale = 100.0
	health.morale = morale_ratio * 100.0
	var u := StubUnit.new()
	u.health = health
	_stub_map.add_child(u)   # 进树 = 场景销毁时一并释放（防 ObjectDB 泄漏告警）
	_stub_map.entities.append(u)
	return u


func _find_item(org_id: String) -> TreeItem:
	return _find_recursive(_panel._tree.get_root(), org_id)


func _find_recursive(item: TreeItem, org_id: String) -> TreeItem:
	if item == null:
		return null
	var meta: Variant = item.get_metadata(0)
	if meta != null and String(meta) == org_id:
		return item
	for child in item.get_children():
		var hit := _find_recursive(child, org_id)
		if hit != null:
			return hit
	return null


## 递归收集详情区全部 Label（概览卡的标签在 SketchPanel > VBox 内，非详情区直接子级）
func _detail_text() -> String:
	var texts: Array = []
	_collect_labels(_panel._detail_box, texts)
	return "\n".join(texts)


func _collect_labels(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is Label:
			out.append((child as Label).text)
		_collect_labels(child, out)


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_trunk_and_state() -> void:
	var r: Dictionary = _api.create_organization("连甲", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_api.assign_stickman(org_id, "7001", "fighter")
	_api.assign_commander(org_id, "7001")
	_panel.open()
	_panel._refresh_tree()
	var item := _find_item(org_id)
	_runner.assert_not_null(item, "树应含连甲节点")
	if item == null:
		return
	var text := String(item.get_text(0))
	# 主干格式不回归（既有测试断言依赖：▲#id 指挥官标记）
	_runner.assert_true(text.contains("[L2] 连甲 · 军事 1人"), "主干文案应保持，实际：%s" % text)
	_runner.assert_true(text.contains("▲#7001"), "指挥官标记应保持 ▲#id，实际：%s" % text)
	# 状态徽标（新建组织默认 state=FORMING=0 → 组建中）
	_runner.assert_true(text.contains("组建中"), "应带组织状态徽标，实际：%s" % text)


func _test_morale_badge() -> void:
	var r: Dictionary = _api.create_organization("排甲1", "MILITARY", 1, "")
	var org_id := String(r.data.org_id)
	var u1 := _make_unit(0.4)
	var u2 := _make_unit(0.6)
	_api.assign_stickman(org_id, str(u1.get_instance_id()), "fighter")
	_api.assign_stickman(org_id, str(u2.get_instance_id()), "fighter")
	_panel._refresh_tree()
	var item := _find_item(org_id)
	_runner.assert_not_null(item, "树应含排甲1节点")
	if item == null:
		return
	var text := String(item.get_text(0))
	_runner.assert_true(text.contains("士气50%"), "成员士气均值 0.5 应显示为 50%%，实际：%s" % text)
	_runner.assert_true(String(item.get_tooltip_text(0)).contains("士气均值：50%"),
			"悬停提示应带士气均值")
	_api.disband_organization(org_id)


func _test_leaderless_mark() -> void:
	var r: Dictionary = _api.create_organization("连乙", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_panel._refresh_tree()
	var item := _find_item(org_id)
	_runner.assert_not_null(item, "树应含连乙节点")
	if item == null:
		return
	var text := String(item.get_text(0))
	_runner.assert_true(text.contains("群龙无首"), "L2 空缺应带群龙无首标记，实际：%s" % text)
	_runner.assert_false(text.contains("▲"), "空缺态不得有指挥官标记，实际：%s" % text)
	_runner.assert_equal(item.get_custom_color(0), StickTokens.DANGER, "空缺标记应着危险色")
	# L1 空架招兵不算空缺（不制造假警报）
	var c: Dictionary = _api.create_organization("排乙1", "MILITARY", 1, org_id)
	_panel._refresh_tree()
	var child := _find_item(String(c.data.org_id))
	_runner.assert_not_null(child, "树应含排乙1节点")
	if child != null:
		_runner.assert_false(String(child.get_text(0)).contains("群龙无首"),
				"L1 空架（FORMING）不应标群龙无首，实际：%s" % child.get_text(0))
	_api.disband_organization(org_id)


func _test_tooltip_candidates() -> void:
	var r: Dictionary = _api.create_organization("连丙", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	var pr: Dictionary = _api.create_organization("排丙1", "MILITARY", 1, org_id)
	_api.assign_stickman(String(pr.data.org_id), "7101", "fighter")
	_api.assign_commander(String(pr.data.org_id), "7101")
	_api.assign_stickman(org_id, "7102", "fighter")
	_api.assign_commander(org_id, "7102")
	_panel._refresh_tree()
	var item := _find_item(org_id)
	_runner.assert_not_null(item, "树应含连丙节点")
	if item != null:
		var tip := String(item.get_tooltip_text(0))
		_runner.assert_true(tip.contains("补位候选序"), "悬停提示应含补位候选序，实际：%s" % tip)
		_runner.assert_true(tip.contains("▲#7101"), "候选序应含下级指挥官（排长候选）")
	_api.disband_organization(org_id)


func _test_detail_vitals() -> void:
	var r: Dictionary = _api.create_organization("连丁", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_panel._selected_org = org_id
	_panel._refresh_detail()
	var text := _detail_text()
	_runner.assert_true(text.contains("群龙无首：指挥官空缺"), "详情卡应警示空缺，实际：%s" % text)
	_api.disband_organization(org_id)
