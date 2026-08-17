class_name StickWindow
extends Control
## 非模态浮动窗口基类 —— 4 种弹窗行为模板之一（FLOATING / DOCK / POPOVER）。
##
## 与 StickScreen（排他模态）相对：**本类不画全屏遮罩**、不挡游戏、可与其他页面元素交互。
## 行为（PanelBehavior 见 05-弹窗与模态.md §五）：
##   FLOATING  可拖动标题栏、位置自由（编制管理、工具窗）
##   DOCK      固定停靠屏幕角落（建造菜单）
##   POPOVER   跟随锚点弹出、点击面板外自动关闭（下拉/选择器/提示）
##
## 子类：设 window_size / window_title / behavior → _build_window() → _build_content() 填内容。
## ESC 关闭自身（handled，不触发 GameRoot 暂停菜单）。

enum Behavior { FLOATING, DOCK, POPOVER }

# ─────────────────────────────── 参数 ────────────────────────────────
@export var window_size := Vector2(640, 480)
@export var window_title := ""
@export var behavior := Behavior.FLOATING
## POPOVER 锚点（屏幕坐标）
@export var anchor_pos := Vector2(200, 200)

# ─────────────────────────────── 内部节点 ────────────────────────────────
var _panel: PanelContainer = null
## 内容区（子类往这里加控件）
var _body: VBoxContainer = null

var _dragging := false
var _drag_offset := Vector2.ZERO


func _ready() -> void:
	visible = false


## 构建窗口骨架（无遮罩、可交互、FLOATING 可拖动标题栏）
func _build_window() -> void:
	# 根不拦截鼠标 → 面板外事件穿透到游戏（可交互）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", StickStyle.window_panel())
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.custom_minimum_size = window_size
	add_child(_panel)
	_position_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_panel.add_child(vbox)
	# 标题栏（拖动把手 + 关闭）
	var title_bar := HBoxContainer.new()
	title_bar.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(title_bar)
	var title := Label.new()
	title.text = window_title
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_bar.add_child(title)
	if behavior == Behavior.FLOATING:
		title_bar.gui_input.connect(_on_title_input)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(30, 30)
	close_btn.pressed.connect(close)
	title_bar.add_child(close_btn)
	# 内容区
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_body)
	_build_content()


## 子类实现：往 _body 添加内容
func _build_content() -> void:
	pass


## 初始定位（FLOATING 居中；DOCK 停靠；POPOVER 锚点）
func _position_panel() -> void:
	var vp := get_viewport().get_visible_rect() if get_viewport() != null else Rect2(0, 0, 1920, 1080)
	match behavior:
		Behavior.DOCK:
			StickKit.dock(_panel, StickKit.Corner.TOP_RIGHT, window_size)
		Behavior.POPOVER:
			_panel.position = anchor_pos
		_:
			_panel.position = vp.size * 0.5 - window_size * 0.5


# ─────────────────────────────── 拖动（FLOATING）────────────────────────────────

func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_offset = get_viewport().get_mouse_position() - _panel.position
		else:
			_dragging = false
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_panel.position = get_viewport().get_mouse_position() - _drag_offset
		get_viewport().set_input_as_handled()


# ─────────────────────────────── 开关 ────────────────────────────────

func open() -> void:
	visible = true


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func is_open() -> bool:
	return visible


## ESC 关闭自身；POPOVER 点击面板外关闭。均消费（不触发 GameRoot 暂停菜单）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
		return
	if behavior == Behavior.POPOVER and event is InputEventMouseButton and event.pressed:
		if not _panel.get_global_rect().has_point(get_viewport().get_mouse_position()):
			close()
