extends Node
## 集成测试：统一模态栈（UIModalStack）——ESC 逐层退栈 / 层键单例 / 输入屏蔽随栈。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_modal_stack.tscn -- --fresh-start
##
## 覆盖（docs/技术/UI/UI系统重构参考.md §2.2 缺口 2）：
##   - ESC 空栈 → 开暂停菜单并暂停；再 ESC → 关闭并恢复（输入屏蔽随栈统一）
##   - 设置压过暂停菜单（栈盖住防双重遮罩）→ ESC 逐层退栈恢复（原"让位隐藏"语义）
##   - 帝国空面板同类单例：同预设提到栈顶、换预设替换不叠加
##   - 确认框入 CONFIRM 层：ESC = 取消（不触发 on_confirm），恢复下层
##   - 存档面板经栈开合（toggle 语义不变）
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

var _runner: TestRunner
var _helper: CombatTestSetup


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("模态栈: ESC 空栈开暂停菜单并暂停/恢复", _test_escape_pause_menu, true)
	_runner.add_test("模态栈: 设置压过暂停菜单，ESC 逐层退栈", _test_settings_over_pause, true)
	_runner.add_test("模态栈: 占位面板同类单例（提到栈顶/替换）", _test_placeholder_singleton, true)
	_runner.add_test("模态栈: 确认框 ESC = 取消", _test_confirm_escape_cancel, true)
	_runner.add_test("模态栈: 存档面板经栈开合", _test_save_panel_stack, true)
	_runner.add_test("模态栈: StickScreen 自带暂停与栈暂停不互相抢恢复", _test_dual_pause_ownership, true)
	_run_tests_async()


func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	await _runner.run_async()

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	# 套件 fixture 收尾：显式释放 GameRoot（内含地图/系统节点），
	# 避免进程退出时地图侧节点成为 ObjectDB 孤儿残留
	if _helper != null and is_instance_valid(_helper.game_root):
		_helper.game_root.free()
		_helper.game_root = null
	TestRunner.finish_process(self, exit_code)


## 数 ModalOverlay 下的占位面板实例数（同类单例断言用）
func _overlay_placeholder_count(gr: Node) -> int:
	var n: int = 0
	var overlay: Control = gr.ui_root.get_slot("ModalOverlay") if gr.ui_root != null else null
	if overlay != null:
		for child in overlay.get_children():
			if child.name.begins_with("UIPlaceholder_"):
				n += 1
	return n


## ESC 空栈 → 开暂停菜单并暂停；再 ESC → 关闭并恢复
func _test_escape_pause_menu() -> void:
	var gr := _helper.game_root
	var pm: Control = gr.get_pause_menu_panel() if gr.has_method("get_pause_menu_panel") else null
	_runner.assert_not_null(pm, "暂停菜单应已装配")
	if pm == null:
		return
	# 初始：无模态
	_runner.assert_false(pm.visible, "启动时暂停菜单应隐藏")
	_runner.assert_false(TimeManager.is_paused(), "启动时应未暂停")
	# ESC → 开暂停菜单 + 暂停（输入屏蔽随栈统一）
	gr._handle_escape()
	_runner.assert_true(pm.visible, "ESC 后暂停菜单应显示")
	_runner.assert_true(TimeManager.is_paused(), "模态打开应暂停（输入屏蔽随栈统一）")
	# 再 ESC → 关闭 + 恢复
	gr._handle_escape()
	_runner.assert_false(pm.visible, "再 ESC 应关闭暂停菜单")
	_runner.assert_false(TimeManager.is_paused(), "栈空应恢复原速度")


## 设置压过暂停菜单：暂停菜单被栈盖住（不可见但仍在栈）；ESC 逐层退栈恢复
func _test_settings_over_pause() -> void:
	var gr := _helper.game_root
	var pm: Control = gr.get_pause_menu_panel() if gr.has_method("get_pause_menu_panel") else null
	var sp: Control = gr.get_settings_menu_panel() if gr.has_method("get_settings_menu_panel") else null
	_runner.assert_not_null(sp, "设置面板应已装配")
	if pm == null or sp == null:
		return
	# 开暂停菜单 → 开设置（压栈）
	gr._handle_escape()
	_runner.assert_true(pm.visible, "暂停菜单应显示")
	gr.toggle_settings_menu()
	_runner.assert_true(sp.visible, "设置应显示（栈顶）")
	_runner.assert_false(pm.visible, "暂停菜单应被栈盖住（防双重遮罩）")
	_runner.assert_true(TimeManager.is_paused(), "压栈应保持暂停")
	# ESC 关设置 → 恢复暂停菜单（原"让位隐藏"语义）
	gr._handle_escape()
	_runner.assert_false(sp.visible, "ESC 应关闭设置")
	_runner.assert_true(pm.visible, "ESC 后应恢复暂停菜单")
	_runner.assert_true(TimeManager.is_paused(), "暂停菜单仍在栈 → 保持暂停")
	# 关暂停菜单 → 恢复
	gr._handle_escape()
	_runner.assert_false(pm.visible, "ESC 应关闭暂停菜单")
	_runner.assert_false(TimeManager.is_paused(), "栈空应恢复")


## 占位面板同类单例：同预设重复触发提到栈顶（不叠加）；换预设替换；ESC 逐层退栈
func _test_placeholder_singleton() -> void:
	var gr := _helper.game_root
	var pm: Control = gr.get_pause_menu_panel() if gr.has_method("get_pause_menu_panel") else null
	var stack: Node = gr.ui_root.get_modal_stack()
	_runner.assert_not_null(stack, "模态栈应已装配")
	if pm == null or stack == null:
		return
	gr._handle_escape()  # 开暂停菜单作底
	# 打开两次同预设 → 提到栈顶（同一实例，不叠加）
	gr._open_placeholder_panel("tech_tree")
	var first_ok: bool = await TestHelpers.await_condition(
			func() -> bool: return stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL) != null,
			2.0, "首次打开占位面板入栈")
	_runner.assert_true(first_ok, "首次打开应有占位面板")
	var first: Control = stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL)
	gr._open_placeholder_panel("tech_tree")
	var raised: bool = await TestHelpers.await_condition(
			func() -> bool: return stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL) == first,
			2.0, "重复触发提到栈顶")
	_runner.assert_true(raised, "重复触发应提到栈顶（同一实例）")
	# 换预设 → 替换（同类单例，不叠加）。就绪谓词含"旧实例已离场"：替换走
	# queue_free 退役旧面板，只等新条目就位会撞上延迟删除窗口数出 2 个实例
	gr._open_placeholder_panel("empire_overview")
	var replaced: bool = await TestHelpers.await_condition(
			func() -> bool:
				var cur: Control = stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL)
				return cur != null and cur != first and _overlay_placeholder_count(gr) == 1,
			2.0, "换预设替换旧实例")
	_runner.assert_true(replaced, "换预设应替换旧实例")
	var second: Control = stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL)
	var second_preset: Dictionary = second.get("_preset") if second != null and second.get("_preset") is Dictionary else {}
	_runner.assert_equal(second_preset.get("id", ""), "empire_overview", "新实例应为总览报表预设")
	_runner.assert_equal(_overlay_placeholder_count(gr), 1, "同类单例：ModalOverlay 只应有 1 个占位面板实例")
	# ESC → 逐层退栈：占位面板 → 暂停菜单 → 空
	gr._handle_escape()
	var ph_closed: bool = await TestHelpers.await_condition(
			func() -> bool: return not stack.is_open(UIModalStack.Layer.EMPIRE_PANEL),
			2.0, "ESC 关占位面板")
	_runner.assert_true(ph_closed, "ESC 应关占位面板")
	_runner.assert_true(pm.visible, "ESC 后应恢复暂停菜单")
	gr._handle_escape()
	var pm_closed: bool = await TestHelpers.await_condition(
			func() -> bool: return not pm.visible, 2.0, "ESC 关暂停菜单")
	_runner.assert_true(pm_closed, "再 ESC 应关暂停菜单")


## 确认框入 CONFIRM 层：ESC = 取消（不触发 on_confirm），恢复下层
func _test_confirm_escape_cancel() -> void:
	var gr := _helper.game_root
	var pm: Control = gr.get_pause_menu_panel() if gr.has_method("get_pause_menu_panel") else null
	var stack: Node = gr.ui_root.get_modal_stack()
	_runner.assert_not_null(stack, "模态栈应已装配")
	if pm == null or stack == null:
		return
	var confirmed: Array = [false]
	gr._handle_escape()  # 开暂停菜单作底
	# 从暂停菜单开确认框（系统层 CONFIRM，盖住暂停菜单）
	StickKit.confirm(pm, "测试确认", "确认框 ESC 取消语义测试。", func(): confirmed[0] = true, "确定")
	_runner.assert_true(stack.is_open(UIModalStack.Layer.CONFIRM), "确认框应入 CONFIRM 层")
	_runner.assert_false(pm.visible, "确认框应盖住暂停菜单")
	# 遮罩应铺满视口（根 FULL_RECT，防 0 尺寸静默不可见回归）；
	# 布局在一帧后落地，等"栈顶 Control 尺寸就位"而非数帧
	var dialog_ready: bool = await TestHelpers.await_condition(
			func() -> bool:
				var top: Control = stack.top() as Control
				return top != null and top.size.x > 1000.0,
			2.0, "确认框遮罩铺满视口")
	_runner.assert_true(dialog_ready, "确认框根应铺满视口（遮罩可见）")
	var dialog_root: Control = stack.top() as Control  # 栈收 CanvasItem，此处取回 Control 断言遮罩尺寸
	_runner.assert_not_null(dialog_root, "确认框应为栈顶")
	# ESC → 取消（不触发 on_confirm）
	gr._handle_escape()
	var cancelled: bool = await TestHelpers.await_condition(
			func() -> bool: return not stack.is_open(UIModalStack.Layer.CONFIRM),
			2.0, "ESC 取消确认框")
	_runner.assert_true(cancelled, "ESC 应取消确认框")
	_runner.assert_false(confirmed[0], "ESC 取消不应触发 on_confirm")
	_runner.assert_true(pm.visible, "ESC 后应恢复暂停菜单")
	# 收尾
	gr._handle_escape()
	_runner.assert_false(pm.visible, "再 ESC 应关暂停菜单")


## 存档面板经栈开合（toggle 语义不变）
func _test_save_panel_stack() -> void:
	var gr := _helper.game_root
	var stack: Node = gr.ui_root.get_modal_stack()
	_runner.assert_not_null(stack, "模态栈应已装配")
	if stack == null:
		return
	gr.toggle_save_panel()
	var sp_open: bool = await TestHelpers.await_condition(
			func() -> bool: return stack.is_open(UIModalStack.Layer.SAVE_PANEL),
			2.0, "toggle 压存档面板入栈")
	_runner.assert_true(sp_open, "toggle 应压存档面板入栈")
	var sp: Control = stack.get_entry(UIModalStack.Layer.SAVE_PANEL)
	_runner.assert_not_null(sp, "存档面板应在栈中")
	_runner.assert_true(sp.visible, "存档面板应显示")
	_runner.assert_true(TimeManager.is_paused(), "存档面板打开应暂停（输入屏蔽随栈）")
	gr.toggle_save_panel()
	var sp_closed: bool = await TestHelpers.await_condition(
			func() -> bool: return not stack.is_open(UIModalStack.Layer.SAVE_PANEL),
			2.0, "toggle 退存档面板")
	_runner.assert_true(sp_closed, "再 toggle 应退栈")
	_runner.assert_false(TimeManager.is_paused(), "栈空应恢复")


## 双份暂停回归（2026-08-22）：StickScreen 自带 _prev_speed 暂停记录，
## 与 UIModalStack 的暂停随栈并存——约定"面板 open() 发现已暂停则不记录，
## 恢复只由最外层负责"。本用例钉死：面板关闭不得提前恢复速度。
func _test_dual_pause_ownership() -> void:
	var gr := _helper.game_root
	var sp: Control = gr.get_settings_menu_panel() if gr.has_method("get_settings_menu_panel") else null
	_runner.assert_not_null(sp, "设置面板应已装配（StickScreen 子类）")
	if sp == null:
		return
	# 1. 栈先暂停（经暂停菜单）
	gr._handle_escape()
	_runner.assert_true(TimeManager.is_paused(), "前置：栈应已暂停")
	var stack: Node = gr.ui_root.get_modal_stack()
	# 2. StickScreen.open() 发现已暂停 → 不记录自己的恢复责任
	gr.toggle_settings_menu()
	var sp_shown: bool = await TestHelpers.await_condition(
			func() -> bool: return sp.visible, 2.0, "设置面板显示")
	_runner.assert_true(sp_shown, "设置应显示")
	_runner.assert_true(TimeManager.is_paused(), "设置打开保持暂停")
	# 3. 面板自身 close()（toggle 关闭路径）→ 不得提前恢复
	sp.call("close")
	var sp_hidden: bool = await TestHelpers.await_condition(
			func() -> bool: return not sp.visible, 2.0, "设置面板关闭")
	_runner.assert_true(sp_hidden, "面板应关闭")
	_runner.assert_true(TimeManager.is_paused(),
			"关键回归：面板 close 不得抢在栈之前恢复速度（_prev_speed 应为 -1 跳过恢复）")
	# 4. 栈逐层退空 → 才由栈恢复
	gr._handle_escape()  # 关暂停菜单
	var resumed: bool = await TestHelpers.await_condition(
			func() -> bool: return not TimeManager.is_paused(), 2.0, "栈退空恢复速度")
	_runner.assert_true(resumed, "栈退空才恢复原速度")
