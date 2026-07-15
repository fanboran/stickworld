extends Node2D
class_name StrategicMapController
## 战略图主控制器 —— 串联所有组件，处理输入事件
##
## 详见 docs/技术/架构/战略图架构.md §二 模块结构
## 替代旧的 WorldMapController

## 公共 API 引用（同一场景内）
@export var api: Node

## 组件引用
@export var map_renderer: MapRenderer
@export var map_camera: MapCamera
@export var map_mode_manager: MapModeManager
@export var granularity_manager: GranularityManager
@export var stitched_preview: StitchedPreviewController

## 世界数据
@export var world_data: StrategicMapData

## 输入控制
@export var left_click_selects: bool = true
@export var right_click_info: bool = true
@export var double_click_drill_down: bool = true  ## 双击下钻到下一粒度


func _ready() -> void:
	# 自动查找组件（如果未手动指定）
	_auto_find_components()

	# 初始化 API
	if api and api.has_method("setup"):
		api.setup(
			self,
			map_renderer,
			map_camera,
			map_mode_manager,
			world_data,
			granularity_manager,
			stitched_preview
		)


func _auto_find_components() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for child in parent.get_children():
		if child is MapRenderer and map_renderer == null:
			map_renderer = child
		elif child is MapCamera and map_camera == null:
			map_camera = child
		elif child is MapModeManager and map_mode_manager == null:
			map_mode_manager = child
		elif child is GranularityManager and granularity_manager == null:
			granularity_manager = child
		elif child is StitchedPreviewController and stitched_preview == null:
			stitched_preview = child
		elif child.name.to_lower() == "api" and api == null:
			api = child


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	# 鼠标点击
	if event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_handle_left_click(mb.position)
			MOUSE_BUTTON_RIGHT:
				_handle_right_click(mb.position)

	# 双击下钻
	if double_click_drill_down and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
			_handle_double_click(mb.position)

	# 键盘
	if event is InputEventKey and event.pressed:
		_handle_key(event as InputEventKey)


func _handle_left_click(screen_pos: Vector2) -> void:
	if api == null:
		return
	var query: Dictionary = api.query_at_screen(screen_pos)
	if query.is_empty():
		return
	api.select(_get_select_id(query))
	if api.has_signal("region_clicked"):
		api.region_clicked.emit(
			query.get("granularity", 0),
			query.get("region_id", ""),
			query.get("tile_id", ""),
			query.get("settlement_id", "")
		)


func _handle_right_click(screen_pos: Vector2) -> void:
	if api == null:
		return
	var query: Dictionary = api.query_at_screen(screen_pos)
	if query.is_empty():
		return
	if api.has_signal("region_right_clicked"):
		api.region_right_clicked.emit(
			query.get("granularity", 0),
			query.get("region_id", ""),
			query.get("tile_id", ""),
			query.get("settlement_id", "")
		)


func _handle_double_click(screen_pos: Vector2) -> void:
	# 双击下钻：L3→L2→L1→场景图
	if api == null or granularity_manager == null:
		return
	var query: Dictionary = api.query_at_screen(screen_pos)
	if query.is_empty():
		return
	var g: int = query.get("granularity", 0)
	match g:
		0:  # L3 → L2
			var rid: String = query.get("region_id", "")
			if not rid.is_empty():
				granularity_manager.set_granularity(1, rid)
		1:  # L2 → L1
			var tid: String = query.get("tile_id", "")
			if not tid.is_empty():
				granularity_manager.set_granularity(2, tid)
		2:  # L1 → 场景图
			var sid: String = query.get("settlement_id", "")
			if not sid.is_empty():
				api.enter_settlement(sid)


func _handle_key(key_event: InputEventKey) -> void:
	match key_event.keycode:
		KEY_TAB:
			# 切换地图模式
			if map_mode_manager:
				map_mode_manager.cycle_mode()
		KEY_ESCAPE:
			# 返回上一级粒度，或关闭战略图
			if granularity_manager:
				granularity_manager.go_back()
		KEY_HOME:
			# 重置相机
			if map_camera:
				map_camera.focus_on("", true)
		KEY_F1:
			# 切换调试标签
			if map_renderer:
				map_renderer.debug_show_labels = not map_renderer.debug_show_labels
		KEY_F2:
			# 切换拼接预览模式
			if api:
				if api.is_stitched_preview_enabled():
					api.disable_stitched_preview()
				else:
					api.enable_stitched_preview()


func _get_select_id(query: Dictionary) -> String:
	# 按粒度选最细的 ID
	var g: int = query.get("granularity", 0)
	match g:
		0: return query.get("region_id", "")
		1: return query.get("tile_id", "")
		2: return query.get("settlement_id", "")
	return ""
