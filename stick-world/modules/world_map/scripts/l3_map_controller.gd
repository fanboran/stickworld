extends Node2D
class_name L3MapController
## L3 大世界战略图控制器（M 键）—— 与 L1（Tab）独立
##
## 交互：
##   - M 键打开/关闭（由 SystemSetup 接线）
##   - ESC 关闭
##   - 单击地区 -> 下钻 L2 详细地图（打开 L2 视图并隐藏自身）
##   - 拖拽/滚轮缩放（MapCamera）
##   - hover 高亮地区（渲染器处理）

## L2 下钻视图（由 SystemSetup 装配时注入）
@export var l2_view: L2MapController = null

@export var map_renderer: L3MapRenderer
@export var map_camera: MapCamera

## 缩放指示条（CanvasLayer 直接子节点，open/close 同步显隐）
var _zoom_indicator: Control = null

## 粒度指示器（CanvasLayer 直接子节点，显隐由本控制器同步；open 时更新文案）
var _indicator: GranularityIndicator = null

## 视图名牌（CanvasLayer 直接子节点，同批显隐；open 时喂"大世界 · N 地区"）
var _title_bar: MapTitleBar = null

## 全屏海洋背景（CanvasLayer 首个子节点，z 最低）。显隐跟 M 会话而非 Content：
## 下钻 L2 时保留（L2 层号 102 更高，内容盖在其上，下钻仍在全屏海洋会话内）
var _ocean_background: Control = null

## 全屏初始缩放的上下限位余量（屏幕像素）：初始地图高度 = 视口高 + 2×余量，
## 打开即满足"上下边界不进屏"，同时作为相机 min_zoom 的锁定值（再缩小边界必进屏）
const FIT_BUFFER := 64.0

## 首次打开时设置初始视角（之后保留用户位置/缩放状态）
var _view_initialized: bool = false

## 当前是否在 L2 视图内（M 关闭/重开时保留）
var _l2_active: bool = false


func _ready() -> void:
	_auto_find_components()
	# 层号统一走 LayerOrder 常量（本节点是 CanvasLayer 的 Content 子节点）
	var canvas := get_parent() as CanvasLayer
	if canvas != null:
		canvas.layer = LayerOrder.STRATEGIC_L3
	# 渲染器悬停检测需要相机做屏幕->地图坐标换算
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)
	# 视图互斥（L1 层号 100 低于 L3 的 101，L1 打开会整个被盖住）：Tab 打开 L1 时
	# （唯一发 strategic_map_opened 的路径）本视图若仍可见则一并收起，保证
	# "新打开的视图 = 玩家看到的视图"；L3 收起连带 L2（close 内已处理）
	if EventBus != null and not EventBus.strategic_map_opened.is_connected(_on_l1_opened):
		EventBus.strategic_map_opened.connect(_on_l1_opened)


## L1（Tab）打开：本视图（含下钻中的 L2）自动收起，避免被盖住的隐形视图
func _on_l1_opened() -> void:
	if visible or (l2_view != null and l2_view.visible):
		close()


## 注入 L2 下钻视图（由 SystemSetup 装配时调用，晚于 _ready）
func set_l2_view(view: L2MapController) -> void:
	l2_view = view
	if l2_view != null and not l2_view.back_requested.is_connected(_on_l2_back):
		l2_view.back_requested.connect(_on_l2_back)


func _auto_find_components() -> void:
	if map_renderer == null:
		map_renderer = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is L3MapRenderer) as L3MapRenderer
	if map_camera == null:
		map_camera = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapCamera) as MapCamera
	# 缩放指示条 + 粒度指示器（CanvasLayer 直接子节点；Control 挂 Node2D 下 anchor 会跑位）
	if _zoom_indicator == null:
		_zoom_indicator = MapControllerUtil.find_sibling(self, "ZoomIndicator")
	if _indicator == null:
		_indicator = MapControllerUtil.find_sibling(self, "GranularityIndicator") as GranularityIndicator
	if _title_bar == null:
		_title_bar = MapControllerUtil.find_sibling(self, "MapTitleBar") as MapTitleBar
	if _ocean_background == null:
		_ocean_background = MapControllerUtil.find_sibling(self, "OceanBackground")


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed:
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		elif key.keycode == KEY_N:
			# N：细分开关（L1 <-> 城市预览效果）
			if map_renderer != null and map_renderer.has_method("toggle_display_mode"):
				map_renderer.toggle_display_mode()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if _try_open_l2_at_screen(event.position):
			get_viewport().set_input_as_handled()


## 旧的 389 细胞 L1 蒙版叠加（V 键）已废弃移除——1986 由 city_split_v2 在老 L1 下重建城市层，
## L1 蒙版展示待接老 L1（legacy_l1_labels）后恢复


## 单击：屏幕坐标 -> 地图坐标 -> 命中地区 -> 下钻 L2
func _try_open_l2_at_screen(screen_pos: Vector2) -> bool:
	if map_camera == null or not map_camera.has_method("screen_to_map") \
			or map_renderer == null or map_renderer.get_data() == null:
		return false
	var map_pos: Vector2 = map_camera.screen_to_map(screen_pos)
	var data: L3WorldData = map_renderer.get_data()
	# 渲染坐标（8192 级网格）-> 索引图坐标（2048 级查询）
	if data.mask_image != null and data.size > 0:
		map_pos *= float(data.mask_image.get_width()) / float(data.size)
	var query: Dictionary = data.query_at_map_pos(map_pos)
	var region: Dictionary = query.get("region", {})
	var label: int = int(region.get("label", 0))
	if label <= 0:
		return false
	_open_l2(label)
	return true


## 下钻 L2：隐藏自身（状态保留）与 L3 HUD，打开 L2 视图
func _open_l2(label: int) -> void:
	if l2_view == null:
		return
	_l2_active = true
	visible = false
	if _zoom_indicator != null:
		_zoom_indicator.visible = false
	if _indicator != null:
		_indicator.visible = false  # L2 有自己的指示器
	if _title_bar != null:
		_title_bar.visible = false  # L2 有自己的名牌
	l2_view.open("region_%03d" % label)


## L2 返回（ESC）：恢复 L3 显示
func _on_l2_back() -> void:
	_l2_active = false
	visible = true
	if _zoom_indicator != null:
		_zoom_indicator.visible = true
	if _indicator != null:
		_indicator.set_view("L3")
		_indicator.visible = true
	if _title_bar != null:
		_update_title_bar()
		_title_bar.visible = true


## 打开 L3 地图（M 键触发）—— 全屏海洋底（场景图不再透出）
## 保留上次状态：相机位置/缩放不变；若上次关闭时在 L2 视图内，恢复 L2 显示
func open() -> void:
	_set_ocean_background_visible(true)
	if not _view_initialized:
		_view_initialized = true
		var map_size := 2048.0
		if map_renderer != null and map_renderer.get_data() != null:
			map_size = float(map_renderer.get_data().size)
		if map_camera != null and map_camera.has_method("set_zoom"):
			var vp := get_viewport()
			if vp != null:
				var vp_size: Vector2 = vp.get_visible_rect().size
				# 全屏适配缩放：地图高度 = 视口高 + 上下限位余量（初始即"边界不进屏"，
				# 余量外是同色海洋背景，全屏观感）。同时锁定 min_zoom——再缩小则上下
				# 边界必然进入屏幕，与限位目标矛盾
				var fit_zoom: float = (vp_size.y + FIT_BUFFER * 2.0) / map_size
				map_camera.min_zoom = fit_zoom
				map_camera.set_zoom(fit_zoom)
				# 全屏适配 = 100%（HUD 百分比按此归一化显示）
				if _zoom_indicator != null and _zoom_indicator.has_method("set_default_zoom"):
					_zoom_indicator.set_default_zoom(fit_zoom)
				# 相机限位：上下严格（边界外扩余量不进屏）/ 左右宽松（宽屏下地图窄于
				# 视口时两侧露出同色海洋，仅防地图被完全移出屏幕）
				if map_camera.has_method("set_viewport_clamp"):
					map_camera.set_viewport_clamp(MapCamera.ClampMode.CLAMP_LOOSE,
							MapCamera.ClampMode.CLAMP_STRICT,
							Rect2(0.0, 0.0, map_size, map_size), FIT_BUFFER)
				if map_camera.has_method("set_offset"):
					# 初始地图居中（上下各留余量在屏外，左右居中对称）
					map_camera.set_offset(vp_size * 0.5 - Vector2(map_size, map_size) * fit_zoom * 0.5)
	if _l2_active and l2_view != null:
		# 恢复 L2 视图（相机状态保留），L3 保持隐藏（指示条隐藏）
		visible = false
		if _zoom_indicator != null:
			_zoom_indicator.visible = false
		if _indicator != null:
			_indicator.visible = false
		if _title_bar != null:
			_title_bar.visible = false
		if l2_view.has_method("set_view_visible"):
			l2_view.call("set_view_visible", true)  # 含 L2 的 HUD/指示器
		else:
			l2_view.visible = true
	else:
		visible = true
		if _zoom_indicator != null:
			_zoom_indicator.visible = true
		if _indicator != null:
			_indicator.set_view("L3")
			_indicator.visible = true
		if _title_bar != null:
			_update_title_bar()
			_title_bar.visible = true


## 关闭 L3 地图（ESC / M 键）—— 收起海洋背景，回场景图
func close() -> void:
	_set_ocean_background_visible(false)
	if _zoom_indicator != null:
		_zoom_indicator.visible = false
	if _indicator != null:
		_indicator.visible = false
	if _title_bar != null:
		_title_bar.visible = false
	# 若在 L2 视图内，一起隐藏（保留状态，重开时恢复）
	if l2_view != null and l2_view.visible:
		if l2_view.has_method("set_view_visible"):
			l2_view.call("set_view_visible", false)  # 含 L2 的 HUD/指示器
		else:
			l2_view.visible = false
	visible = false
	# 通知 system_setup 恢复场景图输入
	if EventBus != null:
		EventBus.strategic_map_closed.emit()


## 名牌内容：大世界 + 地区数概览（数据未加载时降级只显名称）
func _update_title_bar() -> void:
	if _title_bar == null:
		return
	var n_regions: int = 0
	if map_renderer != null and map_renderer.get_data() != null:
		n_regions = map_renderer.get_data().regions.size()
	var subtitle := "%d 地区" % n_regions if n_regions > 0 else ""
	_title_bar.set_content("L3", "大世界", subtitle)


## 海洋背景显隐（open/close 调用；下钻 L2 / L2 返回不调用 = 会话内常显）
func _set_ocean_background_visible(v: bool) -> void:
	if _ocean_background != null:
		_ocean_background.visible = v
