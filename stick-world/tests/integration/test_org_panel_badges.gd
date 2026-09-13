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
##   - 直属为 0 时省略「N人」段（L2+ 不显示 0人、不留空段/孤分隔点）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptFakeRoot := preload("res://tests/helpers/org_panel_test_game_root.gd")
const ScriptOrgPanel := preload("res://modules/organization/ui/org_panel.gd")
const ScriptOverview := preload("res://modules/organization/ui/strategic_overview_panel.gd")
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
var _overview: Control = null
var _stub_map: StubMap = null
## ui_notification 捕获（拖拽调人成败提示路径断言）
var _notes: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("树: 主干文案不回归 + 状态徽标", _test_trunk_and_state)
	_runner.add_test("树: 直属为 0 省略 N人 段（不留空段）", _test_zero_direct_omits_headcount)
	_runner.add_test("树: 士气均值徽标（聚合成员实体）", _test_morale_badge)
	_runner.add_test("树: 群龙无首标记（L2+ 空缺，红字）", _test_leaderless_mark)
	_runner.add_test("树: 补位候选序进悬停提示（只读）", _test_tooltip_candidates)
	_runner.add_test("详情: 概览卡含空缺警示 + 补位候选序", _test_detail_vitals)
	_runner.add_test("OrgPanel: 选中变更发 org_selection_changed（关闭清空）", _test_selection_signal)
	_runner.add_test("总览: 报表行含人数/状态/士气（森林缩进）", _test_overview_rows)
	_runner.add_test("总览: report_filed → 时间线条目 + 行尾最近上报", _test_overview_timeline)
	_runner.add_test("总览: commander_assigned → 时间线条目", _test_overview_assign)
	_runner.add_test("总览: 标签过滤（非匹配组织不生成行）", _test_overview_tag_filter)
	_runner.add_test("总览: 选中行仅本面板高亮", _test_overview_select_row)
	_runner.add_test("总览: 拖拽调人成功（迁移+通知+刷新）", _test_overview_transfer_drag_ok)
	_runner.add_test("总览: 拖拽调人失败走通知（状态不变）", _test_overview_transfer_drag_fail)
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
	var overview: Control = ScriptOverview.new()
	add_child(overview)
	overview.setup(fake)
	_overview = overview


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


## 直属成员为 0 时，主干省略「N人」段：不显示 0人、不造空段/孤分隔点（L2+ 直属通常为 0）。
func _test_zero_direct_omits_headcount() -> void:
	# ① L2 无直属、无下级：只留「标签」段，不出现 0人 与连续分隔点
	var r: Dictionary = _api.create_organization("连戊", "MILITARY", 2, "")
	var company := String(r.data.org_id)
	_panel._refresh_tree()
	var item := _find_item(company)
	_runner.assert_not_null(item, "树应含连戊节点")
	if item != null:
		var text := String(item.get_text(0))
		_runner.assert_false(text.contains("0人"), "直属为 0 不得显示 0人，实际：%s" % text)
		_runner.assert_false(text.contains("· ·"), "不得出现连续分隔点，实际：%s" % text)
		_runner.assert_true(text.begins_with("[L2] 连戊 · 军事"), "标签段应保留，实际：%s" % text)
	# ② L2 无直属、有下级：仍省略直属段，但保留统辖规模段
	var c: Dictionary = _api.create_organization("排戊1", "MILITARY", 1, company)
	_api.assign_stickman(String(c.data.org_id), "7201", "fighter")
	_api.assign_commander(String(c.data.org_id), "7201")
	_panel._refresh_tree()
	var item2 := _find_item(company)
	_runner.assert_not_null(item2, "树应含连戊节点（带下级）")
	if item2 != null:
		var text2 := String(item2.get_text(0))
		_runner.assert_false(text2.contains("0人"), "直属为 0 不得显示 0人，实际：%s" % text2)
		_runner.assert_true(text2.contains("辖1人"), "有下级时应保留统辖规模段，实际：%s" % text2)
	# ③ L1 叶层直属 >0：N人 段照旧保留（不误伤既有口径）
	var leaf := _find_item(String(c.data.org_id))
	_runner.assert_not_null(leaf, "树应含排戊1节点")
	if leaf != null:
		_runner.assert_true(String(leaf.get_text(0)).contains("[L1] 排戊1 · 军事 1人"),
				"直属 >0 时 N人 段应保留，实际：%s" % leaf.get_text(0))
	_api.disband_organization(company)


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


# ─────────────────────── UI-W4b：OrgPanel 选中信号 ───────────────────────

## 选中变更导出（装配层据此联动班组卡）；关闭面板导出「无选中」。
func _test_selection_signal() -> void:
	var seen: Array = []
	var cb := func(oid: String) -> void:
		seen.append(oid)
	_panel.org_selection_changed.connect(cb)
	_panel.open()
	var r: Dictionary = _api.create_organization("信令连", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_panel._refresh_tree()
	var item := _find_item(org_id)
	_runner.assert_not_null(item, "树应含信令连节点")
	if item != null:
		item.select(0)
		_panel._on_tree_item_selected()
		_runner.assert_true(seen.has(org_id), "选中组织应发 org_selection_changed(%s)，实际：%s" % [org_id, seen])
	_panel.close()
	_runner.assert_false(seen.is_empty(), "关闭应至少发一次选中变更")
	if not seen.is_empty():
		_runner.assert_equal(String(seen[-1]), "", "关闭面板应导出空选中（收起班组卡）")
	_panel.org_selection_changed.disconnect(cb)
	_api.disband_organization(org_id)


# ─────────────────────── UI-W4b：战略总览面板 ───────────────────────

## 报表行：人数（直辖/统辖）+ 状态 + 士气均值条（经在场实体表聚合）+ 森林缩进。
func _test_overview_rows() -> void:
	var r: Dictionary = _api.create_organization("总览连", "MILITARY", 2, "")
	var company := String(r.data.org_id)
	var c: Dictionary = _api.create_organization("总览排", "MILITARY", 1, company)
	var platoon := String(c.data.org_id)
	var u1 := _make_unit(0.4)
	var u2 := _make_unit(0.6)
	_api.assign_stickman(platoon, str(u1.get_instance_id()), "fighter")
	_api.assign_stickman(platoon, str(u2.get_instance_id()), "fighter")
	_overview.open()
	_runner.assert_true(_overview.visible, "总览 open 后应可见")
	var row: Control = _overview._rows.get(company, null)
	_runner.assert_not_null(row, "L2 连报表行应生成")
	if row == null:
		return
	var text := _row_text(row)
	_runner.assert_true(text.contains("直辖 0") and text.contains("统辖 2"),
			"报表行应含人数（直辖/统辖），实际：%s" % text)
	_runner.assert_true(text.contains("军事"), "报表行应含标签列，实际：%s" % text)
	_runner.assert_true(text.contains("组建中"), "报表行应含状态徽标，实际：%s" % text)
	_runner.assert_true(text.contains("50%"),
			"子树两成员士气 0.5 应聚合为 50%%，实际：%s" % text)
	_runner.assert_true(_overview._rows.has(platoon), "森林子行（L1）应生成")
	# 选中信号路径以外的选中态：面板自身高亮态字段
	_overview._selected_org = company
	_overview._apply_selection_visuals()
	_runner.assert_equal(row.outline_override, StickTokens.ACCENT, "选中行应着琥珀描边")
	_api.disband_organization(company)


## 上报流：report_filed → 时间线条目 + 报表行尾「最近上报」原地更新（不二次门控）。
func _test_overview_timeline() -> void:
	var n0: int = _overview._report_cache.size()
	var r: Dictionary = _api.create_organization("总览排乙", "MILITARY", 1, "")
	var org_id := String(r.data.org_id)
	_overview.open()
	_api.file_report(org_id, {"type": "casualty_threshold",
			"payload": {"alive": 2, "dead": 6, "total": 8, "loss_rate": 0.75}})
	_runner.assert_equal(_overview._report_cache.size(), n0 + 1, "应新增一条时间线条目")
	if _overview._report_cache.is_empty():
		return
	var top: Dictionary = _overview._report_cache[0]
	_runner.assert_equal(String(top.get("kind", "")), "伤亡", "分组名应为伤亡")
	_runner.assert_true(String(top.get("text", "")).contains("剩 2/8"),
			"文案应含存活/总数，实际：%s" % String(top.get("text", "")))
	var row: Control = _overview._rows.get(org_id, null)
	_runner.assert_not_null(row, "该组织报表行应存在")
	if row != null:
		_runner.assert_true(_row_text(row).contains("最近 伤亡"),
				"行尾最近上报应原地更新，实际：%s" % _row_text(row))
	_api.disband_organization(org_id)


## commander_assigned → 时间线「任命」分组（指挥变更留痕）。
func _test_overview_assign() -> void:
	var n0: int = _overview._report_cache.size()
	EventBus.commander_assigned.emit("assign_probe_org", 9001)
	_runner.assert_equal(_overview._report_cache.size(), n0 + 1, "任命事件应新增一条时间线条目")
	if _overview._report_cache.is_empty():
		return
	var top: Dictionary = _overview._report_cache[0]
	_runner.assert_equal(String(top.get("kind", "")), "任命", "分组名应为任命")
	_runner.assert_true(String(top.get("text", "")).contains("▲#9001"),
			"文案应含受任者 id，实际：%s" % String(top.get("text", "")))


## 标签过滤复用 OrgPanel 语义：非匹配组织不生成行。
func _test_overview_tag_filter() -> void:
	var r: Dictionary = _api.create_organization("过滤连", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_overview.open()
	_overview._on_tab_selected(1)  # 军事
	_runner.assert_true(_overview._rows.has(org_id), "军事标签下军事组织应显示")
	_overview._on_tab_selected(2)  # 科研
	_runner.assert_false(_overview._rows.has(org_id), "科研标签下军事组织不应生成行")
	_runner.assert_true(_overview._rows.is_empty(), "科研过滤下不应有匹配行（实际 %d）" % _overview._rows.size())
	_overview._on_tab_selected(0)  # 全部
	_runner.assert_true(_overview._rows.has(org_id), "切回全部后军事组织应重新显示")
	_api.disband_organization(org_id)


## 选中行：仅本面板高亮（不新造跨面板状态同步）。
func _test_overview_select_row() -> void:
	var r: Dictionary = _api.create_organization("选中连", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_overview.open()
	var row: Control = _overview._rows.get(org_id, null)
	_runner.assert_not_null(row, "选中连报表行应生成")
	if row == null:
		return
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	row.gui_input.emit(ev)
	_runner.assert_equal(_overview._selected_org, org_id, "点行应记为选中组织")
	_runner.assert_equal(row.outline_override, StickTokens.ACCENT, "选中行应着琥珀描边")
	_api.disband_organization(org_id)


## 行控件内全部 Label 文案拼接（报表列断言口径）
func _row_text(row: Control) -> String:
	var texts: Array = []
	_collect_labels(row, texts)
	return " ".join(texts)


# ─────────────────── UI-W4b：战略总览 · 跨组织调人（拖拽） ───────────────────

## 拖拽成功路径：托盘芯片起拖 → 目标行投放 → api 迁移 + info 通知 + 报表刷新。
## UI 只产载荷、只呈现结果，不做层级可行性预判（归 api，方案 §五.6）。
func _test_overview_transfer_drag_ok() -> void:
	var r: Dictionary = _api.create_organization("调人源排", "MILITARY", 1, "")
	var src := String(r.data.org_id)
	var r2: Dictionary = _api.create_organization("调人目标排", "MILITARY", 1, "")
	var dst := String(r2.data.org_id)
	_api.assign_stickman(src, "8801", "fighter")
	_overview.open()
	# 选中源行 → 托盘列出成员芯片
	var src_row: Control = _overview._rows.get(src, null)
	_runner.assert_not_null(src_row, "源组织报表行应生成")
	if src_row == null:
		return
	_click_row(src_row)
	_runner.assert_equal(_overview._selected_org, src, "点行后应选中源组织")
	var chip := _find_tray_chip("8801")
	_runner.assert_not_null(chip, "成员托盘应列出成员 8801")
	if chip == null:
		return
	# 起拖：产调人载荷（不预判合法性）
	var payload: Variant = chip.call("_get_drag_data", Vector2.ZERO)
	_runner.assert_true(payload is Dictionary \
			and String((payload as Dictionary).get("kind", "")) == "stickman_transfer",
			"拖拽载荷应为调人协议，实际：%s" % str(payload))
	_runner.assert_true(String(_overview._tray_hint.text).contains("调动中"),
			"拖拽中托盘应提示调动，实际：%s" % _overview._tray_hint.text)
	var dst_row: Control = _overview._rows.get(dst, null)
	_runner.assert_not_null(dst_row, "目标组织报表行应生成")
	if dst_row == null:
		return
	_runner.assert_true(bool(dst_row.call("_can_drop_data", Vector2.ZERO, payload)),
			"目标行应接受调人载荷（类型对即可，合法性归 api）")
	var notes := _capture_notifications()
	dst_row.call("_drop_data", Vector2.ZERO, payload)
	_runner.assert_equal(_api.get_organization(src).data.personnel, [], "源成员表应清空")
	_runner.assert_equal(_api.get_organization(dst).data.personnel, ["8801"], "目标成员表应加入 8801")
	_runner.assert_true(notes.size() >= 1 and String(notes[-1].level) == "info",
			"成功应发 info 通知，实际：%s" % str(notes))
	_runner.assert_true(String(_overview._tray_hint.text).contains("→"),
			"投放后拖拽态应复位，实际：%s" % _overview._tray_hint.text)
	_stop_notifications()
	_api.disband_organization(src)
	_api.disband_organization(dst)


## 拖拽失败路径：投到源组织自身（api 拒绝）→ warn 通知且两组织状态逐位不变。
func _test_overview_transfer_drag_fail() -> void:
	var r: Dictionary = _api.create_organization("失败源排", "MILITARY", 1, "")
	var src := String(r.data.org_id)
	_api.assign_stickman(src, "8901", "fighter")
	_overview.open()
	var src_row: Control = _overview._rows.get(src, null)
	_runner.assert_not_null(src_row, "源组织报表行应生成")
	if src_row == null:
		return
	_click_row(src_row)
	var chip := _find_tray_chip("8901")
	_runner.assert_not_null(chip, "成员托盘应列出成员 8901")
	if chip == null:
		return
	var payload: Variant = chip.call("_get_drag_data", Vector2.ZERO)
	# UI 不做第二套判断：同一行也接受载荷，由 api 判否（源=目标）
	_runner.assert_true(bool(src_row.call("_can_drop_data", Vector2.ZERO, payload)),
			"UI 不预判归属，载荷类型对即接受投放")
	var notes := _capture_notifications()
	src_row.call("_drop_data", Vector2.ZERO, payload)
	_runner.assert_equal(_api.get_organization(src).data.personnel, ["8901"], "失败后源成员表逐位不变")
	_runner.assert_true(notes.size() >= 1 and String(notes[-1].level) == "warn",
			"失败应发 warn 通知，实际：%s" % str(notes))
	_runner.assert_true(String(notes[-1].body).contains("调动失败"),
			"失败通知文案应说明失败，实际：%s" % String(notes[-1].body))
	_stop_notifications()
	_api.disband_organization(src)


## 驱动报表行点击（选中路径）
func _click_row(row: Control) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	row.gui_input.emit(ev)


## 成员托盘内按 stickman_id 查找芯片（duck 探测，不耦合内联类名）
func _find_tray_chip(stickman_id: String) -> Control:
	if _overview._tray_box == null:
		return null
	for c in _overview._tray_box.get_children():
		if c.get("stickman_id") != null and String(c.get("stickman_id")) == stickman_id:
			return c
	return null


func _capture_notifications() -> Array:
	_notes.clear()
	if EventBus != null and EventBus.has_signal("ui_notification") \
			and not EventBus.ui_notification.is_connected(_on_test_notification):
		EventBus.ui_notification.connect(_on_test_notification)
	return _notes


func _on_test_notification(title: String, body: String, level: String) -> void:
	_notes.append({"title": title, "body": body, "level": level})


func _stop_notifications() -> void:
	if EventBus != null and EventBus.has_signal("ui_notification") \
			and EventBus.ui_notification.is_connected(_on_test_notification):
		EventBus.ui_notification.disconnect(_on_test_notification)
	_notes.clear()
