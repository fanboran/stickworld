class_name ZoomBar
extends HBoxContainer
## 缩放条 —— 顶部中央小地图正下方的相机缩放滑块（top_center stack，见 hud_zone_layout.gd）。
##
## 薄消费壳：机件（滑条/滚轮/拖动双向同步 + 百分比标签）全部在公共组件
## ZoomSlider（同目录 zoom_slider.gd），本类只声明顶层缩放条的领域配置——
## 显示百分比域与 user_zoom 换算。定位归 zone：由装配层经 UIRoot.place_in_zone
## 落位，本部件只声明体量（custom_minimum_size），不自算屏幕坐标。

## 滑块宽度（体量声明，与小地图保留区同宽量级）
const BAR_WIDTH: float = 360.0
const BAR_HEIGHT: float = 24.0
## 右侧百分比标签宽度
const LABEL_WIDTH: float = 48.0
## 缩放滑块量程：**显示百分比域，整 10 档**（创始人 2026-09-16"缩放的最大
## 最小范围变成整10"）——70%~260%、步进 10%，20 档；user_zoom = 显示% ×
## ZOOM_BASE / 100（70%→0.7 / 260%→2.6，均在 CameraRig 夹制 [0.6667, 2.6667]
## 内；100% 默认档恰在刻度上）。滚轮缩放仍走 CameraRig 步进，句柄按最近
## 整 10 刻度吸附，标签读相机真实值。
## ui_global 禁止反向依赖 world 模块，CameraRig.ZOOM_* 不取，夹制由其自身保证。
const DISPLAY_MIN: float = 70.0
const DISPLAY_MAX: float = 260.0
const DISPLAY_STEP: float = 10.0
## 显示基准档：user_zoom=1.0（HD-2D 构图契约默认档，CameraRig 同值镜像）
## 显示为 100%（创始人 2026-09-15：默认档的数字映射为 100%；24px 换轨后
## 基准档由旧轨 0.75 折入世界常量、归一为 1.0）。
const ZOOM_BASE: float = 1.0

var _zoom: ZoomSlider = null
var _camera_rig: Node = null


func _ready() -> void:
	# 体量声明（坐标由 zone 表计算，见 hud_zone_layout.gd）
	custom_minimum_size = Vector2(BAR_WIDTH + 4.0 + LABEL_WIDTH, BAR_HEIGHT)


## 由 GameRoot 调用，注入相机引用并构建 UI。
func setup(camera_rig: Node) -> void:
	_camera_rig = camera_rig
	_build_ui()
	_zoom.sync_now()


func _build_ui() -> void:
	_zoom = ZoomSlider.new()
	_zoom.slider_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	_zoom.label_width = LABEL_WIDTH
	_zoom.separation = 4
	_zoom.sync_epsilon = 0.05
	_zoom.get_display_value = func() -> float:
		if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
			return _camera_rig.get_user_zoom() / ZOOM_BASE * 100.0
		return 100.0
	_zoom.apply_display = func(v: float) -> void:
		if _camera_rig != null and _camera_rig.has_method("set_user_zoom"):
			_camera_rig.set_user_zoom(v / 100.0 * ZOOM_BASE)
	_zoom.format_percent = func(_display: float) -> String:
		if _camera_rig != null and _camera_rig.has_method("get_user_zoom"):
			return "%d%%" % int(round(_camera_rig.get_user_zoom() / ZOOM_BASE * 100))
		return "100%"
	add_child(_zoom)
	# 滑块量程=显示百分比域（整 10 档）：旧 user_zoom 域 0.5~2.0 换算显示
	# 66.7%~266.7%，端点非整 10（创始人 2026-09-16）。拖动改相机 user_zoom
	# = 显示%×ZOOM_BASE/100，量程始终覆盖 CameraRig 夹制区间。
	# set_range 屏蔽量程 clamp 触发的 value_changed，装配不写相机
	_zoom.set_range(DISPLAY_MIN, DISPLAY_MAX, DISPLAY_STEP)
	# 缩放档位刻度：70~260 每 10 一档 = 20 档（默认 100% 恰落在刻度上）；
	# 刻度渲染由 SketchHSlider 自绘接管
	_zoom.slider.tick_count = int((DISPLAY_MAX - DISPLAY_MIN) / DISPLAY_STEP) + 1
