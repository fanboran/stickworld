class_name Minimap
extends Control
## 小地图 —— 屏幕正上方中央的缩略地图。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.4。
## P0 策略 3（纯色填充）：地面绿色矩形 + 天空蓝色矩形。
##
## 显示内容：
##   - 地图缩略图（纯色填充：天空蓝 + 地面绿）
##   - 当前屏幕视野框（红色边框）
##   - 角色位置点（绿色）
##   - 建筑物图标（黄/棕色小矩形）
##
## 交互：
##   - 左键点击/拖动：相机跳转到点击位置（RTS 式），暂停自动跟随
##
## 由 GameRoot 在 _ready 中创建并 add_child 到 UIRoot，随后调用 setup(game_root)。

# ─────────────────────────────── 常量 ────────────────────────────────
## 小地图尺寸（屏幕像素）
const MAP_WIDTH: float = 240.0
const MAP_HEIGHT: float = 80.0
## 边框宽度
const BORDER_WIDTH: float = 2.0
## 建筑图标最小宽度（像素）
const BUILDING_MIN_W: float = 2.0
## 视野框更新频率（Hz，节流避免每帧重算）
const UPDATE_HZ: float = 15.0

# ─────────────────────────────── 颜色 ────────────────────────────────
const COLOR_BORDER: Color = Color(0.15, 0.15, 0.15, 0.9)
const COLOR_SKY: Color = Color(0.25, 0.45, 0.7, 0.7)
const COLOR_GROUND: Color = Color(0.2, 0.45, 0.2, 0.85)
const COLOR_VIEWPORT: Color = Color(1.0, 0.3, 0.3, 0.85)
const COLOR_PLAYER: Color = Color(0.3, 1.0, 0.35, 1.0)
const COLOR_BUILDING: Color = Color(0.85, 0.7, 0.35, 0.9)
const COLOR_TERRAIN_BLD: Color = Color(0.6, 0.55, 0.5, 0.85)

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _camera_rig: Node = null

# ─────────────────────────────── 地图信息 ────────────────────────────────
var _map_left: float = 0.0
var _map_right: float = 8192.0
var _map_width: float = 8192.0
var _ground_y: float = 810.0
var _ground_bottom: float = 1080.0
var _ground_ratio: float = 0.25
var _has_map_info: bool = false

# ─────────────────────────────── 状态 ────────────────────────────────
var _update_accum: float = 0.0
var _dragging: bool = false


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入引用。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_camera_rig = game_root.camera_rig if game_root.has_method("get") else null
	if _camera_rig == null and game_root.get("camera_rig") != null:
		_camera_rig = game_root.camera_rig
	# 设置位置：屏幕正上方中央
	_anchor_top_center()
	mouse_filter = Control.MOUSE_FILTER_STOP


## 设置地图信息（地图加载时由 GameRoot 调用，详见 §10.4.6）
func set_map_info(p_map_left: float, p_map_right: float, p_ground_y: float, p_ground_ratio: float) -> void:
	_map_left = p_map_left
	_map_right = p_map_right
	_map_width = p_map_right - p_map_left
	if _map_width <= 0.0:
		_map_width = 1.0
	_ground_y = p_ground_y
	_ground_ratio = p_ground_ratio
	_has_map_info = true
	queue_redraw()


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _process(delta: float) -> void:
	# 节流重绘（15Hz 足够，角色点/视野框不需要每帧）
	_update_accum += delta
	if _update_accum >= 1.0 / UPDATE_HZ:
		_update_accum = 0.0
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not _has_map_info:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_jump_to_mouse(event.position)
			else:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_jump_to_mouse(event.position)


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	if not _has_map_info:
		_draw_placeholder()
		return
	var rect := Rect2(Vector2.ZERO, Vector2(MAP_WIDTH, MAP_HEIGHT))
	# 1. 背景：天空 + 地面
	var ground_y_px: float = MAP_HEIGHT * (1.0 - _ground_ratio)
	draw_rect(rect, COLOR_SKY, true)
	draw_rect(Rect2(Vector2(0, ground_y_px), Vector2(MAP_WIDTH, MAP_HEIGHT - ground_y_px)), COLOR_GROUND, true)
	# 2. 建筑图标
	_draw_buildings(ground_y_px)
	# 3. 角色点
	_draw_player_dot(ground_y_px)
	# 4. 视野框
	_draw_viewport_rect()
	# 5. 边框
	draw_rect(rect, COLOR_BORDER, false, BORDER_WIDTH)


func _draw_placeholder() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(MAP_WIDTH, MAP_HEIGHT))
	draw_rect(rect, Color(0.2, 0.2, 0.2, 0.8), true)
	draw_rect(rect, COLOR_BORDER, false, BORDER_WIDTH)


func _draw_buildings(ground_y_px: float) -> void:
	var map: Node2D = _get_current_map()
	if map == null:
		return
	# 动态建筑（building_host）
	var building_host: Node2D = map.get_node_or_null("BuildingHost") if map.has_method("get_node_or_null") else null
	if building_host != null:
		for building in building_host.get_children():
			if building is Node2D:
				_draw_building_icon(building as Node2D, ground_y_px, COLOR_BUILDING)
	# 地形建筑（terrain_buildings，只读）
	var terrain_bld: Node2D = map.get_node_or_null("TerrainBuildings") if map.has_method("get_node_or_null") else null
	if terrain_bld != null:
		for building in terrain_bld.get_children():
			if building is Node2D:
				_draw_building_icon(building as Node2D, ground_y_px, COLOR_TERRAIN_BLD)


func _draw_building_icon(building: Node2D, ground_y_px: float, color: Color) -> void:
	var world_x: float = building.global_position.x
	var icon_x: float = _world_to_minimap_x(world_x)
	# 建筑宽度（从 PassageBarrier 或默认 32px）
	var world_w: float = 32.0
	var pb: Node = building.get_node_or_null("PassageBarrier")
	if pb != null:
		for child in pb.get_children():
			if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
				world_w = ((child as CollisionShape2D).shape as RectangleShape2D).size.x
				break
	var icon_w: float = maxf(BUILDING_MIN_W, world_w / _map_width * MAP_WIDTH)
	# 建筑图标在地面线上方（模拟建筑高度）
	var icon_h: float = 6.0
	draw_rect(Rect2(icon_x - icon_w * 0.5, ground_y_px - icon_h, icon_w, icon_h), color, true)


func _draw_player_dot(ground_y_px: float) -> void:
	var player: Node2D = _get_player_entity()
	if player == null:
		return
	var dot_x: float = _world_to_minimap_x(player.global_position.x)
	# 角色点在地面线上（Y 固定，详见 §10.4.4）
	draw_circle(Vector2(dot_x, ground_y_px), 3.0, COLOR_PLAYER)


func _draw_viewport_rect() -> void:
	if _camera_rig == null or not _camera_rig.has_method("get_viewport_rect_world"):
		return
	var vp_world: Rect2 = _camera_rig.get_viewport_rect_world()
	var vp_x: float = _world_to_minimap_x(vp_world.position.x)
	var vp_w: float = vp_world.size.x / _map_width * MAP_WIDTH
	# 视野框覆盖整个小地图高度（水平卷轴，垂直范围恒定）
	var vp_rect := Rect2(vp_x, 0, vp_w, MAP_HEIGHT)
	vp_rect = vp_rect.intersection(Rect2(Vector2.ZERO, Vector2(MAP_WIDTH, MAP_HEIGHT)))
	draw_rect(vp_rect, COLOR_VIEWPORT, false, 1.5)


# ─────────────────────────────── 坐标映射 ────────────────────────────────

## 世界坐标 X → 小地图 X
func _world_to_minimap_x(world_x: float) -> float:
	return (world_x - _map_left) / _map_width * MAP_WIDTH


## 小地图 X → 世界坐标 X
func _minimap_to_world_x(minimap_x: float) -> float:
	return minimap_x / MAP_WIDTH * _map_width + _map_left


# ─────────────────────────────── 交互 ────────────────────────────────

## 点击/拖动小地图 → 相机跳转（RTS 式，暂停自动跟随，详见 §10.4.5）
func _jump_to_mouse(local_pos: Vector2) -> void:
	if _camera_rig == null or not _camera_rig.has_method("jump_to_x"):
		return
	var world_x: float = _minimap_to_world_x(local_pos.x)
	_camera_rig.jump_to_x(world_x)


# ─────────────────────────────── 内部辅助 ────────────────────────────────

func _anchor_top_center() -> void:
	# 锚定到屏幕正上方中央
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	# 计算居中位置
	var vp_w: float = get_viewport_rect().size.x
	var pos_x: float = (vp_w - MAP_WIDTH) * 0.5
	position = Vector2(pos_x, 4.0)
	size = Vector2(MAP_WIDTH, MAP_HEIGHT)


func _get_current_map() -> Node2D:
	if _game_root == null:
		return null
	if _game_root.has_method("get_current_map"):
		return _game_root.get_current_map()
	return null


func _get_player_entity() -> Node2D:
	var map: Node2D = _get_current_map()
	if map == null:
		return null
	# 优先返回附身实体
	if map.has_method("get_possessed_entity"):
		var possessed: Node2D = map.get_possessed_entity()
		if possessed != null:
			return possessed
	# 退而求其次：第一个实体
	if map.has_method("get_entities"):
		var entities: Array = map.get_entities()
		if not entities.is_empty():
			return entities[0]
	return null
