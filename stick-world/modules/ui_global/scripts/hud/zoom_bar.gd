class_name ZoomBar
extends HBoxContainer
## 缩放条 —— 顶部中央小地图正下方的相机缩放滑块（top_center stack，见 hud_zone_layout.gd）。
##
## 滑块占左侧，右侧显示缩放百分比。支持拖动滑块和滚轮缩放双向同步。
## 定位归 zone：由装配层经 UIRoot.place_in_zone 落位，本部件只声明体量
## （custom_minimum_size = 滑块 + 间距 + 标签），不自算屏幕坐标。

## 滑块宽度（体量声明，与小地图保留区同宽量级）
const BAR_WIDTH: float = 360.0
const BAR_HEIGHT: float = 24.0
## 右侧百分比标签宽度
const LABEL_WIDTH: float = 48.0
## 缩放范围与档位（与 CameraRig.ZOOM_* 同值——ui_global 禁止反向依赖 world 模块，
## 取不了其常量，此处为 UI 侧镜像；刻度 0.5~2.0 每 0.1 一档 = 16 档，默认 100% 恰落在刻度上）
const ZOOM_MIN: float = 0.5
const ZOOM_MAX: float = 2.0
const ZOOM_STEP: float = 0.1

var _slider: HSlider = null
var _label: Label = null
var _camera_rig: Node = null


func _ready() -> void:
	# 体量声明（坐标由 zone 表计算，见 hud_zone_layout.gd）
	custom_minimum_size = Vector2(BAR_WIDTH + 4.0 + LABEL_WIDTH, BAR_HEIGHT)
	add_theme_constant_override("separation", 4)


## 由 GameRoot 调用，注入相机引用并构建 UI。
func setup(camera_rig: Node) -> void:
	_camera_rig = camera_rig
	_build_ui()
	if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
		_slider.set_value_no_signal(_camera_rig.get_user_zoom())
		_update_label()


func _build_ui() -> void:
	# 滑块：条本体宽 = BAR_WIDTH，水平排列由容器管理（无手写 offset）
	_slider = SketchHSlider.new()
	_slider.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	# 滑块量程必须对齐相机 user_zoom 域：HSlider 默认 0~100，不设则相机值
	# 0.5~2.0 只占量程 1%~2%（手柄滚轮缩放几乎不动的根因），拖动则被 clamp 瞬跳
	_slider.min_value = ZOOM_MIN
	_slider.max_value = ZOOM_MAX
	_slider.step = ZOOM_STEP
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	# 缩放档位刻度：原生 tick_count 机制（0.5~2.0 每 0.1 一档 = 16 档，
	# 默认 100% 恰落在刻度上）；刻度渲染由 SketchHSlider 自绘接管
	_slider.tick_count = 16
	# 百分比标签：条右侧
	_label = Label.new()
	_label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
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
