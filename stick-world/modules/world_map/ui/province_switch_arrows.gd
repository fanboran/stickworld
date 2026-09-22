extends Control
class_name ProvinceSwitchArrows
## 战略图 L1 左右切省箭头 —— 屏幕左中/右中各一个**扁等腰三角形**，点击切到该方向的
## 相邻 L1 省份（查看邻省的政权分布）。
##
## 为什么是贴边的三角而不是常规按钮：地图四边都是内容区，箭头读作「地图边界的方向
## 指示」；扁等腰形（短指向、宽底边）贴边时不遮挡地图中心；朝向按邻省**实际方位**
## 旋转（对应方向箭头），所以西北邻省时左箭头就朝左上——方向诚实，不假装正左正右。
##
## 数据与动作全部由控制器注入（本文件不认识 world_map 数据层）：
##   targets_fn:  () -> Array[Dictionary]  条目 {side, label, bearing: Vector2, text, color}
##   activate_fn: (label: int) -> void
## side = ProvincePolitics.SIDE_LEFT / SIDE_RIGHT；某侧无候选（无相邻省份）则该侧不画。
##
## 根 = 全屏 Control（走 UIKit.full_rect 合规出口，anchor 正确）；两个三角是普通的
## 贴边子控件（自带 anchor），只有三角本体吃鼠标（根 IGNORE），不挡地图拖拽/点选。

## 三角形体量（扁：指向轴短、底边长）
const ARROW_LENGTH := 20.0
const ARROW_BASE := 46.0
## 距屏幕边缘留白
const EDGE_MARGIN := 10.0
## 朝向相对基准方位（左箭头 = 正左、右箭头 = 正右）的最大偏转：超过就"竖起来"不像左右箭头了
const MAX_TILT := 0.9   # rad ≈ 51.6°

## 数据源 / 动作（控制器注入；未注入 = 两侧皆不画）
var targets_fn: Callable = Callable()
var activate_fn: Callable = Callable()

var _arrow_left: Control = null
var _arrow_right: Control = null
## 当前目标（side -> 条目；无该侧条目则不画）
var _targets: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow_left = _make_arrow(ProvincePolitics.SIDE_LEFT)
	_arrow_right = _make_arrow(ProvincePolitics.SIDE_RIGHT)
	visible = false


## 建一个贴边三角子控件（左中 / 右中锚点，固定尺寸）
func _make_arrow(side: int) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	c.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	c.custom_minimum_size = Vector2(ARROW_LENGTH, ARROW_BASE)
	c.anchor_top = 0.5
	c.anchor_bottom = 0.5
	if side == ProvincePolitics.SIDE_LEFT:
		c.anchor_left = 0.0
		c.anchor_right = 0.0
		c.offset_left = EDGE_MARGIN
		c.offset_right = EDGE_MARGIN + ARROW_LENGTH
	else:
		c.anchor_left = 1.0
		c.anchor_right = 1.0
		c.offset_left = -EDGE_MARGIN - ARROW_LENGTH
		c.offset_right = -EDGE_MARGIN
	c.offset_top = -ARROW_BASE * 0.5
	c.offset_bottom = ARROW_BASE * 0.5
	c.visible = false
	c.draw.connect(_draw_arrow.bind(c, side))
	c.gui_input.connect(_on_arrow_input.bind(side))
	c.mouse_entered.connect(_on_arrow_hover.bind(side, true))
	c.mouse_exited.connect(_on_arrow_hover.bind(side, false))
	add_child(c)
	return c


## 重取目标（控制器在地图打开 / 切省后调用）
func refresh() -> void:
	_targets = {}
	if targets_fn.is_valid():
		for t in targets_fn.call():
			if t is Dictionary:
				_targets[int((t as Dictionary).get("side", 0))] = t
	for side in [ProvincePolitics.SIDE_LEFT, ProvincePolitics.SIDE_RIGHT]:
		var c: Control = _arrow_left if side == ProvincePolitics.SIDE_LEFT else _arrow_right
		if c == null:
			continue
		var info: Dictionary = _targets.get(side, {})
		c.visible = visible and not info.is_empty()
		if c.visible:
			c.tooltip_text = String(info.get("text", ""))
		c.queue_redraw()


## 扁等腰三角：底边贴屏幕边、顶点朝邻省方位；填充 = 邻省主导政权色（侧表缺 = 纸色）
func _draw_arrow(c: Control, side: int) -> void:
	var info: Dictionary = _targets.get(side, {})
	if info.is_empty():
		return
	var fill: Color = info.get("color", MapTokens.L1_ARROW_FILL)
	if fill.a <= 0.0:
		fill = MapTokens.L1_ARROW_FILL
	if bool(info.get("hovered", false)):
		fill = fill.lightened(0.18)
	var bearing: Vector2 = info.get("bearing", Vector2.ZERO)
	var base_ang := PI if side == ProvincePolitics.SIDE_LEFT else 0.0
	# 朝屏幕内的一侧为指向轴：右箭头指 +x、左箭头指 -x
	var rot := clampf(bearing.angle() - base_ang, -MAX_TILT, MAX_TILT)
	var h := c.size.y if c.size.y > 1.0 else ARROW_BASE
	var len_px := c.size.x if c.size.x > 1.0 else ARROW_LENGTH
	var center := Vector2(len_px * 0.5, h * 0.5)
	# 局部（指 +x）：底边在 x=0、顶点在 x=len_px
	var local := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(len_px, h * 0.5), Vector2(0.0, h)])
	var pts := PackedVector2Array()
	for p in local:
		pts.append(center + (p - center).rotated(rot))
	c.draw_colored_polygon(pts, fill)
	var outline := PackedVector2Array(pts)
	outline.append(pts[0])
	c.draw_polyline(outline, MapTokens.L1_ARROW_INK, MapTokens.L1_ARROW_INK_WIDTH, true)


func _on_arrow_input(event: InputEvent, side: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var info: Dictionary = _targets.get(side, {})
	var label := int(info.get("label", 0))
	if label > 0 and activate_fn.is_valid():
		activate_fn.call(label)
	accept_event()


func _on_arrow_hover(side: int, entered: bool) -> void:
	var info: Dictionary = _targets.get(side, {})
	if info.is_empty():
		return
	info["hovered"] = entered
	var c: Control = _arrow_left if side == ProvincePolitics.SIDE_LEFT else _arrow_right
	if c != null:
		c.queue_redraw()


## 显隐（视图开/关用；各侧是否有目标由 refresh 决定，这里只叠总开关）
func set_shown(v: bool) -> void:
	visible = v
	refresh()
