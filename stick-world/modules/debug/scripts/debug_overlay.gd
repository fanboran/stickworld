class_name DebugOverlay
extends CanvasLayer
## 调试覆盖层 -- F3 切换，可视化所有运行时不可见的标记。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.5。
## 职责：
##   - F3 切换调试模式（图例 + 绘制器）
##   - 启动时显示图例（常驻小字，半透明）
##   - _process 中 queue_redraw 绘制控件
##
## 子节点：
##   DebugDrawControl (Control)    ← 全屏绘制控件
##   LegendPanel (Panel)           ← 图例面板（带半透明背景）
##     └── LegendLabel (Label)     ← 图例文字

## 图例文本
const LEGEND_TEXT: String = """[F3] 调试
绿条=占地  红条=不可建  蓝区=地图障碍  紫区=建筑障碍
黄线=地面线  青线=地面底  白框=建筑  紫框=Chunk触发"""

## 绘制控件
var _draw_control: Control = null
## 图例面板（含半透明背景）
var _legend_panel: Panel = null
## 图例标签
var _legend_label: Label = null


func _ready() -> void:
	# 确保层级最高（高于游戏画面和 UI）
	layer = 100
	# 创建绘制控件
	_draw_control = Control.new()
	_draw_control.name = "DebugDrawControl"
	_draw_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_control.set_script(load("res://modules/debug/scripts/debug_draw_control.gd"))
	add_child(_draw_control)
	# 创建图例面板（带半透明深色背景，避开 GlobalHUD 顶部区域）
	_legend_panel = Panel.new()
	_legend_panel.name = "LegendPanel"
	_legend_panel.position = Vector2(12, 64)
	_legend_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 8.0
	sb.content_margin_bottom = 4.0
	_legend_panel.add_theme_stylebox_override("panel", sb)
	add_child(_legend_panel)
	# 图例文字
	_legend_label = Label.new()
	_legend_label.name = "LegendLabel"
	_legend_label.text = LEGEND_TEXT
	_legend_label.add_theme_font_size_override("font_size", 10)
	_legend_label.modulate = Color(1.0, 1.0, 1.0, 0.85)
	_legend_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend_panel.add_child(_legend_label)
	# 等待一帧后根据 Label 实际尺寸调整 Panel 大小
	call_deferred("_resize_legend_panel")
	# 连接 DebugApi 信号
	if DebugApi != null:
		DebugApi.visibility_changed.connect(_on_visibility_changed)
		DebugApi.legend_visibility_changed.connect(_on_legend_changed)
	# 应用初始状态
	_on_visibility_changed(DebugApi.is_visible() if DebugApi else false)
	_on_legend_changed(DebugApi.is_legend_visible() if DebugApi else false)


## 根据图例文字实际尺寸调整面板大小
func _resize_legend_panel() -> void:
	if _legend_label == null or _legend_panel == null:
		return
	var label_size: Vector2 = _legend_label.get_minimum_size()
	_legend_panel.size = label_size + Vector2(16, 8)


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
func _on_visibility_changed(is_visible: bool) -> void:
	if _draw_control != null:
		_draw_control.visible = is_visible
		if is_visible:
			_draw_control.queue_redraw()
	if _legend_panel != null:
		_legend_panel.visible = is_visible and DebugApi.is_legend_visible() if DebugApi else is_visible


## 图例可见性变化回调
func _on_legend_changed(is_visible: bool) -> void:
	if _legend_panel != null:
		_legend_panel.visible = is_visible and (DebugApi.is_visible() if DebugApi else false)
