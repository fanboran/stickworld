extends Control
class_name MapHUD
## 战略图底部 HUD：层级按钮组（本省 L1/地区 L2/世界 L3）+ 图层开关条（政治/城市/交通/资源，B4）
## + 缩放条（HSlider + 百分比）+ 细分模式按钮（仅 L3）。
## 通用组件：L1 / L3 / L2 场景共用（Content 下有带 toggle_display_mode 的渲染器才显示细分按钮；
## 挂 MapModeManager 才显示图层开关条）。
##
## 层级按钮组（需求 8：不止靠 Tab/M 快捷键切层级）：
##   [本省 L1] [地区 L2] [世界 L3]，当前所在层级高亮（控制器 open 时经 set_level_state 喂）。
##   点击 → EventBus.strategic_map_level_requested(level)，由装配方（system_setup）统一分派
##   （视图互斥与场景图输入暂停/恢复是装配方记账，控制器各管各会记错账）。
##   不可达层级（无该视图 / 无对应地区包）置灰 + tooltip 说明，不报错。
##
## 组件化（与全局 UI 一致）：
##   - 按钮 = 主题 Button（StickTheme/StickKit），不再是自绘矩形
##   - 缩放条 = 公共组件 ZoomSlider（SketchHSlider + 百分比 Label，拖动与滚轮双向同步）
## 布局：左下角单行 [本省 L1|地区 L2|世界 L3] [政治|城市|交通|资源] [细分按钮] [缩放条] [百分比]，
## 互不重叠；根节点 PASS 鼠标，仅按钮/滑块/标签接收输入，不挡地图拖拽/下钻。
##
## 缩放归一化：控制器 open() 时调用 set_default_zoom(初始缩放)，此后显示
## 当前缩放相对默认缩放的百分比（默认 = 100%）。

const H := 56.0

const BTN_W := 150.0
const BTN_H := StickTokens.BTN_H
## 小号按钮高（图层开关条全排 + 细分按钮统一用此高度，顶底对齐）
const BTN_H_SM := StickTokens.BTN_H_SM
const MODE_BTN_W := 56.0
## 层级按钮宽（容「本省 L1」四字 + 内边距）
const LEVEL_BTN_W := 78.0
const SLIDER_W := 240.0
const SLIDER_H := 28.0
const LABEL_W := 60.0
## 控件间距（设计语言五档 4/6/8/12/16 取 12）
const GAP := 12.0

## 层级按钮标识与文案（顺序 = 从细到粗，与视图粒度一致）
const LEVELS: Array[String] = ["L1", "L2", "L3"]
const LEVEL_LABELS := {"L1": "本省 L1", "L2": "地区 L2", "L3": "世界 L3"}

## 滑块允许的缩放倍数范围（相对默认缩放）
const MIN_MULT := 0.5
const MAX_MULT := 3.0

var _camera: Node = null
var _renderer: Node = null

## 图层开关管理器（同场景 Content 子节点；无则不显示开关条）
var _mode_manager: Node = null
## 开关按钮表（layer → Button；点按翻转该层，广播回流刷新按下态）
var _layer_btns: Dictionary = {}

## 层级按钮表（level → Button）与当前层级（控制器 set_level_state 喂）
var _level_btns: Dictionary = {}
var _current_level: String = ""

## 默认缩放（该视图首次打开时的初始缩放 = 100%）
var default_zoom: float = 1.0

var _mode_btn: Button = null
## 缩放条（公共组件：滑条 + 百分比标签 + 双向同步机件）
var _zoom: ZoomSlider = null
var _ruler: ColorRect = null


func _ready() -> void:
	theme = StickTheme.create()
	var layer := get_parent()
	if layer != null:
		var content := layer.get_node_or_null("Content")
		if content != null:
			_camera = content.get_node_or_null("MapCamera")
			_mode_manager = content.get_node_or_null("MapModeManager")
			if _mode_manager != null and _mode_manager.has_signal("layer_toggled"):
				_mode_manager.layer_toggled.connect(_on_layer_toggled)
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
	# 可见 UI 外壳（Panel 回退主题自带 SketchStyle 手绘贴图横条，R8 层1 换肤）
	var shell := Panel.new()
	shell.name = "Shell"
	shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	shell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shell)
	_build_widgets()


## 设置默认缩放（该视图初始缩放 = 100%），由控制器 open() 时调用
func set_default_zoom(z: float) -> void:
	if z <= 0.0:
		return
	default_zoom = z
	if _zoom != null:
		# 滑块下限不得低于相机硬限（如 L3 全屏模式 min_zoom=适配缩放），
		# 否则滑块可设出被相机 clamp 拒绝的值，显示与实际缩放脱节
		var cam_min := 0.0
		if _camera != null and "min_zoom" in _camera:
			cam_min = float(_camera.min_zoom)
		# 直接落到当前相机缩放，避免 range clamp 触发 value_changed 反向写相机
		# （set_range 内部屏蔽 clamp 信号）
		var cur: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else z
		_zoom.set_range(maxf(default_zoom * MIN_MULT, cam_min), default_zoom * MAX_MULT, NAN, cur)
	_zoom.refresh_label()
	_update_ruler()


func _build_widgets() -> void:
	var x: float = StickTokens.SCREEN_MARGIN
	# 层级按钮组（需求 8）：[本省 L1][地区 L2][世界 L3] 三档独立 toggle（当前层高亮，
	# 不可达层置灰）；点击发 EventBus.strategic_map_level_requested，装配方统一分派
	for lv in LEVELS:
		var b := _make_level_button(String(lv))
		_dock_bottom_left(b, x, LEVEL_BTN_W, BTN_H_SM)
		x += LEVEL_BTN_W + GAP
	_sync_level_buttons()
	x += GAP * 0.5
	# 图层开关条（B4）：政治/城市/交通/资源 四联独立 toggle 按钮（无单选组——
	# 四层可任意叠加；状态随静态开关表广播同步）
	if _mode_manager != null:
		for layer in [MapModeManager.Layer.POLITICAL, MapModeManager.Layer.CITY,
				MapModeManager.Layer.TRAFFIC, MapModeManager.Layer.RESOURCE]:
			var b := _make_layer_button(MapModeManager.layer_name(layer), layer)
			_dock_bottom_left(b, x, MODE_BTN_W, BTN_H_SM)
			x += MODE_BTN_W + GAP
		_sync_layer_buttons()
	# 细分模式按钮（仅 L3 有 toggle_display_mode）
	if _renderer != null and _renderer.has_method("toggle_display_mode"):
		_mode_btn = StickKit.sketch_button(self, "细分:关", _on_mode_pressed,
				StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		_mode_btn.custom_minimum_size = Vector2(BTN_W, BTN_H)
		_dock_bottom_left(_mode_btn, x, BTN_W, BTN_H)
		_update_mode_text()
		x += BTN_W + GAP
	# 缩放滑块（公共组件 ZoomSlider：手绘滑条 + 百分比，拖动/滚轮双向同步）
	_zoom = ZoomSlider.new()
	_zoom.slider_size = Vector2(SLIDER_W, SLIDER_H)
	_zoom.label_width = LABEL_W
	_zoom.separation = int(GAP)
	_zoom.sync_epsilon = 0.0005
	_zoom.get_display_value = func() -> float:
		if _camera != null and _camera.has_method("get_zoom"):
			return _camera.get_zoom()
		return default_zoom
	_zoom.apply_display = func(v: float) -> void:
		if _camera != null and _camera.has_method("set_zoom"):
			_camera.set_zoom(v)
	_zoom.format_percent = func(_display: float) -> String:
		# 标签读相机真实值（拖动写相机后可能被 clamp，显示与实际缩放一致）
		var zoom: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else default_zoom
		return "%d%%" % int(roundf(zoom / default_zoom * 100.0))
	# 先入树（_ready 建子控件）再落量程：把滑块值落在范围内且不触发
	# set_zoom 干扰相机（set_range 屏蔽 clamp 信号）
	add_child(_zoom)
	_zoom.set_range(default_zoom * MIN_MULT, default_zoom * MAX_MULT, 0.001, default_zoom)
	_dock_bottom_left(_zoom, x, SLIDER_W + GAP + LABEL_W, SLIDER_H)
	_update_ruler()
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


## 造图层开关按钮（toggle，独立不成组；点击翻转全局静态开关表，广播回流同步按下态）
func _make_layer_button(text: String, layer: int) -> Button:
	var b := StickKit.button(self, text, func() -> void: MapModeManager.toggle_layer(layer),
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(MODE_BTN_W, StickTokens.BTN_H_SM)
	_layer_btns[layer] = b
	return b


## 造层级按钮（toggle，独立不成组；点击发全局层级切换请求，状态由控制器回流刷新）
func _make_level_button(level: String) -> Button:
	var b := StickKit.button(self, str(LEVEL_LABELS.get(level, level)),
			_on_level_pressed.bind(level), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(LEVEL_BTN_W, StickTokens.BTN_H_SM)
	_level_btns[level] = b
	return b


## 层级按钮点击 → 全局请求（装配方分派；逐级出口不各自关闭/打开视图，记错输入暂停账）
func _on_level_pressed(level: String) -> void:
	if EventBus != null:
		EventBus.strategic_map_level_requested.emit(level)


## 设置层级状态（控制器 open 时喂）：current 高亮，enabled 内 false 的层级置灰。
## tips: 层级 → tooltip 文案（不可达原因 / 操作说明；空串 = 清空提示）。
func set_level_state(current: String, enabled: Dictionary = {}, tips: Dictionary = {}) -> void:
	_current_level = current
	for lv in _level_btns:
		var b: Button = _level_btns[lv]
		b.set_pressed_no_signal(String(lv) == current)
		b.disabled = not bool(enabled.get(lv, true))
		b.tooltip_text = str(tips.get(lv, ""))
	_sync_level_buttons()


## 层级按钮按下态同步（当前层级高亮；控制器可能在他视图切层后回流）
func _sync_level_buttons() -> void:
	for lv in _level_btns:
		var b: Button = _level_btns[lv]
		b.set_pressed_no_signal(String(lv) == _current_level)


## 图层按钮可用性（L1 锁政治层：视图默认即政治配色、无附加层可关——按钮禁用；
## L2/L3 恢复可点。创始人 2026-09-29）
func set_layer_enabled(layer: int, enabled: bool) -> void:
	var b: Button = _layer_btns.get(layer)
	if b != null:
		b.disabled = not enabled


## 图层开关变更（含他视图切层广播回流）：按静态开关表刷新四颗按钮按下态
func _on_layer_toggled(_layer: int, _on: bool) -> void:
	_sync_layer_buttons()


func _sync_layer_buttons() -> void:
	for layer in _layer_btns:
		var b: Button = _layer_btns[layer]
		b.set_pressed_no_signal(MapModeManager.is_layer_on(layer))


func _update_ruler() -> void:
	if _ruler == null or _zoom == null or _zoom.slider == null:
		return
	var s := _zoom.slider
	var grabber := s.get_theme_icon("grabber", "HSlider")
	var gw: float = float(grabber.get_width()) if grabber != null else 16.0
	var nrm := clampf((default_zoom - s.min_value) / (s.max_value - s.min_value), 0.0, 1.0)
	var tick_x := nrm * (SLIDER_W - gw) + gw * 0.5
	# 刻度锚滑条在容器内的位置（滑条是 HBox 首子控件，首帧布局前 position=(0,0) 亦正确）
	_ruler.position = _zoom.position + s.position + Vector2(tick_x - 1.0, SLIDER_H - 5.0)
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
