extends Node
## world_map 模块公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 world_map 内部脚本的方法。
## 借鉴 P社 Clausewitz 引擎设计：地图=标识层+数据层+渲染层分离。

# ===== 公共信号 =====

## 地块被点击（左键）
signal region_clicked(region_id: int)

## 地块被右键点击
signal region_right_clicked(region_id: int)

## 鼠标悬停地块变化（-1 表示离开所有地块区域）
signal region_hovered(region_id: int)

## 地图模式切换
signal map_mode_changed(mode: int, mode_name: String)

## 地块归属变化
signal region_owner_changed(region_id: int, old_owner: int, new_owner: int)


# ===== 内部引用（在 _setup 中绑定） =====
var _map_renderer: MapRenderer
var _map_camera: MapCamera
var _map_mode_manager: MapModeManager
var _world_data: WorldMapData
var _is_initialized: bool = false


# ===== 初始化 =====

## 由 world_map 场景的根节点调用，注入内部组件引用
func setup(
	map_renderer: MapRenderer,
	map_camera: MapCamera,
	map_mode_manager: MapModeManager,
	world_data: WorldMapData
) -> void:
	_map_renderer = map_renderer
	_map_camera = map_camera
	_map_mode_manager = map_mode_manager
	_world_data = world_data
	_is_initialized = true


# ===== 地块查询 =====

## 根据屏幕坐标查询地块ID（用于输入处理）
func get_region_at_screen(screen_pos: Vector2) -> int:
	if _map_renderer == null:
		return -1
	return _map_renderer.get_region_id_at_screen_position(screen_pos)

## 获取地块数据
func get_region(region_id: int) -> RegionDefinition:
	if _world_data == null:
		return null
	return _world_data.get_region(region_id)

## 获取所有地块数据
func get_all_regions() -> Dictionary:
	if _world_data == null:
		return {}
	return _world_data.regions

## 获取所有可通行陆地地块
func get_passable_land_regions() -> Array[int]:
	if _world_data == null:
		return []
	return _world_data.get_passable_land_regions()


# ===== 归属操作 =====

## 获取地块归属
func get_region_owner(region_id: int) -> int:
	if _world_data == null:
		return -1
	return _world_data.get_owner(region_id)

## 设置地块归属
func set_region_owner(region_id: int, owner_id: int):
	if _world_data == null:
		return
	var old_owner: int = _world_data.get_owner(region_id)
	_world_data.set_owner(region_id, owner_id)
	if _map_renderer:
		_map_renderer.refresh_cache()
	region_owner_changed.emit(region_id, old_owner, owner_id)

## 批量设置地块归属（用于和平条约等场景）
func set_region_owners_bulk(owner_map: Dictionary):
	if _world_data == null:
		return
	for region_id in owner_map:
		_world_data.set_owner(region_id, owner_map[region_id])
	if _map_renderer:
		_map_renderer.refresh_cache()


# ===== 地图模式 =====

## 设置地图模式
func set_map_mode(mode: int):
	if _map_mode_manager:
		_map_mode_manager.switch_mode(mode)

## 获取当前地图模式
func get_map_mode() -> int:
	if _map_mode_manager:
		return int(_map_mode_manager.current_mode)
	return 0

## 获取所有可用地图模式
func get_available_map_modes() -> Array:
	if _map_mode_manager:
		return _map_mode_manager.get_available_modes()
	return []


# ===== 地块选中 =====

## 选中地块
func select_region(region_id: int):
	if _map_renderer:
		_map_renderer.select_region(region_id)

## 取消选中
func deselect_region():
	if _map_renderer:
		_map_renderer.deselect_region()

## 获取当前选中地块
func get_selected_region() -> int:
	if _map_renderer:
		return _map_renderer.get_selected_region()
	return -1


# ===== 镜头控制 =====

## 镜头移动到指定地图坐标
func camera_move_to(pos: Vector2, animated: bool = false):
	if _map_camera:
		_map_camera.move_to(pos, animated)

## 镜头缩放到指定级别
func camera_set_zoom(zoom: float):
	if _map_camera:
		_map_camera.set_zoom(zoom)

## 屏幕坐标转地图坐标
func screen_to_map(screen_pos: Vector2) -> Vector2:
	if _map_camera:
		return _map_camera.screen_to_map(screen_pos)
	return screen_pos


# ===== 势力颜色管理 =====

## 设置势力颜色
func set_owner_color(owner_id: int, color: Color):
	if _world_data == null:
		return
	_world_data.owner_colors[owner_id] = color
	if _map_renderer:
		_map_renderer.refresh_cache()


## 获取地图尺寸
func get_map_size() -> Vector2:
	if _world_data == null:
		return Vector2.ZERO
	return _world_data.map_size
