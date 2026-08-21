class_name DebugOverlay
extends CanvasLayer
## 调试覆盖层 -- F3 切换，可视化所有运行时不可见的标记。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.5。
## 职责：
##   - F3 切换调试模式
##   - _process 中 queue_redraw 绘制控件
##   - 管理可拖动调试控制面板（DebugPanel）
##
## 子节点：
##   DebugDrawControl (Control)    ← 全屏绘制控件（覆盖画面）
##   DebugPanel (Control)          ← 可拖动调试控制面板（按钮 + 开关列表）

## 绘制控件
var _draw_control: Control = null
## 可拖动调试面板
var _debug_panel: Control = null
## 实体信息文本框
var _entity_info_panel: Control = null


func _ready() -> void:
	# 独立调试层（高于 UIRoot=1；战略图 100/101/102 全屏打开时被盖，合理）
	layer = LayerOrder.DEBUG_OVERLAY
	# 创建绘制控件
	_draw_control = Control.new()
	_draw_control.name = "DebugDrawControl"
	_draw_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_control.set_script(load("res://modules/debug_GUI/scripts/debug_draw_control.gd"))
	add_child(_draw_control)
	# 创建可拖动调试面板
	_debug_panel = Control.new()
	_debug_panel.name = "DebugPanel"
	_debug_panel.set_script(load("res://modules/debug_GUI/scripts/debug_panel.gd"))
	add_child(_debug_panel)
	# 创建实体信息文本框
	_entity_info_panel = Control.new()
	_entity_info_panel.name = "DebugInfoPanel"
	_entity_info_panel.set_script(load("res://modules/debug_GUI/scripts/debug_info_panel.gd"))
	add_child(_entity_info_panel)
	# 连接 DebugApi 信号
	if DebugApi != null:
		DebugApi.visibility_changed.connect(_on_visibility_changed)
	# 应用初始状态
	_on_visibility_changed(DebugApi.is_visible() if DebugApi else false)


func _process(_delta: float) -> void:
	# 调试模式开启时持续重绘
	if DebugApi != null and DebugApi.is_visible() and _draw_control != null:
		_draw_control.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	# F3 切换调试覆盖层
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if DebugApi != null:
			DebugApi.toggle_visibility()
		get_viewport().set_input_as_handled()


## 可见性变化回调
func _on_visibility_changed(p_visible: bool) -> void:
	if _draw_control != null:
		_draw_control.visible = p_visible
		if p_visible:
			_draw_control.queue_redraw()
