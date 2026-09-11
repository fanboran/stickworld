extends Node
## 集成测试：组织管理面板 OrgPanel（批次 2）——UI 操作 → org 状态断言。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_org_panel.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖（架构文档 §三 / §六）：
##   - 路径全部同步（面板刷新由信号/回调直接驱动，无帧间等待），可批量跑
##   - 装配：OrgPanel 实例化 + open/close
##   - 新 API：list_root_orgs / set_org_name / list_preset_names
##   - 树构建：预设创建 → 单根；org_disbanded 信号 → 全量重建
##   - 详情区：字段展示；改名/新建子编制/插入上层（任命统辖）/自主权限/过滤/解散清选中
##
## 插入上层需空层级（child.tier = parent.tier - 1 恒成立）：用例先 remove_tier 制造空层。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptFakeRoot := preload("res://tests/helpers/org_panel_test_game_root.gd")
const ScriptOrgPanel := preload("res://modules/organization/ui/org_panel.gd")

var _runner: TestRunner
var _api: Node = null
var _panel: Control = null


func _ready() -> void:
	_runner = TestRunner.new()
	_setup_env()
	_run_tests()


# ─────────────────────────────── 环境搭建 ────────────────────────────────

## 轻量环境：真 manager + 真 api（信号路径全真），OrgPanel 直接实例化挂本场景。
## 不拉全量 game_root（面板只依赖 org api 引用，与战斗系统零耦合）。
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
	var panel: Control = ScriptOrgPanel.new()
	add_child(panel)
	panel.setup(fake)
	_panel = panel


# ─────────────────────────────── 测试执行 ────────────────────────────────

func _run_tests() -> void:
	_runner.add_test("装配: OrgPanel 已挂载且可开关", _test_assembly)
	_runner.add_test("新API: list_root_orgs 列根组织", _test_list_root_orgs)
	_runner.add_test("新API: list_preset_names 列预设名", _test_list_preset_names)
	_runner.add_test("树: 预设创建后组织树含全部节点", _test_tree_built_from_preset)
	_runner.add_test("树: 解散信号触发全量重建（节点消失）", _test_tree_rebuild_on_signal)
	_runner.add_test("详情: 选中节点展示字段（层级/标签/指挥官）", _test_detail_fields)
	_runner.add_test("操作: 改名经 API 落到 org 状态", _test_rename)
	_runner.add_test("操作: 新建子编制 L1 挂到选中组织", _test_create_child)
	_runner.add_test("操作: 插入上层=任命统辖（建层+任命一次完成）", _test_insert_above_with_commander)
	_runner.add_test("操作: 自主权限即点即改", _test_autonomy)
	_runner.add_test("过滤: 军事标签下非军事根不显示", _test_tag_filter)
	_runner.add_test("操作: 解散后选中态清空", _test_disband_clears_selection)
	_runner.run()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_assembly() -> void:
	_runner.assert_true(_panel != null, "OrgPanel 应已实例化")
	_runner.assert_true(_panel.has_method("open") and _panel.has_method("close"), "应有 open/close")
	_panel.open()
	_runner.assert_true(_panel.visible, "open 后应可见")
	_panel.close()
	_runner.assert_false(_panel.visible, "close 后应隐藏")


func _test_list_root_orgs() -> void:
	var r1: Dictionary = _api.create_organization("测试旅", "MILITARY", 5, "")
	_runner.assert_true(r1.get("ok", false), "独立根创建应成功")
	var roots: Array = _api.list_root_orgs()
	_runner.assert_true(String(r1.data.org_id) in roots, "新根应出现在 list_root_orgs")
	_api.create_organization("测试连", "MILITARY", 4, String(r1.data.org_id))
	_runner.assert_equal(_api.list_root_orgs().size(), roots.size(), "挂子组织后根数不变")
	_api.disband_organization(String(r1.data.org_id))


func _test_list_preset_names() -> void:
	var names: Array = _api.list_preset_names()
	_runner.assert_true(names.size() >= 5, "presets.tres 五套预设应可列（实际 %d）" % names.size())
	_runner.assert_true("军事编制" in names, "应含「军事编制」")


func _test_tree_built_from_preset() -> void:
	var r: Dictionary = _api.load_preset("军事编制", "")
	_runner.assert_true(r.get("ok", false), "军事编制预设应创建成功")
	_runner.assert_equal((r.data.created as Array).size(), 5, "军事编制应 5 个节点（师团营连排）")
	_runner.assert_equal(_visible_root_count(), 1, "树应显示单根")


func _test_tree_rebuild_on_signal() -> void:
	var roots: Array = _api.list_root_orgs()
	_runner.assert_equal(roots.size(), 1, "前置：应有单根（军事编制师）")
	_api.disband_organization(String(roots[0]))
	_runner.assert_equal(_visible_root_count(), 0, "解散后树应清空（信号驱动重建）")


func _test_detail_fields() -> void:
	var r: Dictionary = _api.create_organization("甲师", "MILITARY", 5, "")
	var org_id := String(r.data.org_id)
	_api.assign_stickman(org_id, "1001", "fighter")
	_api.assign_commander(org_id, "1001")
	_select_org(org_id)
	var info := _detail_label_text()
	_runner.assert_true(info.contains("甲师"), "详情应含组织名")
	_runner.assert_true(info.contains("L5"), "详情应含层级")
	_runner.assert_true(info.contains("军事"), "详情应含标签中文")
	_runner.assert_true(info.contains("▲#1001"), "详情应含指挥官标识")
	_api.disband_organization(org_id)
	_selected_clear()


func _test_rename() -> void:
	var r: Dictionary = _api.create_organization("乙团", "MILITARY", 4, "")
	var org_id := String(r.data.org_id)
	_select_org(org_id)
	var edit: LineEdit = _panel._rename_edit
	_runner.assert_true(edit != null, "详情区应有改名输入框")
	edit.text = "乙团改"
	_panel._on_rename_pressed()
	var d: Dictionary = _api.get_organization(org_id)
	_runner.assert_true(String(d.data.name) == "乙团改", "org 名应改为「乙团改」")
	_api.disband_organization(org_id)
	_selected_clear()


func _test_create_child() -> void:
	var r: Dictionary = _api.create_organization("丙连", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_select_org(org_id)
	_runner.assert_true(_panel._child_name_edit != null, "L2 组织应有新建子编制行")
	_panel._child_name_edit.text = "丁排"
	_panel._on_create_child_pressed("MILITARY")
	var kids: Array = _api.get_child_orgs(org_id)
	_runner.assert_equal(kids.size(), 1, "选中组织应有 1 个子编制")
	var kid: Dictionary = _api.get_organization(String(kids[0]))
	_runner.assert_true(String(kid.data.name) == "丁排" and int(kid.data.tier) == 1, "子编制应为 L1「丁排」")
	_api.disband_organization(org_id)
	_selected_clear()


func _test_insert_above_with_commander() -> void:
	# 链 L4→L3→L2→L1，删 L3 制造空层，再对 L2「插入上层」补回 L3（任命统辖：建层+任命一次完成）
	var l4: Dictionary = _api.create_organization("子测团", "MILITARY", 4, "")
	var l4id := String(l4.data.org_id)
	var l3: Dictionary = _api.create_organization("子测营", "MILITARY", 3, l4id)
	var l2: Dictionary = _api.create_organization("子测连", "MILITARY", 2, String(l3.data.org_id))
	var l2id := String(l2.data.org_id)
	var l1: Dictionary = _api.create_organization("子测排", "MILITARY", 1, l2id)
	var l1id := String(l1.data.org_id)
	_api.assign_stickman(l1id, "2001", "fighter")
	_api.assign_commander(l1id, "2001")
	_api.remove_tier(String(l3.data.org_id))
	_runner.assert_true(String(_api.get_organization(l2id).data.parent_org) == l4id, "删层后连应上挂团")
	_select_org(l2id)
	_panel._on_insert_pressed("above")
	_runner.assert_true(_panel._insert_name_edit != null, "应进入插入流程态")
	_runner.assert_true(_panel._insert_commander_option != null, "中间层应要求指挥官人选")
	_runner.assert_equal(_panel._insert_commander_option.get_item_count(), 1, "候选应恰为排长 1 人")
	_panel._insert_name_edit.text = "子测新营"
	_panel._on_insert_confirm(3)
	var kids: Array = _api.get_child_orgs(l4id)
	_runner.assert_equal(kids.size(), 1, "团下应挂新层")
	var new_org: Dictionary = _api.get_organization(String(kids[0]))
	_runner.assert_true(String(new_org.data.name) == "子测新营" and int(new_org.data.tier) == 3, "新层应为 L3「子测新营」")
	_runner.assert_true(String(new_org.data.commander_id) == "2001", "新层指挥官应为排长 2001（任命统辖）")
	_runner.assert_true(String(_api.get_organization(l2id).data.parent_org) == String(kids[0]), "连应改挂新层")
	_api.disband_organization(l4id)
	_selected_clear()


func _test_autonomy() -> void:
	var r: Dictionary = _api.create_organization("庚队", "MILITARY", 3, "")
	var org_id := String(r.data.org_id)
	_select_org(org_id)
	_runner.assert_true(_panel._autonomy_option != null, "应有自主权限下拉")
	_panel._autonomy_option.select(0)  # HIGH
	_panel._on_autonomy_selected(0)
	var d: Dictionary = _api.get_organization(org_id)
	_runner.assert_equal(int(d.data.autonomy_level), 0, "自主权限应落为 HIGH")
	_api.disband_organization(org_id)
	_selected_clear()


func _test_tag_filter() -> void:
	_api.create_organization("独苗科研", "RESEARCH", 5, "")
	_api.create_organization("独苗军事", "MILITARY", 5, "")
	_panel._on_tab_selected(_tab_index("MILITARY"))
	_runner.assert_equal(_visible_root_count(), 1, "军事标签下应只显示军事根")
	_panel._on_tab_selected(0)
	_runner.assert_true(_visible_root_count() >= 2, "全部标签应显示所有根")
	for root_id in _api.list_root_orgs():
		_api.disband_organization(String(root_id))


func _test_disband_clears_selection() -> void:
	var r: Dictionary = _api.create_organization("辛队", "MILITARY", 4, "")
	var org_id := String(r.data.org_id)
	_select_org(org_id)
	_api.disband_organization(org_id)
	_runner.assert_true(String(_panel._selected_org).is_empty(), "解散后选中态应清空（防悬空引用）")


# ─────────────────────────────── 工具 ────────────────────────────────

## 驱动树选中（item_selected 路径 → _selected_org → 详情区）
func _select_org(org_id: String) -> void:
	_panel.open()
	_panel._refresh_tree()
	var found := _find_item(_panel._tree.get_root(), org_id)
	_runner.assert_true(found != null, "树中应能找到组织 %s" % org_id)
	if found != null:
		found.select(0)
		_panel._on_tree_item_selected()


func _find_item(item: TreeItem, org_id: String) -> TreeItem:
	if item == null:
		return null
	var meta: Variant = item.get_metadata(0)
	if meta != null and String(meta) == org_id:
		return item
	for child in item.get_children():
		var hit := _find_item(child, org_id)
		if hit != null:
			return hit
	return null


func _detail_label_text() -> String:
	var texts: Array = []
	for child in _panel._detail_box.get_children():
		if child is Label:
			texts.append((child as Label).text)
	return "\n".join(texts)


func _visible_root_count() -> int:
	var root_item: TreeItem = _panel._tree.get_root()
	if root_item == null:
		return 0
	return root_item.get_child_count()


func _tab_index(tag_id: String) -> int:
	for i in _panel.TABS.size():
		if String(_panel.TABS[i]["id"]) == tag_id:
			return i
	return 0


func _selected_clear() -> void:
	_panel._selected_org = ""
	_panel._refresh_tree()
