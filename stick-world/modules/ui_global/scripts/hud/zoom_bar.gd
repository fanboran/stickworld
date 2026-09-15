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
## 缩放滑块量程：**显示百分比域，整 10 档**（创始人 2026-09-16"缩放的最大
## 最小范围变成整10"）——70%~260%、步进 10%，20 档；user_zoom = 显示% ×
## ZOOM_BASE / 100（70%→0.525 / 260%→1.95，均在 CameraRig 夹制 [0.5, 2.0]
## 内；100% 默认档恰在刻度上）。滚轮缩放仍走 CameraRig 步进，句柄按最近
## 整 10 刻度吸附，标签读相机真实值。
## ui_global 禁止反向依赖 world 模块，CameraRig.ZOOM_* 不取，夹制由其自身保证。
const DISPLAY_MIN: float = 70.0
const DISPLAY_MAX: float = 260.0
const DISPLAY_STEP: float = 10.0
## 显示基准档：user_zoom=0.75（HD-2D 构图契约默认档，CameraRig 同值镜像）
## 显示为 100%（创始人 2026-09-15：缩放条 75% 的数字映射为 100%）。
const ZOOM_BASE: float = 0.75

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
		sync_from_camera()


func _build_ui() -> void:
	# 滑块：条本体宽 = BAR_WIDTH，水平排列由容器管理（无手写 offset）
	_slider = SketchHSlider.new()
	_slider.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	# 滑块量程=显示百分比域（整 10 档）：旧 user_zoom 域 0.5~2.0 换算显示
	# 66.7%~266.7%，端点非整 10（创始人 2026-09-16）。拖动改相机 user_zoom
	# = 显示%×ZOOM_BASE/100，量程始终覆盖 CameraRig 夹制区间
	_slider.min_value = DISPLAY_MIN
	_slider.max_value = DISPLAY_MAX
	_slider.step = DISPLAY_STEP
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	# 缩放档位刻度：70~260 每 10 一档 = 20 档（默认 100% 恰落在刻度上）；
	# 刻度渲染由 SketchHSlider 自绘接管
	_slider.tick_count = int((DISPLAY_MAX - DISPLAY_MIN) / DISPLAY_STEP) + 1
	# 百分比标签：条右侧
	_label = Label.new()
	_label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.text = "100%"
	add_child(_label)


func _on_slider_changed(value: float) -> void:
	# value = 显示百分比（整 10 档）→ 换算相机 user_zoom
	if _camera_rig != null and _camera_rig.has_method("set_user_zoom"):
		_camera_rig.set_user_zoom(value / 100.0 * ZOOM_BASE)
	_update_label()


func _update_label() -> void:
	if _label == null:
		return
	if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
		_label.text = "%d%%" % int(round(_camera_rig.get_user_zoom() / ZOOM_BASE * 100))


## 滚轮缩放后由 GameRoot 调用，同步滑块位置（句柄吸附最近整 10 刻度）
func sync_from_camera() -> void:
	if _slider == null or _camera_rig == null or not _camera_rig.has_method("get_user_zoom"):
		return
	var display: float = _camera_rig.get_user_zoom() / ZOOM_BASE * 100.0
	if absf(_slider.value - display) > 0.05:
		_slider.set_value_no_signal(display)
		_update_label()


func _process(_delta: float) -> void:
	sync_from_camera()
