class_name ZoomBar
extends Control
## 缩放条 -- 小地图下方的相机缩放滑块。
##
## 宽度与小地图对齐，滑块占左侧，右侧显示缩放百分比。
## 支持拖动滑块和滚轮缩放双向同步。

const BAR_WIDTH: float = UIAPI.HUD_MINIMAP_WIDTH
const BAR_HEIGHT: float = 24.0
## 右侧百分比标签宽度
const LABEL_WIDTH: float = 48.0

var _slider: HSlider = null
var _label: Label = null
var _camera_rig: Node = null


## 由 GameRoot 调用，注入相机引用并构建 UI。
func setup(camera_rig: Node) -> void:
	_camera_rig = camera_rig
	_anchor_below_minimap()
	_build_ui()
	if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
		_slider.set_value_no_signal(_camera_rig.get_user_zoom())
		_update_label()


## 锚定到小地图下方（屏幕上方中央，y 与 Minimap 对齐见 UIAPI.HUD_*）。
## 条本体（BAR_WIDTH）居中与小地图对齐；右侧额外留出文字区（不占条宽）。
func _anchor_below_minimap() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	var vp_w: float = get_viewport_rect().size.x
	var bar_x: float = (vp_w - BAR_WIDTH) * 0.5
	position = Vector2(bar_x, UIAPI.HUD_ZOOMBAR_Y)
	size = Vector2(BAR_WIDTH + LABEL_WIDTH + 8.0, BAR_HEIGHT)


func _build_ui() -> void:
	# 滑块：条本体宽 = BAR_WIDTH（与小地图同宽对齐），不把文字让进条内
	_slider = SketchHSlider.new()
	_slider.min_value = 0.5
	_slider.max_value = 2.0
	_slider.step = 0.1
	_slider.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_slider.offset_right = BAR_WIDTH
	_slider.offset_bottom = BAR_HEIGHT
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	# 默认缩放（100%）刻度：叠在条内底部（贴近下缘，滑块圆点不覆盖该区域）。
	# 位置按 SketchHSlider 滑块圆心公式对准 1.0（圆心范围 [grab_r, W-grab_r]）
	var grab_r: float = SketchHSlider.grabber_radius(BAR_HEIGHT)
	var tick_x: float = (1.0 - _slider.min_value) / (_slider.max_value - _slider.min_value) \
			* (BAR_WIDTH - grab_r * 2.0) + grab_r
	var ruler := ColorRect.new()
	ruler.color = Color(StickTokens.ACCENT, 0.75)
	ruler.position = Vector2(tick_x - 1.0, BAR_HEIGHT - 5.0)
	ruler.size = Vector2(2.0, 4.0)
	ruler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ruler)
	# 百分比标签：放在条右侧（条宽之外），不与条组成对齐体
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.offset_left = BAR_WIDTH + 4.0
	_label.offset_right = BAR_WIDTH + 4.0 + LABEL_WIDTH
	_label.offset_bottom = BAR_HEIGHT
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.text = "100%"
	add_child(_label)


func _on_slider_changed(value: float) -> void:
	if _camera_rig != null and _camera_rig.has_method("set_user_zoom"):
		_camera_rig.set_user_zoom(value)
	_update_label()


func _update_label() -> void:
	if _label == null:
		return
	if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
		_label.text = "%d%%" % int(round(_camera_rig.get_user_zoom() * 100))


## 滚轮缩放后由 GameRoot 调用，同步滑块位置
func sync_from_camera() -> void:
	if _slider == null or _camera_rig == null or not _camera_rig.has_method("get_user_zoom"):
		return
	var cam_zoom: float = _camera_rig.get_user_zoom()
	if absf(_slider.value - cam_zoom) > 0.001:
		_slider.set_value_no_signal(cam_zoom)
		_update_label()


func _process(_delta: float) -> void:
	sync_from_camera()
