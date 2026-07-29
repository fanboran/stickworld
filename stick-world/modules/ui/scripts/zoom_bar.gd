class_name ZoomBar
extends Control
## 缩放条 -- 小地图下方的相机缩放滑块。
##
## 宽度与小地图对齐，滑块占左侧，右侧显示缩放百分比。
## 支持拖动滑块和滚轮缩放双向同步。

const BAR_WIDTH: float = 240.0
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


## 锚定到小地图下方（屏幕上方中央，y=88）
func _anchor_below_minimap() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	var vp_w: float = get_viewport_rect().size.x
	var pos_x: float = (vp_w - BAR_WIDTH) * 0.5
	position = Vector2(pos_x, 88.0)
	size = Vector2(BAR_WIDTH, BAR_HEIGHT)


func _build_ui() -> void:
	# 滑块（占左侧，留出右侧标签空间）
	_slider = HSlider.new()
	_slider.min_value = 0.5
	_slider.max_value = 2.0
	_slider.step = 0.1
	_slider.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_slider.offset_right = BAR_WIDTH - LABEL_WIDTH
	_slider.offset_bottom = BAR_HEIGHT
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	# 百分比标签（右侧，右对齐）
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_label.offset_left = -LABEL_WIDTH
	_label.offset_right = 0.0
	_label.offset_bottom = BAR_HEIGHT
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
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
