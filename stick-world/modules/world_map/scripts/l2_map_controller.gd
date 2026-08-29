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

var _current_region_id: String = ""


func _ready() -> void:
	_auto_find_components()
	# 层号统一走 LayerOrder 常量（本节点是 CanvasLayer 的 Content 子节点）
	var canvas := get_parent() as CanvasLayer
	if canvas != null:
		canvas.layer = LayerOrder.STRATEGIC_L2
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)


## 注入 L1 下钻视图（由接线方调用）
func set_l1_view(view: Node) -> void:
	l1_view = view


func _auto_find_components() -> void:
	for child in get_children():
		if child is L2MapRenderer and map_renderer == null:
			map_renderer = child
		elif child is MapCamera and map_camera == null:
			map_camera = child
	if _hud == null:
		var layer := get_parent()
		if layer != null:
			_hud = layer.get_node_or_null("ZoomIndicator")


func _input(event: InputEvent) -> void:
	# 用自身 visible（headless 下 is_visible_in_tree 因窗口不可见恒 false）
	if not visible:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_handle_l1_click(mb.position)
	if event is InputEventKey and event.pressed:
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			# ESC 返回 L3（地图整体仍开着，不关地图、不恢复场景图输入）
			visible = false
			if _hud != null:
				_hud.visible = false
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
	visible = false
	if _hud != null:
		_hud.visible = false


## L1 返回（ESC）：恢复 L2 显示
func _on_l1_back() -> void:
	visible = true
	if _hud != null:
		_hud.visible = true


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
	if _hud != null:
		_hud.visible = true


func get_current_region_id() -> String:
	return _current_region_id
