extends Control
class_name MapHUD
## 战略图底部 HUD：地图模式条（地形/政治，B4）+ 缩放条（HSlider + 百分比）+ 细分模式按钮（仅 L3）。
## 通用组件：L1 / L3 / L2 场景共用（Content 下有带 toggle_display_mode 的渲染器才显示细分按钮；
## 挂 MapModeManager 才显示模式条）。
##
## 组件化（与全局 UI 一致）：
##   - 按钮 = 主题 Button（StickTheme/StickKit），不再是自绘矩形
##   - 缩放条 = 主题 HSlider + 百分比 Label（默认缩放 = 100%，可拖动与滚轮双向同步）
## 布局：左下角单行 [地形|政治] [细分按钮] [缩放条] [百分比]，互不重叠；根节点 PASS 鼠标，
## 仅按钮/滑块/标签接收输入，不挡地图拖拽/下钻。
##
## 缩放归一化：控制器 open() 时调用 set_default_zoom(初始缩放)，此后显示
## 当前缩放相对默认缩放的百分比（默认 = 100%）。

const H := 56.0

const BTN_W := 150.0
const BTN_H := StickTokens.BTN_H
## 小号按钮高（模式条全排 + 细分按钮统一用此高度，顶底对齐）
const BTN_H_SM := StickTokens.BTN_H_SM
const MODE_BTN_W := 56.0
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

## 地图模式管理器（同场景 Content 子节点；无则不显示模式条）
var _mode_manager: Node = null
var _mode_group: ButtonGroup = null
var _terrain_btn: Button = null
var _political_btn: Button = null

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
			_mode_manager = content.get_node_or_null("MapModeManager")
			if _mode_manager != null and _mode_manager.has_signal("mode_changed"):
				_mode_manager.mode_changed.connect(_on_map_mode_changed)
			# 查找带 toggle_display_mode 的渲染器（L3 有 = 显示细分按钮；L2 无 = 恒城市模式）
			for ch in content.get_children():
				if ch.has_method("toggle_display_mode"):
					_renderer = ch
					break
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -H
	offset_bottom = 0.0
	# 根 STOP：底部横条整条 = 不可穿透区（F1 验收反馈），点击不落到地图地块上；
	# 地图拖拽/滚轮走 MapCamera._input（先于 GUI），不受本条影响
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 可见 UI 外壳（次窗体底"玻璃横条"，与图例同款样式）
	var shell := Panel.new()
	shell.name = "Shell"
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	shell.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	shell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shell)
	_build_widgets()


## 设置默认缩放（该视图初始缩放 = 100%），由控制器 open() 时调用
func set_default_zoom(z: float) -> void:
	if z <= 0.0:
		return
	default_zoom = z
	if _slider != null:
		_block_slider_signal = true
		# 滑块下限不得低于相机硬限（如 L3 全屏模式 min_zoom=适配缩放），
		# 否则滑块可设出被相机 clamp 拒绝的值，显示与实际缩放脱节
		var cam_min := 0.0
		if _camera != null and "min_zoom" in _camera:
			cam_min = float(_camera.min_zoom)
		_slider.min_value = maxf(default_zoom * MIN_MULT, cam_min)
		_slider.max_value = default_zoom * MAX_MULT
		# 直接落到当前相机缩放，避免 range clamp 触发 value_changed 反向写相机
		var cur: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else z
		_slider.set_value_no_signal(clampf(cur, _slider.min_value, _slider.max_value))
		_block_slider_signal = false
	_update_label()
	_update_ruler()


func _build_widgets() -> void:
	var x: float = StickTokens.SCREEN_MARGIN
	# 地图模式条（B4）：地形/政治 双选按钮（ButtonGroup 单选；状态随静态模式广播同步）
	if _mode_manager != null:
		_mode_group = ButtonGroup.new()
		_terrain_btn = _make_mode_button("地形", MapModeManager.Mode.TERRAIN)
		_dock_bottom_left(_terrain_btn, x, MODE_BTN_W, StickTokens.BTN_H_SM)
		x += MODE_BTN_W + GAP
		_political_btn = _make_mode_button("政治", MapModeManager.Mode.POLITICAL)
		_dock_bottom_left(_political_btn, x, MODE_BTN_W, BTN_H_SM)
		x += MODE_BTN_W + GAP
		_sync_mode_buttons()
		# 资源/物流覆盖层入口预留（创始人要求）：枚举已留、数据未接，置灰占位
		for r in [["资源", "未开放：资源覆盖层数据接入后启用"],
				["物流", "未开放：物流覆盖层数据接入后启用"]]:
			var rb := StickKit.button(self, r[0], Callable(),
					StickKit.ButtonKind.NORMAL, BTN_H_SM)
			rb.disabled = true
			rb.tooltip_text = r[1]
			rb.custom_minimum_size = Vector2(MODE_BTN_W, BTN_H_SM)
			_dock_bottom_left(rb, x, MODE_BTN_W, BTN_H_SM)
			x += MODE_BTN_W + GAP
	# 细分模式按钮（仅 L3 有 toggle_display_mode）
	if _renderer != null and _renderer.has_method("toggle_display_mode"):
		_mode_btn = StickKit.button(self, "细分:关", _on_mode_pressed,
				StickKit.ButtonKind.NORMAL, BTN_H_SM)
		_mode_btn.custom_minimum_size = Vector2(BTN_W, BTN_H_SM)
		_dock_bottom_left(_mode_btn, x, BTN_W, BTN_H_SM)
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


## 造模式条按钮（toggle + 单选组；点击写全局静态模式，广播回流同步另一颗）
func _make_mode_button(text: String, mode: int) -> Button:
	var b := StickKit.button(self, text, func() -> void: MapModeManager.set_mode(mode),
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	b.toggle_mode = true
	b.button_group = _mode_group
	b.custom_minimum_size = Vector2(MODE_BTN_W, StickTokens.BTN_H_SM)
	return b


## 模式变更（含他视图切模式广播回流）：同步两颗按钮按压态
func _on_map_mode_changed(_mode: int) -> void:
	_sync_mode_buttons()


func _sync_mode_buttons() -> void:
	if _terrain_btn == null or _political_btn == null:
		return
	var m: int = MapModeManager.current_mode
	_terrain_btn.set_pressed_no_signal(m == MapModeManager.Mode.TERRAIN)
	_political_btn.set_pressed_no_signal(m == MapModeManager.Mode.POLITICAL)


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
