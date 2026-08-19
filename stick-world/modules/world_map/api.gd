extends Node
## 战略图模块（world_map）公共接口契约 —— L1 单层版
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 world_map 内部脚本的方法。
##
## 详见 docs/技术/架构/战略图架构.md §六 API 契约（L1 单层子集）
## 术语：战略图（看的地图，玩家不在其中）vs 场景图（玩家地图，玩家在其中）

# ===== 公共信号 =====

## 聚落被点击（左键）
@warning_ignore("unused_signal")
signal settlement_clicked(settlement_id: String)

## 聚落被双击（进入场景图）
@warning_ignore("unused_signal")
signal settlement_activated(settlement_id: String)

## 鼠标悬停变化
@warning_ignore("unused_signal")
signal region_hovered(tile_id: String, settlement_id: String)

# 战略图开/关通知走 EventBus.strategic_map_opened / strategic_map_closed（单一通道，勿在本地重复声明）


# ===== 内部引用 =====

var _data: L1WorldData = null
var _controller: Node = null
var _renderer: Node = null
var _camera: Node = null
var _is_initialized: bool = false


# ===== 初始化 =====

## 由 strategic_map.tscn 根节点调用，注入内部组件引用
func setup(
	controller: Node,
	renderer: Node,
	camera: Node
) -> void:
	_controller = controller
	_renderer = renderer
	_camera = camera


## 初始化战略图（加载 L1 世界数据）
## json_path: l1_world.json 的 res:// 路径
## base_dir: 含 l1_base.png / l1_mask.png 的目录
## [P] setup 已调用
## [Q] L1WorldData 加载完成，渲染器/相机就绪
func initialize(json_path: String, base_dir: String) -> void:
	_data = L1WorldData.load_from(json_path, base_dir)
	_is_initialized = _data != null and _data.base_texture != null
	if _is_initialized:
		if _renderer != null and _renderer.has_method("set_data"):
			_renderer.set_data(_data)
		if _camera != null and _camera.has_method("set_data"):
			_camera.set_data(_data)


func is_initialized() -> bool:
	return _is_initialized


## 加载指定老 L1 的地图数据（L2 点击 L1 下钻用）
## l1_label: 老 L1 全局 label（1..69），数据在 config/strategic_map/l1_packs/l1_%03d/l1_world.json
## 成功后替换当前数据（renderer/camera 同步切换），返回是否成功
func open_l1(l1_label: int) -> bool:
	var dir_name := "l1_%03d" % l1_label
	var base_dir := "res://config/strategic_map/l1_packs/%s" % dir_name
	var json_path := "%s/l1_world.json" % base_dir
	if not FileAccess.file_exists(json_path):
		push_error("[StrategicMapAPI] L1 数据缺失: %s" % json_path)
		return false
	var data := L1WorldData.load_from(json_path, base_dir)
	if data == null or data.base_texture == null:
		push_error("[StrategicMapAPI] L1 加载失败: %s" % dir_name)
		return false
	_data = data
	if _renderer != null and _renderer.has_method("set_data"):
		_renderer.set_data(data)
	if _camera != null and _camera.has_method("set_data"):
		_camera.set_data(data)
	return true


func get_data() -> L1WorldData:
	return _data


# ===== 查询 =====

## 根据屏幕坐标查询命中的聚落
## 返回 {"tile": L1TileDef, "settlement": SettlementRef}
func query_at_screen(screen_pos: Vector2) -> Dictionary:
	if _data == null or _camera == null:
		return {"tile": null, "settlement": null}
	var map_pos: Vector2 = _camera.screen_to_map(screen_pos)
	return _data.query_at_map_pos(map_pos)


## 获取聚落引用
func get_settlement_ref(settlement_id: String) -> SettlementRef:
	if _data == null:
		return null
	return _data.get_settlement(settlement_id)


## 获取所有地块（L1 多边形 + 聚落）
func get_tiles() -> Array:
	if _data == null:
		return []
	return _data.tiles


## 获取所有道路（像素坐标点列）
func get_roads() -> Array:
	if _data == null:
		return []
	return _data.roads


# ===== 选中 =====

func select(id: String) -> void:
	if _renderer != null and _renderer.has_method("select"):
		_renderer.select(id)


func deselect() -> void:
	if _renderer != null and _renderer.has_method("deselect"):
		_renderer.deselect()


func get_selected() -> String:
	if _renderer != null and _renderer.has_method("get_selected"):
		return _renderer.get_selected()
	return ""


# ===== 相机 =====

## 聚焦到指定地块中心
func camera_focus(id: String, animated: bool = true) -> void:
	if _camera != null and _camera.has_method("focus_on"):
		_camera.focus_on(id, animated)


func screen_to_map(screen_pos: Vector2) -> Vector2:
	if _camera != null and _camera.has_method("screen_to_map"):
		return _camera.screen_to_map(screen_pos)
	return screen_pos


func map_to_screen(map_pos: Vector2) -> Vector2:
	if _camera != null and _camera.has_method("map_to_screen"):
		return _camera.map_to_screen(map_pos)
	return map_pos


# ===== 政治属性（只读查询） =====

func get_state_color(state_id: String) -> Color:
	if _data == null:
		return Color.GRAY
	return _data.get_state_color(state_id)


func get_states() -> Dictionary:
	if _data == null:
		return {}
	return _data.states


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
		push_warning("[WorldMapApi] 聚落无 map_id（空聚落不可进入）: %s" % settlement_id)
		return
	# 发射旅行请求 -> SceneLoader 监听并处理
	if EventBus != null:
		EventBus.travel_requested.emit(map_id)
	# 关闭战略图
	close_strategic_map()


## 关闭战略图，返回之前的场景图。
## 关闭通知统一由控制器经 EventBus.strategic_map_closed 发射（controller.close 内），
## 此处兜底：控制器缺失时直接发信号，避免场景图输入永久暂停。
func close_strategic_map() -> void:
	if _controller != null and _controller.has_method("close"):
		_controller.close()
	elif EventBus != null:
		EventBus.strategic_map_closed.emit()
