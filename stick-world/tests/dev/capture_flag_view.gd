class_name CaptureFlagView
extends ProgressPainter
## 夺点旗视觉（观察场侧渲染件）——CapturePoint 是纯 RefCounted 零渲染（tactics
## 依赖纪律），旗面/占领圈/进度由本节点只读消费 get_capture_state() 画出来。
## 挂战场 entity_host（y_sort）：旗底 y = 旗位，自然参与单位前后排序。
## 绘制（世界空间，24px=1 格口径）：
##   - 地面占领圈：归属色淡填充 + 描边（争夺态白描边）
##   - 旗杆 72px + 三角旗面（归属色：蓝/红/中立灰白）
##   - 旗脚进度条：单方在场推进时显示占旗进度（进攻方色，ProgressPainter.draw_bar）
## 节拍 0.2s 比对摘要，变化才重绘。

## 阵营配色（对齐血条 FACTION_COLORS 口径，此处自带防跨模块取色）
const COLORS: Dictionary = {
	1: Color(0.38, 0.58, 0.98),
	2: Color(0.98, 0.44, 0.35),
	0: Color(0.75, 0.75, 0.72),
}
## 旗杆高（px）——按观战缩放 0.46 标定可辨尺寸（杆≈50px 屏幕高，约 1.5 人高的旗帜感）
const POLE_H: float = 110.0
## 旗面三角（底边/高，px；zoom 0.46 下屏上 ≈30×18px）
const FLAG_W: float = 66.0
const FLAG_H: float = 40.0
## 旗脚进度条尺寸（px）
const BAR_W: float = 44.0
const BAR_H: float = 9.0
## 状态比对节拍（s）
const POLL: float = 0.2

## 关联夺点（RefCounted，duck 读 get_capture_state/get_holders）
var point: RefCounted = null

var _t := 0.0
var _sig := ""


func _ready() -> void:
	z_index = 0   # 与单位同层（y_sort 排前后，不抬层压单位）


func _physics_process(delta: float) -> void:
	if point == null:
		return
	_t += delta
	if _t < POLL:
		return
	_t = 0.0
	var s: Dictionary = point.get_capture_state()
	var sig: String = "%d|%.0f|%s" % [int(s.get("owner_faction", 0)), float(s.get("progress", 0.0)), bool(s.get("contested", false))]
	if sig != _sig:
		_sig = sig
		queue_redraw()


func _draw() -> void:
	if point == null:
		return
	var s: Dictionary = point.get_capture_state()
	var owner_c: Color = COLORS.get(int(s.get("owner_faction", 0)), COLORS[0])
	var r: float = float(s.get("radius", 0.0))
	# 地面占领圈（争夺态白描边示意冻结互消）
	draw_circle(Vector2.ZERO, r, Color(owner_c.r, owner_c.g, owner_c.b, 0.16))
	var ring: Color = Color(owner_c.r, owner_c.g, owner_c.b, 0.55) \
			if not bool(s.get("contested", false)) else Color(1, 1, 1, 0.8)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, ring, 2.0)
	# 旗杆 + 三角旗面（归属色）
	draw_line(Vector2.ZERO, Vector2(0, -POLE_H), Color(0.2, 0.18, 0.15), 3.5)
	var top := Vector2(0, -POLE_H)
	var tri := PackedVector2Array([
		top, top + Vector2(FLAG_W, FLAG_H * 0.4), top + Vector2(0, FLAG_H),
	])
	draw_colored_polygon(tri, owner_c)
	draw_polyline(tri + PackedVector2Array([top]), ProgressPainter.COLOR_BORDER, 1.5)
	# 旗脚进度条：单方在场推进才显示（占旗方色）
	var holders: Dictionary = point.get_holders()
	if holders.size() == 1:
		var taker: int = holders.keys()[0]
		draw_bar(-BAR_W * 0.5, -BAR_H - 2.0, BAR_W, BAR_H,
				float(s.get("progress", 0.0)) / 100.0, COLORS.get(taker, COLORS[0]))
