extends Node
## 战略图模块（world_map）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 world_map 内部脚本的方法。
##
## 详见 docs/技术/架构/战略图架构.md §六 API 契约
## 术语：战略图（看的地图，玩家不在其中）vs 场景图（玩家地图，玩家在其中）

# ===== 公共信号 =====

## 地块/地区/聚落被点击（左键）
## granularity: 0=L3, 1=L2, 2=L1；未命中字段为 ""
signal region_clicked(granularity: int, region_id: String, tile_id: String, settlement_id: String)

## 地块/地区/聚落被右键点击
signal region_right_clicked(granularity: int, region_id: String, tile_id: String, settlement_id: String)

## 鼠标悬停变化
signal region_hovered(granularity: int, region_id: String, tile_id: String, settlement_id: String)

## 粒度切换（L3↔L2↔L1）
signal granularity_changed(old_g: int, new_g: int, focused_parent_id: String)

## 地图模式切换
signal map_mode_changed(mode: int, mode_name: String)

## 数据变更（接收其他模块的 EventBus 信号后转发）
signal region_owner_changed(region_id: String, old_owner: String, new_owner: String)
signal settlement_updated(settlement_id: String)  ## 聚落规模变化（玩家建设）
signal battlefront_updated(battle_id: String, region_id: String)
## 战略图打开（通知 UI / InputDispatcher 暂停场景图输入）
signal strategic_map_opened
## 战略图关闭（通知 UI / InputDispatcher 恢复场景图输入）
signal strategic_map_closed


# ===== 内部引用（在 setup 中绑定） =====

var _controller: StrategicMapController = null
var _renderer: MapRenderer = null
var _camera: MapCamera = null
var _mode_manager: MapModeManager = null
var _data: StrategicMapData = null
var _granularity_manager: GranularityManager = null
var _stitched_preview: StitchedPreviewController = null
var _is_initialized: bool = false


# ===== 初始化 =====

## 由 strategic_map.tscn 根节点调用，注入内部组件引用
func setup(
	controller: StrategicMapController,
	renderer: MapRenderer,
	camera: MapCamera,
	mode_manager: MapModeManager,
	data: StrategicMapData,
	granularity_manager: GranularityManager,
	stitched_preview: StitchedPreviewController
) -> void:
	_controller = controller
	_renderer = renderer
	_camera = camera
	_mode_manager = mode_manager
	_data = data
	_granularity_manager = granularity_manager
	_stitched_preview = stitched_preview
	_is_initialized = true


## 初始化战略图（加载 L3 大世界数据）
## [P] setup 已调用，manifest_path 指向 config/strategic_map/manifest.tres
## [Q] continent + political 加载完成，current_granularity = L3
func initialize(manifest_path: String) -> void:
	# TODO: SM-1 实现
	# 1. load(manifest_path) 加载 manifest.tres
	# 2. _data.manifest = manifest
	# 3. _data.load_continent()
	# 4. _renderer.refresh()
	pass


# ===== 粒度切换 =====

## 设置粒度级别
## level: 0=L3, 1=L2, 2=L1
## [P] level=1 时 parent_id 是合法 region_id；level=2 时是合法 tile_id
## [Q] 触发懒加载，发射 granularity_changed
func set_granularity(level: int, parent_id: String = "") -> void:
	if _granularity_manager:
		_granularity_manager.set_granularity(level, parent_id)


func get_granularity() -> int:
	if _data:
		return _data.current_granularity
	return 0


func get_focused_parent_id() -> String:
	if _data:
		return _data.focused_parent_id
	return ""


# ===== 查询 =====

## 根据屏幕坐标查询 ID
## 返回 {"granularity": int, "region_id": String, "tile_id": String, "settlement_id": String}
func query_at_screen(screen_pos: Vector2) -> Dictionary:
	if _data:
		return _data.query_id_at_screen(screen_pos)
	return {"granularity": 0, "region_id": "", "tile_id": "", "settlement_id": ""}


## 获取地区数据
func get_region_data(region_id: String) -> RegionData:
	if _data:
		return _data.regions.get(region_id, null)
	return null


## 获取地块数据
func get_tile_data(tile_id: String) -> MapTileData:
	if _data:
		return _data.tiles.get(tile_id, null)
	return null


## 获取聚落引用
func get_settlement_ref(settlement_id: String) -> SettlementRef:
	if _data:
		return _data.get_settlement(settlement_id)
	return null


## 获取当前粒度下所有可见多边形（用于 UI 标记放置）
func get_visible_polygons() -> Array[Dictionary]:
	if _data:
		return _data.get_visible_polygons()
	return []


# ===== 选中 =====

func select(id: String) -> void:
	if _renderer:
		_renderer.select(id)


func deselect() -> void:
	if _renderer:
		_renderer.deselect()


func get_selected() -> String:
	if _renderer:
		return _renderer.get_selected()
	return ""


# ===== 地图模式 =====

func set_map_mode(mode: int) -> void:
	if _mode_manager:
		_mode_manager.switch_mode(mode)


func get_map_mode() -> int:
	if _mode_manager:
		return int(_mode_manager.current_mode)
	return 0


func get_available_map_modes() -> Array:
	if _mode_manager:
		return _mode_manager.get_available_modes()
	return []


# ===== 相机 =====

## 聚焦到指定 region/tile/settlement 的中心
func camera_focus(id: String, animated: bool = true) -> void:
	if _camera:
		_camera.focus_on(id, animated)


## 缩放到指定粒度（触发 set_granularity）
func camera_zoom_to(granularity: int) -> void:
	set_granularity(granularity)


func screen_to_map(screen_pos: Vector2) -> Vector2:
	if _camera:
		return _camera.screen_to_map(screen_pos)
	return screen_pos


func map_to_screen(map_pos: Vector2) -> Vector2:
	if _camera:
		return _camera.map_to_screen(map_pos)
	return map_pos


# ===== 政治属性（只读查询，写入通过 EventBus） =====

func get_region_owner(region_id: String) -> String:
	if _data:
		return _data.get_region_owner(region_id)
	return ""


func get_region_alliance(region_id: String) -> String:
	if _data and _data.political:
		var state_id := _data.get_region_owner(region_id)
		if state_id.is_empty():
			return ""
		var info: Dictionary = _data.political.get_state_info(state_id)
		return info.get("alliance_id", "")
	return ""


func get_state_info(state_id: String) -> Dictionary:
	if _data and _data.political:
		return _data.political.get_state_info(state_id)
	return {}


func get_alliance_info(alliance_id: String) -> Dictionary:
	if _data and _data.political:
		return _data.political.get_alliance_info(alliance_id)
	return {}


func set_owner_color(state_id: String, color: Color) -> void:
	if _data and _data.political:
		_data.political.set_state_color(state_id, color)
		if _renderer:
			_renderer.refresh()


# ===== 拼接预览模式 =====

## 启用拼接预览（跨地区作战时）
func enable_stitched_preview() -> void:
	if _stitched_preview:
		_stitched_preview.enable()


## 关闭拼接预览
func disable_stitched_preview() -> void:
	if _stitched_preview:
		_stitched_preview.disable()


## 拼接预览是否启用
func is_stitched_preview_enabled() -> bool:
	if _stitched_preview:
		return _stitched_preview.is_enabled()
	return false


# ===== 场景图切换 =====

## 进入聚落（关闭战略图，加载场景图）
## [P] settlement_id 存在且对应 map_id 已注册
## [Q] 发射 EventBus.travel_requested，关闭战略图 ModalOverlay
func enter_settlement(settlement_id: String) -> void:
	var settlement: SettlementRef = get_settlement_ref(settlement_id)
	if settlement == null:
		push_warning("[WorldMapApi] 聚落不存在: %s" % settlement_id)
		return
	var map_id: String = settlement.map_id
	if map_id.is_empty():
		push_warning("[WorldMapApi] 聚落无 map_id: %s" % settlement_id)
		return
	# 发射旅行请求 -> SceneLoader 监听并处理（详见 §9 战略图->聚落进入流程）
	if EventBus:
		EventBus.travel_requested.emit(map_id)
	# 关闭战略图
	close_strategic_map()


## 关闭战略图，返回之前的场景图
func close_strategic_map() -> void:
	# TODO: 完整实现需要恢复场景图的 CameraRig 和 InputDispatcher
	# 当前阶段：发射关闭信号，由 UI 层处理 ModalOverlay 隐藏
	# 后续实现：
	# 1. 暂停战略图渲染
	# 2. 恢复场景图的 CameraRig 和 InputDispatcher
	# 3. 隐藏 ModalOverlay
	strategic_map_closed.emit()
	if EventBus:
		EventBus.emit_signal("strategic_map_closed")


# ===== 接收其他模块的 EventBus 信号 =====
# 这些方法由 EventBus 连接调用，不是外部直接调用

func _on_region_owner_changed(region_id: String, old_owner: String, new_owner: String) -> void:
	if _data and _data.political:
		_data.political.set_region_owner(region_id, new_owner)
		if _renderer:
			_renderer.refresh()
	region_owner_changed.emit(region_id, old_owner, new_owner)


func _on_settlement_updated(settlement_id: String) -> void:
	# L1 粒度下重新渲染该聚落建筑群
	if _renderer and _data.current_granularity == StrategicMapData.Granularity.L1_TILE:
		_renderer.refresh_settlement(settlement_id)
	settlement_updated.emit(settlement_id)


func _on_battle_started(battle_id: String, region_id: String, tile_id: String) -> void:
	if _renderer:
		_renderer.add_battlefront_marker(battle_id, region_id, tile_id)


func _on_battle_ended(battle_id: String) -> void:
	if _renderer:
		_renderer.remove_battlefront_marker(battle_id)
