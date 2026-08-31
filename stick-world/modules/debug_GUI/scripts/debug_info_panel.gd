extends Control
## 调试信息面板 -- 画面中的文本框，显示 FPS/实体数/鼠标悬停单位信息。
##
## 非覆盖绘制，是一个独立的 UI 面板。通过调试面板的复选框控制显示/隐藏。
## 面板可拖动，位置通过 DebugApi 持久化。

var _label: Label = null
var _panel: Panel = null
var _hovered_entity: Node2D = null
## 拖动状态
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	if DebugApi:
		visible = DebugApi.is_visible() and DebugApi.is_drawer_enabled("entity_info")
		DebugApi.visibility_changed.connect(_on_visibility_changed)
		DebugApi.drawer_enabled_changed.connect(_on_drawer_enabled_changed)


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	_update_hovered()
	_update_text()


func _build_ui() -> void:
	# 半透明背景面板（可拖动）
	_panel = Panel.new()
	_panel.position = Vector2(12, 80)
	_panel.custom_minimum_size = Vector2(300, 180)
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_panel.gui_input.connect(_on_panel_gui_input)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.88)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_right = 6.0
	sb.content_margin_bottom = 4.0
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	# 文本标签
	_label = Label.new()
	_label.text = "FPS: 0\n实体: 0\n悬停: 无"
	_label.add_theme_font_size_override("font_size", 12)
	_label.modulate = Color(0.9, 0.95, 1.0, 0.9)
	_label.position = Vector2(6, 4)
	_label.custom_minimum_size = Vector2(288, 170)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)


func _update_text() -> void:
	if _label == null:
		return
	var lines: Array[String] = []
	# FPS + 实体数
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	var map: Node2D = _get_current_map()
	var entity_count: int = 0
	if map != null and is_instance_valid(map):
		# 实体宿主路径由 world 装配层注入（见 system_setup.register_debug_drawers），不 import WorldAPI
		var map_paths: Dictionary = DebugApi.get_ctx_extra("map_paths", {}) if DebugApi else {}
		var entity_host: Node2D = map.get_node_or_null(map_paths.get("entity_host", ""))
		if entity_host != null:
			entity_count = entity_host.get_child_count()
	lines.append("实体: %d" % entity_count)
	# 鼠标悬停实体信息
	if _hovered_entity == null or not is_instance_valid(_hovered_entity):
		lines.append("悬停: 无")
		_label.modulate = Color(0.7, 0.7, 0.7, 0.8)
	else:
		_label.modulate = Color(0.9, 0.95, 1.0, 0.9)
		var e: Node2D = _hovered_entity
		lines.append("悬停: %s" % e.name)
		lines.append("  坐标: (%d, %d)" % [int(e.global_position.x), int(e.global_position.y)])
		if "possessed" in e:
			lines.append("  状态: %s" % ("[主控]" if e.possessed else "[AI]"))
		if e.has_method("get_current_anim"):
			lines.append("  动画: %s" % e.get_current_anim())
		if e.has_method("get_facing"):
			lines.append("  朝向: %d" % e.get_facing())
		if "health" in e:
			var max_hp: float = float(e.max_health) if "max_health" in e else 100.0
			lines.append("  HP: %d/%d" % [int(e.health), int(max_hp)])
	_label.text = "\n".join(lines)


## 面板拖动
func _on_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_offset = event.position
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_panel.position += event.relative
		var vp_size: Vector2 = get_viewport_rect().size
		_panel.position.x = clampf(_panel.position.x, 0, vp_size.x - _panel.size.x)
		_panel.position.y = clampf(_panel.position.y, 0, vp_size.y - _panel.size.y)


func _update_hovered() -> void:
	var camera: Camera2D = _get_camera()
	if camera == null:
		_hovered_entity = null
		return
	var zoom: float = camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0
	var vp_size: Vector2 = get_viewport_rect().size
	var cam_pos: Vector2 = camera.global_position
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var mouse_world: Vector2 = (mouse_screen - vp_size * 0.5) / zoom + cam_pos
	var map: Node2D = _get_current_map()
	if map == null:
		_hovered_entity = null
		return
	var entity_host: Node2D = map.get_node_or_null(
			(DebugApi.get_ctx_extra("map_paths", {}) if DebugApi else {}).get("entity_host", ""))
	if entity_host == null:
		_hovered_entity = null
		return
	var closest: Node2D = null
	var closest_dist: float = 999999.0
	for entity in entity_host.get_children():
		if not entity is CharacterBody2D:
			continue
		var e: CharacterBody2D = entity as CharacterBody2D
		# 用 Range 节点检测悬停（比 Collider 大，更容易触发）
		var rng: CollisionShape2D = e.get_node_or_null("Range") as CollisionShape2D
		if rng == null or not (rng.shape is RectangleShape2D):
			continue
		var rs: RectangleShape2D = rng.shape as RectangleShape2D
		var diff: Vector2 = mouse_world - rng.global_position
		if absf(diff.x) <= rs.size.x * 0.5 and absf(diff.y) <= rs.size.y * 0.5:
			var d: float = diff.length()
			if d < closest_dist:
				closest_dist = d
				closest = e
	_hovered_entity = closest


## （调试可视化职责豁免：本模块职责即全局可视化，2026-08 审计标注）
func _get_camera() -> Camera2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		var cam: Node = child.get_node_or_null("CameraRig")
		if cam != null and cam is Camera2D:
			return cam as Camera2D
	return null


func _get_current_map() -> Node2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		if child.has_method("get_current_map"):
			var map: Node2D = child.get_current_map() as Node2D
			if map != null and is_instance_valid(map):
				return map
	return null


func _on_visibility_changed(_v: bool) -> void:
	_update_visible()


func _on_drawer_enabled_changed(_name: String, _enabled: bool) -> void:
	if _name == "entity_info":
		_update_visible()


func _update_visible() -> void:
	if DebugApi:
		visible = DebugApi.is_visible() and DebugApi.is_drawer_enabled("entity_info")
