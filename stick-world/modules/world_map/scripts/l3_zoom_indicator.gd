extends Control
class_name MapHUD
## 战略图底部 HUD：缩放条（HSlider + 百分比）+ 细分模式按钮（仅 L3）。
## 通用组件：L3 / L2 场景共用（Content 下有带 toggle_display_mode 的渲染器才显示按钮）。
##
## 组件化（与全局 UI 一致）：
##   - 按钮 = 主题 Button（StickTheme/StickKit），不再是自绘矩形
##   - 缩放条 = 主题 HSlider + 百分比 Label（默认缩放 = 100%，可拖动与滚轮双向同步）
## 布局：左下角单行 [细分按钮] [缩放条] [百分比]，互不重叠；根节点 PASS 鼠标，
## 仅按钮/滑块/标签接收输入，不挡地图拖拽/下钻。
##
## 缩放归一化：控制器 open() 时调用 set_default_zoom(初始缩放)，此后显示
## 当前缩放相对默认缩放的百分比（默认 = 100%）。

const H := 56.0

const BTN_W := 150.0
const BTN_H := StickTokens.BTN_H
const SLIDER_W := 240.0
const SLIDER_H := 28.0
const LABEL_W := 60.0
## 控件间距（设计语言五档 4/6/8/12/16 取 12）
const GAP := 12.0

## 滑块允许的缩放倍数范围（相对默认缩放）
const MIN_MULT := 0.5
const MAX_MULT := 3.0

var _camera: Node = null
var _renderer: Node = null

## 默认缩放（该视图首次打开时的初始缩放 = 100%）
var default_zoom: float = 1.0

var _mode_btn: Button = null
var _slider: HSlider = null
var _zoom_label: Label = null
var _ruler: ColorRect = null

## 滑块范围（min/max）变更时置位，抑制 range clamp 触发的 value_changed 反向写相机
var _block_slider_signal := false


func _ready() -> void:
	theme = StickTheme.create()
	var layer := get_parent()
	if layer != null:
		var content := layer.get_node_or_null("Content")
		if content != null:
			_camera = content.get_node_or_null("MapCamera")
			# 查找带 toggle_display_mode 的渲染器（L3 有 = 显示细分按钮；L2 无 = 恒城市模式）
			for ch in content.get_children():
				if ch.has_method("toggle_display_mode"):
					_renderer = ch
					break
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -H
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_widgets()


## 设置默认缩放（该视图初始缩放 = 100%），由控制器 open() 时调用
func set_default_zoom(z: float) -> void:
	if z <= 0.0:
		return
	default_zoom = z
	if _slider != null:
		_block_slider_signal = true
		_slider.min_value = default_zoom * MIN_MULT
		_slider.max_value = default_zoom * MAX_MULT
		# 直接落到当前相机缩放，避免 range clamp 触发 value_changed 反向写相机
		var cur: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else z
		_slider.set_value_no_signal(clampf(cur, _slider.min_value, _slider.max_value))
		_block_slider_signal = false
	_update_label()
	_update_ruler()


func _build_widgets() -> void:
	var x: float = StickTokens.SCREEN_MARGIN
	# 细分模式按钮（仅 L3 有 toggle_display_mode）
	if _renderer != null and _renderer.has_method("toggle_display_mode"):
		_mode_btn = StickKit.button(self, "细分:关", _on_mode_pressed,
				StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		_mode_btn.custom_minimum_size = Vector2(BTN_W, BTN_H)
		_dock_bottom_left(_mode_btn, x, BTN_W, BTN_H)
		_update_mode_text()
		x += BTN_W + GAP
	# 缩放滑块
	_slider = HSlider.new()
	_slider.min_value = default_zoom * MIN_MULT
	_slider.max_value = default_zoom * MAX_MULT
	_slider.step = 0.001
	_slider.custom_minimum_size = Vector2(SLIDER_W, SLIDER_H)
	_slider.mouse_filter = Control.MOUSE_FILTER_STOP
	# 先把滑块值落在范围内再接信号：避免初始 value=0 被 min clamp 触发 set_zoom 干扰相机
	_slider.set_value_no_signal(clampf(default_zoom, _slider.min_value, _slider.max_value))
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)
	_dock_bottom_left(_slider, x, SLIDER_W, SLIDER_H)
	# 百分比标签
	_zoom_label = Label.new()
	_zoom_label.custom_minimum_size = Vector2(LABEL_W, SLIDER_H)
	_zoom_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_zoom_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_zoom_label)
	_dock_bottom_left(_zoom_label, x + SLIDER_W + GAP, LABEL_W, SLIDER_H)
	_update_label()
	# 100% 刻度（叠在滑块内底部，对准 grabber 中心）
	_ruler = ColorRect.new()
	_ruler.color = Color(StickTokens.ACCENT, 0.75)
	_ruler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ruler)
	_update_ruler()


## 停靠到控件左下角（距左下 SCREEN_MARGIN，与屏幕安全边距一致）
func _dock_bottom_left(node: Control, x: float, w: float, h: float) -> void:
	node.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	node.offset_left = x
	node.offset_top = -StickTokens.SCREEN_MARGIN - h
	node.offset_right = x + w
	node.offset_bottom = -StickTokens.SCREEN_MARGIN


func _update_ruler() -> void:
	if _ruler == null or _slider == null:
		return
	var grabber := _slider.get_theme_icon("grabber", "HSlider")
	var gw: float = grabber.get_width() if grabber != null else 16.0
	var nrm := clampf((default_zoom - _slider.min_value) / (_slider.max_value - _slider.min_value), 0.0, 1.0)
	var tick_x := nrm * (SLIDER_W - gw) + gw * 0.5
	_ruler.position = _slider.position + Vector2(tick_x - 1.0, SLIDER_H - 5.0)
	_ruler.size = Vector2(2.0, 4.0)


func _on_mode_pressed() -> void:
	if _renderer != null and _renderer.has_method("toggle_display_mode"):
		_renderer.toggle_display_mode()
		_update_mode_text()


func _update_mode_text() -> void:
	if _mode_btn == null or _renderer == null:
		return
	var on: bool = _renderer.has_method("get_mode_name") and _renderer.get_mode_name() == "城市"
	_mode_btn.text = "细分:开" if on else "细分:关"


func _on_slider_changed(value: float) -> void:
	if _block_slider_signal:
		return
	if _camera != null and _camera.has_method("set_zoom"):
		_camera.set_zoom(value)
	_update_label()


func _update_label() -> void:
	if _zoom_label == null:
		return
	var zoom: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else default_zoom
	_zoom_label.text = "%d%%" % int(roundf(zoom / default_zoom * 100.0))


## 滚轮缩放后同步滑块 + 百分比
func _process(_delta: float) -> void:
	if not is_visible_in_tree() or _slider == null or _camera == null:
		return
	if not _camera.has_method("get_zoom"):
		return
	var z: float = _camera.get_zoom()
	if absf(_slider.value - z) > 0.0005:
		_slider.set_value_no_signal(z)
	_update_label()
