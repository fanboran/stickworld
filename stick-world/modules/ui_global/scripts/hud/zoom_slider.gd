class_name ZoomSlider
extends HBoxContainer
## 公共缩放条 —— SketchHSlider + 百分比 Label 的双向同步机件（ui_global L1 组件）。
##
## 语义 = 两处消费场景（顶层 HUD ZoomBar / 战略图 MapHUD）的并集：滑条拖动写相机、
## 滚轮/外部缩放经每帧回流拉回滑条与百分比标签，双向同步。差异全部参数化：
##   - 体量：slider_size / label_width / separation（HBox 间距）
##   - 显示域与步进：宿主直接设 slider.min_value/max_value/step/tick_count
##   - 值换算与文案：三个 Callable 注入（见下），本组件不认识相机
## 定位归宿主（zone 表或 dock），本组件只管排布自身两个子控件。


## 子控件体量（滑条 min size；标签 min = label_width × slider_size.y）
var slider_size := Vector2(240.0, 28.0)
## 百分比标签宽
var label_width := 60.0
## 滑条与标签间距
var separation := 12
## 每帧回流容差：源值与滑条值差小于该值不重设（防抖动）
var sync_epsilon := 0.05

## () -> float：读取源（相机）值并换算到显示域。空则不做回流同步。
var get_display_value := Callable()
## (display: float) -> void：滑条值（显示域）写回源（相机）。空则拖动只刷标签。
var apply_display := Callable()
## (display: float) -> String：显示域值 → 标签文案（各场景口径不同，如读相机真实值）。
var format_percent := Callable()

var slider: SketchHSlider = null
var label: Label = null

## set_range 期间置位：吞掉量程 clamp 触发的 value_changed（Range 设 min/max 会
## clamp value 并发信号，装配/换域时不许把 clamp 中间值写回相机）
var _block := false


func _ready() -> void:
	add_theme_constant_override("separation", separation)
	slider = SketchHSlider.new()
	slider.custom_minimum_size = slider_size
	slider.mouse_filter = Control.MOUSE_FILTER_STOP
	slider.value_changed.connect(_on_slider_changed)
	add_child(slider)
	label = Label.new()
	label.custom_minimum_size = Vector2(label_width, slider_size.y)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


## 设滑块量程（含屏蔽 clamp 触发的 value_changed）。
## step_v / value_v 传 NAN 表示保持不变；value_v 自动夹进新量程且不写回相机。
## 须在子控件就绪后调用（宿主先 add_child 再配置）。
func set_range(min_v: float, max_v: float, step_v: float = NAN, value_v: float = NAN) -> void:
	if slider == null:
		push_warning("[ZoomSlider] set_range 在 _ready 前调用，已忽略（先 add_child 再配置）")
		return
	_block = true
	slider.min_value = min_v
	slider.max_value = max_v
	if not is_nan(step_v):
		slider.step = step_v
	if not is_nan(value_v):
		slider.set_value_no_signal(clampf(value_v, min_v, max_v))
	_block = false


func _on_slider_changed(value: float) -> void:
	if _block:
		return
	if apply_display.is_valid():
		apply_display.call(value)
	_refresh_label(value)


## 每帧回流：源值（换算显示域）拉回滑条与标签（滚轮/外部缩放后的同步路径）
func _process(_delta: float) -> void:
	if not is_visible_in_tree() or not get_display_value.is_valid():
		return
	var display: float = get_display_value.call()
	if slider != null and absf(slider.value - display) > sync_epsilon:
		slider.set_value_no_signal(display)
	_refresh_label(display)


func _refresh_label(display: float) -> void:
	if label != null and format_percent.is_valid():
		label.text = format_percent.call(display)


## 立即刷新标签（读源值换算；量程变更后即时对齐用）
func refresh_label() -> void:
	if get_display_value.is_valid():
		_refresh_label(get_display_value.call())


## 立即回流一次（构建后首次对齐用；平时由 _process 驱动）
func sync_now() -> void:
	if get_display_value.is_valid():
		var display: float = get_display_value.call()
		if slider != null and absf(slider.value - display) > sync_epsilon:
			slider.set_value_no_signal(display)
		_refresh_label(display)
