class_name ZoomBar
extends Control
## 缩放条 -- 小地图下方的相机缩放滑块。
##
## 显示当前缩放倍率，支持拖动滑块和滚轮缩放双向同步。

const BAR_WIDTH: float = 240.0
const BAR_HEIGHT: float = 36.0

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
	# 滑块
	_slider = HSlider.new()
	_slider.min_value = 0.5
	_slider.max_value = 2.0
	_slider.step = 0.1
	_slider.anchors_preset = Control.PRESET_TOP_WIDE
	_slider.offset_bottom = 18.0
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	# 标签
	_label = Label.new()
	_label.anchors_preset = Control.PRESET_BOTTOM_WIDE
	_label.offset_top = -18.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.text = "1.0x"
	add_child(_label)


func _on_slider_changed(value: float) -> void:
	if _camera_rig != null and _camera_rig.has_method("set_user_zoom"):
		_camera_rig.set_user_zoom(value)
	_update_label()


func _update_label() -> void:
	if _label == null:
		return
	if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
		_label.text = "%.1fx" % _camera_rig.get_user_zoom()


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
