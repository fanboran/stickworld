extends Node
## 集成测试：L1 班组卡（W2 · docs/设计/UI/组织界面与AI状态接线-总体方案.md §3.2.A）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_squad_card.tscn -- --fresh-start
##
## 覆盖（卡片 = 框选触发 + 三问呈现 + 两条既有操作 API）：
##   - 装配：SquadCard 落在 UIRoot 的 ContextPanel/SquadInspector 槽，初始收起
##   - 槽存活：切一次 BATTLE 模式（clear_context）后槽与卡片仍在（owner 判定回归）
##   - 触发：框选小队即显示并绑定；清空选择即收起
##   - 内容：班名 / 成员行数 / 班长栏 / 操作按钮齐备；空数据态不报错
##   - 号令：EventBus.order_issued 驱动号令栏（玩家直令档）
##   - 相位：A5 相位计划 active 显示徽标，未启用即隐藏（信号驱动消费点）
##   - 操作：点行选中 → 任命班长落到编制侧；移出班组成员行减少
## 退出码：0 全过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")
const TacticalOrdersScript := preload("res://modules/combat/scripts/command/tactical_orders.gd")

## 测试单位数量（= 成员行期望数）
const UNIT_COUNT: int = 5
const SQUAD_NAME := "先锋班"
const ADVANCE_TARGET := Vector2(2400.0, 500.0)

var _runner: TestRunner
var _helper: CombatTestSetup
var _card: Control = null
var _squad_id: String = ""
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_run()


func _run() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_card = _helper.game_root.ui_root.get_node_or_null("ContextPanel/SquadInspector/SquadCard")
	for i in 2:
		await get_tree().process_frame
	_register_tests()
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── 用例注册 ────────────────────────────────

func _register_tests() -> void:
	# [用例名, 方法名, 是否异步]
	_tests = [
		["装配: SquadCard 落在 ContextPanel/SquadInspector 槽", "_test_mounted", false],
		["初始: 无选择即收起（不占布局、不显幽灵卡）", "_test_hidden_initially", false],
		["触发: 框选小队显示并绑定该编队", "_test_show_on_selection", true],
		["槽存活: 切 BATTLE 模式（clear_context）后卡片仍在", "_test_slot_survives_mode_switch", true],
		["内容: 班名/成员行/班长栏/操作按钮齐备", "_test_content_wired", false],
		["号令: order_issued 写入号令栏（玩家直令档）", "_test_order_line", true],
		["相位: 计划激活显示徽标；撤销后隐藏（GK-4 生产默认开）", "_test_phase_badge", true],
		["操作: 点行选中 → 任命班长落到编制侧", "_test_assign_leader", true],
		["操作: 移出班组后成员行减少", "_test_remove_member", true],
		["收起: 清空选择即隐藏", "_test_hide_on_clear", true],
	]
	for t in _tests:
		_runner.add_test(t[0], Callable(self, String(t[1])), bool(t[2]))


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_mounted() -> void:
	_runner.assert_not_null(_card, "SquadCard 应已由 SystemSetup 装配")
	if _card == null:
		return
	_runner.assert_equal(_card.get_parent().name, "SquadInspector", "父节点应为 SquadInspector 槽")
	_runner.assert_true(_card.get_parent().get_parent() is ContextPanel, "槽应挂在 ContextPanel 之下")


func _test_hidden_initially() -> void:
	if _card == null:
		return
	_runner.assert_false(_card.visible, "无选择时卡片应收起")
	_runner.assert_false(bool(_card.is_showing_squad()), "未绑定编队不应算显示")


func _test_show_on_selection() -> void:
	if _card == null:
		return
	_helper.spawn_test_units(UNIT_COUNT)
	await get_tree().process_frame
	_squad_id = String(_helper.formation.create_squad(_helper.units, SQUAD_NAME))
	_runner.assert_true(not _squad_id.is_empty(), "测试编队应创建成功")
	_helper.selection.select_units(_helper.units)
	for i in 3:
		await get_tree().process_frame
	_runner.assert_true(_card.visible, "框选小队后卡片应显示")
	_runner.assert_equal(_card.get_bound_squad(), _squad_id, "卡片应绑定被框选单位所在的编队")


## 回归：UIRoot.clear_context 不得把场景声明的槽一起释放（owner 判定）
func _test_slot_survives_mode_switch() -> void:
	if _card == null:
		return
	_helper.game_root.ui_root.apply_mode_panel(UIAPI.PanelType.BATTLE)
	for i in 2:
		await get_tree().process_frame
	_runner.assert_true(is_instance_valid(_card), "切 BATTLE 模式后卡片不应被释放")
	_runner.assert_true(_card.get_parent() != null, "槽位结构应保留")


func _test_content_wired() -> void:
	if _card == null:
		return
	_runner.assert_equal(_card.get_node("Body/Header/SquadName").text, SQUAD_NAME, "头部应显示班名")
	_runner.assert_equal(_card.get_node("Body/Members").get_child_count(), UNIT_COUNT, "成员行数应等于编队人数")
	_runner.assert_true(
			not String(_card.get_node("Body/Commander/Leader").text).is_empty(),
			"班长栏应有内容（指挥官或空缺态）")
	_runner.assert_true(
			_card.get_node("Body/Actions/ActionsA").get_child_count() >= 2,
			"操作按钮应有任命班长 / 移出班组两枚")
	_runner.assert_true(
			_card.get_node("Body/Actions/ActionsB").get_child(0).disabled,
			"指挥链入口本批应为禁用占位")


func _test_order_line() -> void:
	if _card == null or _squad_id.is_empty():
		return
	var ok: bool = bool(_helper.tactical.issue(TacticalOrdersScript.OrderType.ADVANCE_ALL,
			_squad_id, ADVANCE_TARGET))
	_runner.assert_true(ok, "前进号令应下发成功")
	for i in 2:
		await get_tree().process_frame
	var txt := String(_card.get_node("Body/OrderRow/Order").text)
	_runner.assert_true(txt.contains("前进"), "号令栏应显示中文号令名（实测 %s）" % txt)
	_runner.assert_true(txt.contains("玩家"), "玩家直令档应标注来源（实测 %s）" % txt)


func _test_phase_badge() -> void:
	if _card == null or _squad_id.is_empty():
		return
	var phase_label: Label = _card.get_node("Body/Phase")
	# GK-4 开闸依据：.tres 生效默认已开，推进号令即激活计划——原"默认未启用即隐藏"
	# 前提不再成立。改为在开态下走「激活→撤销」两态：先验徽标显示，再用
	# HOLD 非推进号令撤销计划验隐藏（两态断言均保留，不依赖默认值）。
	_helper.formation.set_phase_plan_params({"phase_plan_enabled": true})
	_helper.tactical.issue(TacticalOrdersScript.OrderType.ADVANCE_ALL, _squad_id, ADVANCE_TARGET)
	for i in 3:
		await get_tree().process_frame
	_runner.assert_true(phase_label.visible, "计划激活后应显示相位徽标")
	_runner.assert_true(
			String(phase_label.text).contains("跃进中"),
			"徽标应为相位直译文案（实测 %s）" % String(phase_label.text))
	_helper.tactical.issue(TacticalOrdersScript.OrderType.HOLD_POSITION, _squad_id, Vector2.ZERO)
	for i in 2:
		await get_tree().process_frame
	_runner.assert_false(phase_label.visible, "计划撤销后不应显示相位徽标")


func _test_assign_leader() -> void:
	if _card == null or _squad_id.is_empty():
		return
	var members: VBoxContainer = _card.get_node("Body/Members")
	var row: Node = members.get_child(0)
	row.pressed.emit()
	await get_tree().process_frame
	var assign_btn: Button = _card.get_node("Body/Actions/ActionsA").get_child(0)
	_runner.assert_false(assign_btn.disabled, "选中成员后任命班长应可用")
	assign_btn.pressed.emit()
	for i in 2:
		await get_tree().process_frame
	var leader: Node = _helper.formation.get_squad_leader(_squad_id)
	_runner.assert_not_null(leader, "任命应落到编制侧班长位")
	_runner.assert_true(
			not String(_card.get_node("Body/Commander/Leader").text).contains("空缺"),
			"班长栏应显示已任命班长")
	_runner.assert_true(
			String(_card.get_node("Body/Commander/Authority").text).contains("威望"),
			"权威值应呈现为威望数值")


func _test_remove_member() -> void:
	if _card == null or _squad_id.is_empty():
		return
	var remove_btn: Button = _card.get_node("Body/Actions/ActionsA").get_child(1)
	_runner.assert_false(remove_btn.disabled, "有选中成员时移出班组应可用")
	remove_btn.pressed.emit()
	for i in 2:
		await get_tree().process_frame
	_runner.assert_equal(_helper.formation.get_squad_size(_squad_id), UNIT_COUNT - 1,
			"编制侧人数应减一")
	_runner.assert_equal(_card.get_node("Body/Members").get_child_count(), UNIT_COUNT - 1,
			"成员行应随之减少")


func _test_hide_on_clear() -> void:
	if _card == null:
		return
	_helper.selection.clear_selection()
	for i in 3:
		await get_tree().process_frame
	_runner.assert_false(_card.visible, "清空选择后卡片应收起")
	_runner.assert_equal(_card.get_bound_squad(), "", "收起后不应残留绑定")
