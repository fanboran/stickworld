extends Node
## 集成测试：ESC 经**真实输入链路**（Viewport.push_input → GUI/_input/_unhandled_input → GameRoot）
## 打开/关闭暂停菜单。\n##
## 回归背景：StickWindow（编制窗口常驻挂 ModalOverlay、初始隐藏）的 _unhandled_input 曾无条件消费
## ESC（未检查 visible），子节点先于根节点收事件 → GameRoot 永远收不到 ESC → 暂停菜单打不开。
## 本测试直接注入按键事件，走完整管线（不是直调 _handle_escape）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_esc_key_input.tscn -- --fresh-start

const TestRunner := preload("res://tests/core/test_runner.gd")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")

var _runner: TestRunner
var _game_root: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("ESC 真实按键链路：开暂停菜单/占位压栈/ESC 逐层退栈", _test_esc_key_chain, true)
	_run_tests_async()


func _run_tests_async() -> void:
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	# 等地图加载 + 系统装配（模式切到 EXPLORE）：条件等待替代数帧（README 硬规矩）。
	# 就绪判据 = _boot_world_phase 翻 false（地图就绪、载入覆盖淡出——载入屏是强
	# 模态会吞输入，boot 未完 push_input 会被吞）且暂停菜单面板已装配；
	# 超时由用例首部 assert_not_null(pm/stack) 与本处 boot_ready 断言兜红
	var boot_ready: bool = await TestHelpers.await_condition(
			func() -> bool: return _game_root.get("_boot_world_phase") == false and _game_root.get_pause_menu_panel() != null,
			10.0, "GameRoot boot 完成（载入屏淡出+暂停菜单装配）")
	_runner.assert_true(boot_ready, "GameRoot 应在 10s 内 boot 完成（载入屏淡出+暂停菜单装配）")
	await _runner.run_async()

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	TestRunner.finish_process(self, exit_code)


## 向根 Viewport 注入真实按键（走 GUI → _input → _unhandled_input 完整管线）。
## keycode 与 physical_keycode 双填（OS 真实输入两字段都有；玩法键是
## InputBindings 的 physical 绑定，只填 keycode 不命中 is_action）。
func _send_key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	get_viewport().push_input(ev)


func _test_esc_key_chain() -> void:
	var gr: Node = _game_root
	var pm: Control = gr.get_pause_menu_panel() if gr.has_method("get_pause_menu_panel") else null
	var stack: Node = gr.get("ui_root").get_modal_stack() if gr.get("ui_root") != null else null
	_runner.assert_not_null(pm, "暂停菜单应已装配")
	_runner.assert_not_null(stack, "模态栈应已装配")
	if pm == null or stack == null:
		return
	# 初始干净
	_runner.assert_false(pm.visible, "启动时暂停菜单应隐藏")
	# ESC → 开暂停菜单（真实输入链路）：按键→状态跨帧传播，条件等待可达状态
	_send_key(KEY_ESCAPE)
	var opened: bool = await TestHelpers.await_condition(
			func() -> bool: return pm.visible, 2.0, "ESC 打开暂停菜单")
	_runner.assert_true(opened, "ESC 应经输入链路打开暂停菜单")
	_runner.assert_true(TimeManager.is_paused(), "暂停菜单打开应暂停")
	# K → 占位面板压栈（盖住暂停菜单，同类单例不叠加）
	var overlay: Control = gr.get("ui_root").get_slot("ModalOverlay") if gr.get("ui_root") != null else null
	_runner.assert_not_null(overlay, "ModalOverlay 槽位应已装配")
	_send_key(KEY_K)
	var ph_opened: bool = await TestHelpers.await_condition(
			func() -> bool: return _count_placeholders(overlay) >= 1, 2.0, "K 打开占位面板")
	_runner.assert_true(ph_opened, "K 应经输入链路打开占位面板")
	_runner.assert_equal(_count_placeholders(overlay), 1, "占位面板同类单例（恰 1 个）")
	_runner.assert_false(pm.visible, "占位面板压栈应盖住暂停菜单")
	# ESC → 关占位面板并揭示暂停菜单（逐层退栈）
	_send_key(KEY_ESCAPE)
	var restored: bool = await TestHelpers.await_condition(
			func() -> bool: return pm.visible and _count_placeholders(overlay) == 0,
			2.0, "ESC 退占位面板揭示暂停菜单")
	_runner.assert_true(restored, "ESC 应关闭占位面板并揭示暂停菜单")
	_runner.assert_equal(_count_placeholders(overlay), 0, "占位面板应已关闭")
	# ESC → 关暂停菜单恢复
	_send_key(KEY_ESCAPE)
	var closed: bool = await TestHelpers.await_condition(
			func() -> bool: return not pm.visible, 2.0, "ESC 关闭暂停菜单")
	_runner.assert_true(closed, "再 ESC 应关闭暂停菜单")
	_runner.assert_false(TimeManager.is_paused(), "栈空应恢复")


## 数 ModalOverlay 下的占位面板实例数（同类单例断言用）
func _count_placeholders(overlay: Control) -> int:
	var n: int = 0
	if overlay != null:
		for child in overlay.get_children():
			if child.name.begins_with("UIPlaceholder_"):
				n += 1
	return n
