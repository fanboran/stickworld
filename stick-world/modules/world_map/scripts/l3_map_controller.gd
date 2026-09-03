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


## 打开 L3 地图（M 键触发）
## 保留上次状态：相机位置/缩放不变；若上次关闭时在 L2 视图内，恢复 L2 显示
func open() -> void:
	if not _view_initialized:
		_view_initialized = true
		# 初始视角：默认缩放 0.36（看更大范围），屏幕中心 = 地图中心
		var map_size := 2048.0
		if map_renderer != null and map_renderer.get_data() != null:
			map_size = float(map_renderer.get_data().size)
		if map_camera != null and map_camera.has_method("set_zoom"):
			var vp := get_viewport()
			if vp != null:
				var vp_size: Vector2 = vp.get_visible_rect().size
				map_camera.set_zoom(0.36)
				# 默认缩放 0.36 = 100%（HUD 百分比按此归一化显示）
				if _zoom_indicator != null and _zoom_indicator.has_method("set_default_zoom"):
					_zoom_indicator.set_default_zoom(0.36)
				if map_camera.has_method("set_offset"):
					map_camera.set_offset(vp_size * 0.5 - Vector2(map_size * 0.36 * 0.5, map_size * 0.36 * 0.5))
	if _l2_active and l2_view != null:
		# 恢复 L2 视图（相机状态保留），L3 保持隐藏（指示条隐藏）
		visible = false
		if _zoom_indicator != null:
			_zoom_indicator.visible = false
		if _indicator != null:
			_indicator.visible = false
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


## 关闭 L3 地图（ESC / M 键）
func close() -> void:
	if _zoom_indicator != null:
		_zoom_indicator.visible = false
	if _indicator != null:
		_indicator.visible = false
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
