extends Control
## 可拖动调试控制面板
##
## - 收起：小按钮（可拖动），点击展开
## - 展开：列出所有绘制器开关 CheckBox，面板可拖动
## - 位置和开关状态通过 DebugApi 持久化到 user://debug_settings.cfg
##
## 由 DebugOverlay 创建并管理。

var _toggle_button: Button = null
var _content_panel: Panel = null
var _vbox: VBoxContainer = null
var _dragging: Control = null
var _drag_offset: Vector2 = Vector2.ZERO
## 按下时鼠标位置（用于区分点击 vs 拖动）
var _press_pos: Vector2 = Vector2.ZERO
var _is_dragging: bool = false
const DRAG_THRESHOLD: float = 5.0

## 绘制器中文名映射
const DRAWER_NAMES_ZH: Dictionary = {
	"grid_drawer": "网格占地",
	"barrier_drawer": "通行障碍",
	"building_drawer": "建筑边框",
	"ground_line_drawer": "地面线",
	"chunk_trigger_drawer": "Chunk触发器",
	"entity_state_drawer": "实体状态",
	"entity_collider_drawer": "实体碰撞箱",
	"terrain_grid": "垂直地形网格",
	"resource_nodes": "资源点",
	"building_names": "建筑名称",
	"world_ruler": "世界坐标标尺",
	"entity_info": "实体信息框",
}


func _ready() -> void:
	_build_ui()
	if DebugApi:
		_toggle_button.position = DebugApi.get_button_position()
		_content_panel.position = DebugApi.get_panel_position()
		_content_panel.visible = DebugApi.is_panel_expanded()
		_update_toggle_text()
		DebugApi.visibility_changed.connect(_on_visibility_changed)
	visible = (DebugApi.is_visible() if DebugApi else true)


var _last_drawer_count: int = -1


func _process(_delta: float) -> void:
	# 检测绘制器数量变化（GameRoot._register_debug_drawers 在 DebugPanel._ready 之后执行）
	if DebugApi:
		var count: int = DebugApi.get_drawers().size()
		if count != _last_drawer_count:
			_last_drawer_count = count
			if _content_panel.visible:
				_refresh_drawer_list()


func _build_ui() -> void:
	# 收起按钮（可拖动）
	_toggle_button = Button.new()
	_toggle_button.text = "调试"
	_toggle_button.custom_minimum_size = Vector2(64, 28)
	_toggle_button.add_theme_font_size_override("font_size", 12)
	_toggle_button.pressed.connect(_on_button_pressed)
	_toggle_button.gui_input.connect(_on_drag_input.bind(_toggle_button, "button"))
	add_child(_toggle_button)
	# 展开面板（可拖动）
	_content_panel = Panel.new()
	_content_panel.custom_minimum_size = Vector2(240, 360)
	_content_panel.visible = false
	_content_panel.gui_input.connect(_on_drag_input.bind(_content_panel, "panel"))
	# 半透明背景
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_bottom = 4.0
	_content_panel.add_theme_stylebox_override("panel", sb)
	add_child(_content_panel)
	# 标题栏
	var title := Label.new()
	title.text = "  调试覆盖层"
	title.position = Vector2(8, 5)
	title.add_theme_font_size_override("font_size", 13)
	_content_panel.add_child(title)
	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "×"
	close_btn.position = Vector2(214, 2)
	close_btn.size = Vector2(22, 22)
	close_btn.flat = true
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.pressed.connect(_collapse)
	_content_panel.add_child(close_btn)
	# 分隔线
	var sep := HSeparator.new()
	sep.position = Vector2(4, 28)
	sep.size = Vector2(232, 2)
	_content_panel.add_child(sep)
	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(4, 32)
	scroll.size = Vector2(232, 320)
	_content_panel.add_child(scroll)
	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_vbox)
	_refresh_drawer_list()


func _refresh_drawer_list() -> void:
	if _vbox == null or DebugApi == null:
		return
	for child in _vbox.get_children():
		child.queue_free()
	# 绘制器开关
	var drawers_label := Label.new()
	drawers_label.text = "覆盖层"
	drawers_label.add_theme_font_size_override("font_size", 11)
	drawers_label.modulate = Color(0.7, 0.7, 0.7)
	_vbox.add_child(drawers_label)
	var drawer_names: Dictionary = DebugApi.get_drawers()
	for drawer_name in drawer_names.keys():
		var check := CheckBox.new()
		var zh: String = DRAWER_NAMES_ZH.get(drawer_name, drawer_name)
		check.text = "%s (%s)" % [zh, drawer_name]
		check.button_pressed = DebugApi.is_drawer_enabled(drawer_name)
		check.add_theme_font_size_override("font_size", 11)
		check.toggled.connect(_on_drawer_toggled.bind(drawer_name))
		_vbox.add_child(check)
	# 独立工具区（不随 F3 总开关隐藏）
	var tools_label := Label.new()
	tools_label.text = "独立工具"
	tools_label.add_theme_font_size_override("font_size", 11)
	tools_label.modulate = Color(0.7, 0.7, 0.7)
	_vbox.add_child(tools_label)
	var tools_check := CheckBox.new()
	tools_check.text = "调试工具面板（特效/市场/环境/建筑）"
	tools_check.button_pressed = DebugApi.is_tools_visible()
	tools_check.add_theme_font_size_override("font_size", 11)
	tools_check.toggled.connect(func(pressed: bool) -> void:
		if DebugApi:
			DebugApi.set_tools_visible(pressed))
	_vbox.add_child(tools_check)
	# 操作提示
	var hint := Label.new()
	hint.text = "拖动按钮/面板可移动\nF3 切换显示/隐藏\n独立工具不随 F3 隐藏"
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(0.5, 0.5, 0.5)
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_vbox.add_child(hint)


func _on_drawer_toggled(pressed: bool, drawer_name: String) -> void:
	if DebugApi:
		DebugApi.set_drawer_enabled(drawer_name, pressed)


## 按钮点击（非拖动时触发）
func _on_button_pressed() -> void:
	if _is_dragging:
		return
	if _content_panel.visible:
		_collapse()
	else:
		_expand()


func _expand() -> void:
	_content_panel.visible = true
	_refresh_drawer_list()
	if DebugApi:
		DebugApi.set_panel_expanded(true)
	_update_toggle_text()


func _collapse() -> void:
	_content_panel.visible = false
	if DebugApi:
		DebugApi.set_panel_expanded(false)
	_update_toggle_text()


func _update_toggle_text() -> void:
	_toggle_button.text = "▼ 调试" if _content_panel.visible else "调试"


func _on_visibility_changed(v: bool) -> void:
	visible = v


## 拖动处理（按钮和面板共用）
func _on_drag_input(event: InputEvent, target: Control, target_name: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = target
			_drag_offset = event.position
			_press_pos = event.position
			_is_dragging = false
		else:
			if _dragging == target:
				# 保存位置
				if DebugApi:
					if target_name == "button":
						DebugApi.set_button_position(target.position)
					elif target_name == "panel":
						DebugApi.set_panel_position(target.position)
			_dragging = null
			# 延迟重置拖动标志，让 pressed 信号能检查
			call_deferred("_reset_drag_flag")
	elif event is InputEventMouseMotion and _dragging == target:
		var moved: float = (event.position - _press_pos).length()
		if moved > DRAG_THRESHOLD:
			_is_dragging = true
		target.position += event.relative
		# 限制在屏幕范围内
		var vp_size: Vector2 = get_viewport_rect().size
		target.position.x = clampf(target.position.x, 0, vp_size.x - target.size.x)
		target.position.y = clampf(target.position.y, 0, vp_size.y - target.size.y)


func _reset_drag_flag() -> void:
	_is_dragging = false
