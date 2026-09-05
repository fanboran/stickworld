extends Node2D
class_name L2MapController
## L2 地区详细地图控制器 —— L3 点击地区后进入的下钻视图
##
## 交互：
##   - ESC 返回 L3（发 back_requested 信号，由 L3 控制器恢复显示）
##   - 拖拽/滚轮缩放（MapCamera）
##   - hover 高亮地块（渲染器处理）

## 返回 L3 请求（ESC 触发）
signal back_requested

## L1 下钻视图引用（strategic_map.tscn 的 StrategicMapController；点击 L1 地块时打开对应 L1 地图）
@export var l1_view: Node = null

@export var map_renderer: L2MapRenderer
@export var map_camera: MapCamera

## L2 素材根目录（res:// 相对），子目录 = region_XXX
const DATA_BASE_DIR := "res://config/strategic_map/l2_packs"

## 默认缩放 = 整图适配 × 1.75（打开即更贴近城市细节，并以此作为 HUD 的 100%）
const DEFAULT_ZOOM_MULT := 1.75

## 当前加载的数据
var data: L2WorldData = null

## 底部 HUD（缩放条 + 显示模式按钮，CanvasLayer 直接子）
var _hud: Control = null

## 粒度指示器（CanvasLayer 直接子节点，显隐由本控制器同步；open 时更新文案）
var _indicator: GranularityIndicator = null

## 视图名牌（CanvasLayer 直接子节点，同批显隐；open 时喂"地区 N · N 地块"）
var _title_bar: MapTitleBar = null

## 地图模式管理器（Content 子节点，B4：切模式转发渲染器）
var _mode_manager: MapModeManager = null

var _current_region_id: String = ""


func _ready() -> void:
	_auto_find_components()
	# 层号统一走 LayerOrder 常量（本节点是 CanvasLayer 的 Content 子节点）
	var canvas := get_parent() as CanvasLayer
	if canvas != null:
		canvas.layer = LayerOrder.STRATEGIC_L2
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)
	# 地图模式（B4）：切模式 → 渲染器换层（地形底图/政权叠加层数据落地前仅记录）
	if _mode_manager != null and not _mode_manager.mode_changed.is_connected(_on_map_mode_changed):
		_mode_manager.mode_changed.connect(_on_map_mode_changed)


## 注入 L1 下钻视图（由接线方调用）
func set_l1_view(view: Node) -> void:
	l1_view = view


func _auto_find_components() -> void:
	if map_renderer == null:
		map_renderer = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is L2MapRenderer) as L2MapRenderer
	if map_camera == null:
		map_camera = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapCamera) as MapCamera
	# 指示器挂 CanvasLayer 直下（Control 挂 Node2D 下 anchor 参照矩形为 0 会跑位）
	if _indicator == null:
		_indicator = MapControllerUtil.find_sibling(self, "GranularityIndicator") as GranularityIndicator
	if _title_bar == null:
		_title_bar = MapControllerUtil.find_sibling(self, "MapTitleBar") as MapTitleBar
	if _hud == null:
		_hud = MapControllerUtil.find_sibling(self, "ZoomIndicator")
	if _mode_manager == null:
		_mode_manager = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapModeManager) as MapModeManager


func _input(event: InputEvent) -> void:
	# 用自身 visible（headless 下 is_visible_in_tree 因窗口不可见恒 false）
	if not visible:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# GUI 先决（同 L1 控制器）：悬停控件（HUD 模式条/滑块）时点击归 UI，防穿透下钻 L1
			if get_viewport().gui_get_hovered_control() != null:
				return
			_handle_l1_click(mb.position)
	if event is InputEventKey and event.pressed:
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			# ESC 返回 L3（地图整体仍开着，不关地图、不恢复场景图输入）
			set_view_visible(false)
			back_requested.emit()
			get_viewport().set_input_as_handled()


## 点击 L1 地块：打开对应老 L1 的 Tab 视图（L2 → L1 下钻）
func _handle_l1_click(screen_pos: Vector2) -> void:
	if l1_view == null or data == null or map_camera == null:
		return
	if not map_camera.has_method("screen_to_map"):
		return
	var map_pos: Vector2 = map_camera.screen_to_map(screen_pos)
	# context 坐标 -> 当前地区索引图坐标（与 L2MapRenderer.hover 同路径：-tiles_offset）
	map_pos -= Vector2(data.tiles_offset)
	var query: Dictionary = data.query_at_map_pos(map_pos)
	var tile: Dictionary = query.get("tile", {})
	var gl: int = int(tile.get("global_l1_label", 0))
	if gl <= 0:
		return
	if not l1_view.has_method("open_l1"):
		return
	if not l1_view.back_requested.is_connected(_on_l1_back):
		l1_view.back_requested.connect(_on_l1_back)
	# 隐藏 L2，打开 L1（L1 ESC 经 back_requested 恢复本视图）
	l1_view.call("open_l1", gl)
	set_view_visible(false)


## L1 返回（ESC）：恢复 L2 显示
func _on_l1_back() -> void:
	set_view_visible(true)


## 打开指定 L2 地区视图（region_id 形如 region_001）
func open(region_id: String) -> void:
	# 同一地区重开（M 关闭后恢复）：保留相机位置/缩放；换地区则重新适配
	var same_region: bool = region_id == _current_region_id and data != null
	_current_region_id = region_id
	if not same_region:
		var json_path := "%s/%s/l2_world.json" % [DATA_BASE_DIR, region_id]
		var base_dir := "%s/%s" % [DATA_BASE_DIR, region_id]
		data = L2WorldData.load_from(json_path, base_dir)
		if data.size.x <= 0 or data.size.y <= 0:
			push_error("[L2MapController] 加载失败: %s" % region_id)
			return
		if map_renderer != null and map_renderer.has_method("set_data"):
			map_renderer.set_data(data)
		# 初始视角：整图适配的 1.75 倍（更贴近城市细节），以地图中心为屏幕中心，HUD 记为 100%
		if map_camera != null and map_camera.has_method("set_zoom"):
			var vp := get_viewport()
			if vp != null:
				var vp_size: Vector2 = vp.get_visible_rect().size
				var msize: Vector2 = data.size
				if data.context_size.x > 0:
					msize = data.context_size
				var target_h: float = vp_size.y * 0.72
				var fit_zoom: float = target_h / float(msize.y)
				# 默认缩放 = 1.75×整图适配，夹在相机缩放范围内（小图会顶到 max_zoom）
				var default_zoom: float = clampf(fit_zoom * DEFAULT_ZOOM_MULT,
						map_camera.min_zoom, map_camera.max_zoom)
				map_camera.set_zoom(default_zoom)
				# 默认缩放 = 1.75×整图适配 = 100%（HUD 百分比按此归一化显示）
				if _hud != null and _hud.has_method("set_default_zoom"):
					_hud.set_default_zoom(default_zoom)
				if map_camera.has_method("set_offset"):
					# 地图（context）中心对准屏幕中心，打开即居中
					map_camera.set_offset(vp_size * 0.5 - Vector2(
						float(msize.x) * default_zoom * 0.5, float(msize.y) * default_zoom * 0.5))
	visible = true
	# 地图模式（B4）：本视图关闭期间他视图可能切过模式（全局静态），打开时同步渲染器
	if map_renderer != null and map_renderer.has_method("set_map_mode"):
		map_renderer.set_map_mode(MapModeManager.current_mode)
	if _hud != null:
		_hud.visible = true
	# 粒度指示：L2 层级 + 当前地区 ID（提示文案由组件按 view_level 生成）
	if _indicator != null:
		var rid: String = data.region_id if data != null and not data.region_id.is_empty() else _current_region_id
		_indicator.set_view("L2", rid)
		_indicator.visible = true
	# 名牌：地区 N + 地块数概览（region_001 -> "地区 1"；数据未加载时降级只显 ID）
	if _title_bar != null:
		_update_title_bar()
		_title_bar.visible = true


## 名牌内容：地区序号 + 地块数概览
func _update_title_bar() -> void:
	if _title_bar == null:
		return
	var rid: String = data.region_id if data != null and not data.region_id.is_empty() else _current_region_id
	var title := "地区 %s" % rid
	var n_tiles: int = data.tiles.size() if data != null else 0
	var subtitle := "%d 地块" % n_tiles if n_tiles > 0 else ""
	if rid.begins_with("region_"):
		var num := rid.substr("region_".length())
		if num.is_valid_int():
			title = "地区 %d" % num.to_int()
	_title_bar.set_content("L2", title, subtitle)


## 视图整体显隐（Content + HUD + 指示器 + 名牌）——L3 控制器联动关闭/恢复时调用，
## 与 open() 内的显隐逻辑保持一致（M 关闭重开、下钻切换都同步粒度指示器）
func set_view_visible(v: bool) -> void:
	visible = v
	if _hud != null:
		_hud.visible = v
	if _indicator != null:
		_indicator.visible = v
	if _title_bar != null:
		_title_bar.visible = v


func get_current_region_id() -> String:
	return _current_region_id


## 地图模式变更（B4 广播）：转发渲染器（地形底图/政权叠加层数据落地前仅记录模式）
func _on_map_mode_changed(_mode: int) -> void:
	if map_renderer != null and map_renderer.has_method("set_map_mode"):
		map_renderer.set_map_mode(MapModeManager.current_mode)
