extends Control
class_name ProvinceSwitchArrows
## 战略图 L1 切省箭头环 —— **每个相邻老 L1 省份一个扁等腰三角箭头**，全部排在
## 地图内容区内的一个**虚拟圆环**上：箭头沿半径**背离圆心**指向对应省份，点击切过去
## 看该省的政权分布。
##
## 为什么是圆环：相邻省份可能有一圈（出生省 3 个、大包 17 个），左右两个按钮表达不了
## 「周围有多少邻省」；圆环把方位如实摊开——东北的省，箭头就在环的东北角朝外。
## 圆环锚在**地图坐标系**（随地图缩放/平移跟着走，始终在地图内），不是贴在屏幕上。
##
## 数据与动作全部由控制器注入（本文件不认识 world_map 数据层）：
##   targets_fn: () -> Dictionary
##     {"center": Vector2(地图坐标圆心), "radius": float(地图单位半径),
##      "arrows": [{"label": int, "angle": float(弧度, 指向该省), "color": Color, "text": String}]}
##   activate_fn: (label: int) -> void
##   screen_pos_fn: (map_pos: Vector2) -> Vector2   # 地图坐标 -> 屏幕坐标（相机换算）
## arrows 为空（无邻省/侧表缺失）→ 整环隐藏。
##
## 根 = 全屏 Control（UIKit.full_rect 合规出口）；只有三角本体吃鼠标（根 IGNORE），
## 不挡地图拖拽/点选。

## 三角形体量（**扁等腰**：高 16 / 底 34，约 1:2 —— 底高比接近 1 的等边三角形旋转后
## 读不出朝向，扁形才有明确的指向；可点区取 38 方形，容下任意旋转角）
const ARROW_LENGTH := 16.0
const ARROW_BASE := 34.0
## 单箭头可点区（比三角形略大一圈，便于点击）
const HIT_SIZE := Vector2(38.0, 38.0)

## 数据源 / 动作（控制器注入；未注入 = 隐藏）
var targets_fn: Callable = Callable()
var activate_fn: Callable = Callable()
var screen_pos_fn: Callable = Callable()

var _center := Vector2.ZERO
var _radius := 0.0
## 当前箭头数据（与 _nodes 同序）
var _entries: Array = []
## 箭头子控件（按 entry 数量重建；多出的回收）
var _nodes: Array[Control] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(true)


## 重取目标环（控制器在地图打开 / 切省后调用）
func refresh() -> void:
	_entries = []
	_center = Vector2.ZERO
	_radius = 0.0
	if targets_fn.is_valid():
		var cfg: Variant = targets_fn.call()
		if cfg is Dictionary:
			_center = (cfg as Dictionary).get("center", Vector2.ZERO)
			_radius = float((cfg as Dictionary).get("radius", 0.0))
			_entries = (cfg as Dictionary).get("arrows", [])
	_rebuild()
	_update_positions()


## 按 entry 数量重建/复用箭头控件（复用避免每帧重建节点）
func _rebuild() -> void:
	while _nodes.size() < _entries.size():
		var c := Control.new()
		c.mouse_filter = Control.MOUSE_FILTER_STOP
		c.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		c.custom_minimum_size = HIT_SIZE
		c.size = HIT_SIZE
		var idx := _nodes.size()
		c.draw.connect(_draw_arrow.bind(idx))
		c.gui_input.connect(_on_arrow_input.bind(idx))
		c.mouse_entered.connect(_on_arrow_hover.bind(idx, true))
		c.mouse_exited.connect(_on_arrow_hover.bind(idx, false))
		add_child(c)
		_nodes.append(c)
	for i in _nodes.size():
		var c := _nodes[i]
		var has_entry := i < _entries.size()
		c.visible = visible and has_entry
		if has_entry:
			c.tooltip_text = String((_entries[i] as Dictionary).get("text", ""))
		c.queue_redraw()


## 每帧把各箭头摆到圆环上的屏幕位置（圆环在地图坐标系 → 随缩放/平移跟随；
## 位置未变不写（避免无谓的 transform 传播））
func _process(_delta: float) -> void:
	if visible:
		_update_positions()


func _update_positions() -> void:
	if not visible or _entries.is_empty() or not screen_pos_fn.is_valid():
		return
	for i in _entries.size():
		if i >= _nodes.size():
			break
		var e: Dictionary = _entries[i]
		var ang := float(e.get("angle", 0.0))
		var map_pos: Vector2 = _center + Vector2(cos(ang), sin(ang)) * _radius
		var screen: Vector2 = screen_pos_fn.call(map_pos)
		var want := screen - HIT_SIZE * 0.5
		var c := _nodes[i]
		if c.position != want:
			c.position = want


## 扁等腰三角：顶点朝外（背离圆心，指向对应省份方位）
func _draw_arrow(idx: int) -> void:
	if idx >= _entries.size() or idx >= _nodes.size():
		return
	var e: Dictionary = _entries[idx]
	var c := _nodes[idx]
	var fill: Color = e.get("color", MapTokens.L1_ARROW_FILL)
	if fill.a <= 0.0:
		fill = MapTokens.L1_ARROW_FILL
	if bool(e.get("hovered", false)):
		fill = fill.lightened(0.18)
	var ang := float(e.get("angle", 0.0))
	var h := c.size.y if c.size.y > 1.0 else HIT_SIZE.y
	var w := c.size.x if c.size.x > 1.0 else HIT_SIZE.x
	# 三角在控件中心、指向 +x：顶点在前、底边在后 —— 整体按方位角旋转（+x 即箭头指向）
	var xf := Transform2D(ang, Vector2(w * 0.5, h * 0.5))
	var tip := Vector2(ARROW_LENGTH * 0.5, 0.0)
	var back := Vector2(-ARROW_LENGTH * 0.5, 0.0)
	var half_base := ARROW_BASE * 0.5
	var pts := PackedVector2Array([
		xf * tip,
		xf * (back + Vector2(0.0, -half_base)),
		xf * (back + Vector2(0.0, half_base)),
	])
	c.draw_colored_polygon(pts, fill)
	var outline := PackedVector2Array(pts)
	outline.append(pts[0])
	c.draw_polyline(outline, MapTokens.L1_ARROW_INK, MapTokens.L1_ARROW_INK_WIDTH, true)


func _on_arrow_input(event: InputEvent, idx: int) -> void:
	if idx >= _entries.size():
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var label := int((_entries[idx] as Dictionary).get("label", 0))
	if label > 0 and activate_fn.is_valid():
		activate_fn.call(label)
	accept_event()


func _on_arrow_hover(idx: int, entered: bool) -> void:
	if idx >= _entries.size():
		return
	(_entries[idx] as Dictionary)["hovered"] = entered
	if idx < _nodes.size():
		_nodes[idx].queue_redraw()


## 显隐（视图开/关用；是否有箭头由 refresh 的 entries 决定）
func set_shown(v: bool) -> void:
	visible = v
	refresh()


## 当前箭头数（测试/调试读取）
func arrow_count() -> int:
	return _entries.size()


## 当前箭头标签序（测试/调试读取）
func arrow_labels() -> Array:
	var out: Array = []
	for e in _entries:
		out.append(int((e as Dictionary).get("label", 0)))
	return out
