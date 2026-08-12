class_name PlacementGhost
extends Node2D
## 建造条带预览 —— 单节点自定义绘制。
##
## 早期版本每帧 queue_free() + add_child() 数十个节点，导致呼吸动画帧率低、绘制
## 偶发异常；改为本节点 _draw() 全量绘制，每帧仅 queue_redraw()。
##
## BuildMenu 每帧更新字段后调用 queue_redraw()。

const CELL_SIZE: int = 32
const CELL_INSET_X: float = 3.0
const CELL_INSET_Y: float = 2.0
const CORNER_ARM: float = 10.0
const CORNER_OUTER: float = 2.0
## 端部三角：等边三角，尖朝外（左尖朝左、右尖朝右），整体位于端格靠内一侧。
## 底边靠近但不越过端格内侧边线（保持正距离，不贴线、不越线）
const TRI_BASE: float = 14.0
const TRI_HEIGHT: float = TRI_BASE * 0.866
## 三角底边距端格内侧边线的距离（px，靠内一侧、保持正距离、不贴线不重合）
const TRI_EDGE_INSET: float = 10.0
## 点击反馈时长（ms）
const WOBBLE_DUR_MS: float = 400.0
const RIPPLE_DUR_MS: float = 300.0

## 条带区间 [左, 右)
var cell_start: int = 0
var cell_end: int = 0
## 是否在界内（越界整体变红）
var in_bounds: bool = true
## 是否已放下草稿（进入拉伸阶段，显示端部把手与默认角框）
var draft_placed: bool = false
## 默认大小（橙色角框标定）
var default_start: int = 0
var default_end: int = 0
## 条带视觉范围
var top: float = 0.0
var baseline: float = 0.0
## 悬停的端部格：-1 无，0 左端格，1 右端格
var hover_side: int = -1

## 点击反馈状态
var _wobble_side: int = -1
var _wobble_start_ms: int = -1
var _ripple_side: int = -1
var _ripple_start_ms: int = -1


## 点击反馈：端格绕中心左右震动两下 + 该侧三角浅虚影外扩
func trigger_feedback(side: int) -> void:
	_wobble_side = side
	_wobble_start_ms = Time.get_ticks_msec()
	_ripple_side = side
	_ripple_start_ms = Time.get_ticks_msec()


func _draw() -> void:
	var width: int = maxi(1, cell_end - cell_start)
	var now: int = Time.get_ticks_msec()
	var outline_color: Color = Color(0.3, 0.6, 1.0, 0.9) if in_bounds else Color(0.9, 0.2, 0.2, 0.9)
	var fill_color: Color = Color(0.3, 0.6, 1.0, 0.3) if in_bounds else Color(0.9, 0.2, 0.2, 0.3)
	# 呼吸动画（周期 3s）：水平只向内缩（0~+1px），垂直 ±1.5px
	var tb: float = float(now) * TAU / 3000.0
	var breath_x: float = (sin(tb) + 1.0) * 0.5
	var breath_y: float = sin(tb) * 1.5
	var wobble_angle: float = _wobble_angle(now)
	for c in range(width):
		var cx: int = cell_start + c
		# 悬停端格：垂直 +3px、水平 +1px、停止呼吸；点击震动也作用于该格
		var is_focus: bool = draft_placed and ((hover_side == 0 and c == 0) or (hover_side == 1 and c == width - 1) or _wobble_side == 0 and c == 0 or _wobble_side == 1 and c == width - 1)
		var bx: float = breath_x if not is_focus else 0.0
		var by: float = breath_y if not is_focus else 0.0
		var left: float = float(cx) * float(CELL_SIZE)
		var right: float = left + float(CELL_SIZE)
		var rl: float = left + CELL_INSET_X + bx
		var rr: float = right - CELL_INSET_X - bx
		var rt: float = top + CELL_INSET_Y + by
		var rb: float = baseline - CELL_INSET_Y - by
		if is_focus:
			rl -= 0.5
			rr += 0.5
			rt -= 2.5
			rb += 2.5
		if rr <= rl:
			rr = rl + 4.0
		var rect := Rect2(Vector2(rl, rt), Vector2(rr - rl, rb - rt))
		if is_focus and absf(wobble_angle) > 0.001:
			var center := rect.get_center()
			draw_set_transform(center, wobble_angle)
			draw_rect(Rect2(-rect.size.x * 0.5, -rect.size.y * 0.5, rect.size.x, rect.size.y), fill_color, true)
			draw_rect(Rect2(-rect.size.x * 0.5, -rect.size.y * 0.5, rect.size.x, rect.size.y), outline_color, false, 2.0)
			draw_set_transform(Vector2.ZERO, 0.0)
		else:
			draw_rect(rect, fill_color, true)
			draw_rect(rect, outline_color, false, 2.0)
	if draft_placed:
		_draw_handles(now)
		_draw_ripple(now)
		_draw_default_corners()
	# 格数计数器（条带上方居中，深色底 + 白字）
	var center_x: float = (float(cell_start) + float(cell_end)) * 0.5 * float(CELL_SIZE)
	var text: String = "%d 格" % width
	var label_w: float = 120.0
	var bg_rect := Rect2(Vector2(center_x - label_w * 0.5, top - 44.0), Vector2(label_w, 28.0))
	draw_rect(bg_rect, Color(0, 0, 0, 0.45), true)
	draw_string(ThemeDB.fallback_font, bg_rect.position + Vector2(0, 21.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, label_w, 18, Color(1, 1, 1, 0.95))


## 端部等边三角把手：尖朝外（左尖朝左、右尖朝右），整体位于端格靠内一侧，
## 底边贴近端格内侧边（与相邻格之间的边界线）。悬停该侧时三角 ±0.5px 呼吸。
func _draw_handles(now: int) -> void:
	var cy: float = (top + baseline) * 0.5
	var color := Color(0.3, 0.6, 1.0, 0.95)
	var breath_l: float = 0.0
	var breath_r: float = 0.0
	if hover_side == 0:
		breath_l = sin(float(now) * TAU / 3000.0) * 0.5
	elif hover_side == 1:
		breath_r = sin(float(now) * TAU / 3000.0) * 0.5
	# 左端格：尖朝左（朝条带外），底边贴端格内侧边
	var l_inner: float = float(cell_start + 1) * float(CELL_SIZE) - TRI_EDGE_INSET
	var base_l_x: float = l_inner - breath_l
	var apex_l_x: float = base_l_x - TRI_HEIGHT
	draw_polyline(PackedVector2Array([
		Vector2(apex_l_x, cy), Vector2(base_l_x, cy - TRI_BASE * 0.5), Vector2(base_l_x, cy + TRI_BASE * 0.5), Vector2(apex_l_x, cy),
	]), color, 2.0)
	# 右端格：尖朝右（朝条带外），底边贴端格内侧边
	var r_inner: float = float(cell_end - 1) * float(CELL_SIZE) + TRI_EDGE_INSET
	var base_r_x: float = r_inner + breath_r
	var apex_r_x: float = base_r_x + TRI_HEIGHT
	draw_polyline(PackedVector2Array([
		Vector2(apex_r_x, cy), Vector2(base_r_x, cy - TRI_BASE * 0.5), Vector2(base_r_x, cy + TRI_BASE * 0.5), Vector2(apex_r_x, cy),
	]), color, 2.0)


## 点击涟漪：该侧三角位置处浅色虚影圆环向外扩散后消失
func _draw_ripple(now: int) -> void:
	if _ripple_start_ms < 0:
		return
	var elapsed: float = float(now - _ripple_start_ms)
	if elapsed >= RIPPLE_DUR_MS:
		_ripple_start_ms = -1
		return
	var p: float = elapsed / RIPPLE_DUR_MS
	var radius: float = 6.0 + p * 26.0
	var alpha: float = (1.0 - p) * 0.5
	draw_arc(_triangle_center(_ripple_side), radius, 0.0, TAU, 32, Color(0.5, 0.8, 1.0, alpha), 2.0)


## 震动角：端格绕中心左右震动两下，幅度衰减到 0（结束后复位震动侧）
func _wobble_angle(now: int) -> float:
	if _wobble_start_ms < 0:
		return 0.0
	var elapsed: float = float(now - _wobble_start_ms)
	if elapsed >= WOBBLE_DUR_MS:
		_wobble_start_ms = -1
		_wobble_side = -1
		return 0.0
	var p: float = elapsed / WOBBLE_DUR_MS
	return sin(p * TAU * 2.0) * 0.07 * (1.0 - p)


func _triangle_center(side: int) -> Vector2:
	var cy: float = (top + baseline) * 0.5
	if side == 0:
		return Vector2(float(cell_start + 1) * float(CELL_SIZE) - TRI_EDGE_INSET - TRI_HEIGHT * 0.5, cy)
	return Vector2(float(cell_end - 1) * float(CELL_SIZE) + TRI_EDGE_INSET + TRI_HEIGHT * 0.5, cy)


## 橙色 4 角角框（标定默认大小）：沿矩形边缘向内，垂直方向外移 2px 远离中心
func _draw_default_corners() -> void:
	if default_end <= default_start:
		return
	var dl: float = float(default_start) * float(CELL_SIZE)
	var dr: float = float(default_end) * float(CELL_SIZE)
	var color := Color(1.0, 0.55, 0.1, 1.0)
	_draw_corner(dl, top - CORNER_OUTER, CORNER_ARM, CORNER_ARM, color)
	_draw_corner(dr, top - CORNER_OUTER, -CORNER_ARM, CORNER_ARM, color)
	_draw_corner(dl, baseline + CORNER_OUTER, CORNER_ARM, -CORNER_ARM, color)
	_draw_corner(dr, baseline + CORNER_OUTER, -CORNER_ARM, -CORNER_ARM, color)


## 单个 L 形角框：角点 (px, py)，两条臂沿 X 向 sx、Y 向 sy 伸入矩形内侧
func _draw_corner(px: float, py: float, sx: float, sy: float, color: Color) -> void:
	draw_polyline(PackedVector2Array([
		Vector2(px, py + sy), Vector2(px, py), Vector2(px + sx, py),
	]), color, 3.0)
