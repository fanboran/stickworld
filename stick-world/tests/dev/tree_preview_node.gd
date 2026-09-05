extends Node2D
## 单棵预览树 —— 持有笔列表，逐笔生长动画（渲染过程展示），画完静止。
## 笔列表为贴图本地坐标（y 向下、ground=H-12），绘制时按 origin/scale 变换。

var pens: Array = []
var label := ""
var wire_tree: Dictionary = {}  # 非空 = 结构线框模式（管线阶段①）
var progress := 0.0
var speed := 0.035  # 每帧推进比例（约 0.5-1s 画完）
var display_origin := Vector2.ZERO
var display_scale := 1.0
var _done := true


func setup(p_pens: Array, p_origin: Vector2, p_scale: float, p_delay: float = 0.0) -> void:
	pens = p_pens
	display_origin = p_origin
	display_scale = p_scale
	progress = -p_delay  # 负值 = 延迟入场（按排依次生长）
	_done = false
	queue_redraw()


## 结构线框：干矩形描边 + 枝线 + 冠圆描边（管线阶段①可视化）
func _draw_wire() -> void:
	var t := wire_tree
	var sc := display_scale
	var ox := display_origin
	var xf := func(p: Vector2) -> Vector2:
		return Vector2((p.x - 192.0) * sc, (p.y - 660.0) * sc) + ox
	var trunk_l: Vector2 = xf.call(Vector2(float(t["trunk_top_x"]) - float(t["w_top"]) * 0.5, float(t["trunk_top_y"])))
	var trunk_r: Vector2 = xf.call(Vector2(float(t["trunk_top_x"]) + float(t["w_top"]) * 0.5, float(t["trunk_top_y"])))
	var trunk_lb: Vector2 = xf.call(Vector2(float(t["trunk_bot_x"]) - float(t["w_base"]) * 0.5, float(t["ground"])))
	var trunk_rb: Vector2 = xf.call(Vector2(float(t["trunk_bot_x"]) + float(t["w_base"]) * 0.5, float(t["ground"])))
	var col := Color(0.15, 0.12, 0.08, 0.9)
	draw_line(trunk_l, trunk_lb, col, 2.0)
	draw_line(trunk_r, trunk_rb, col, 2.0)
	draw_line(trunk_l, trunk_r, col, 2.0)
	draw_line(trunk_lb, trunk_rb, col, 2.0)
	for br in t["branches"]:
		draw_line(xf.call(br["o"]), xf.call(br["t"]), Color(0.3, 0.2, 0.1, 0.9), 2.0)
	for b in t["blobs"]:
		var c: Vector2 = xf.call(b["c"])
		draw_arc(c, b["r"] * sc, 0.0, TAU, 40, Color(0.2, 0.35, 0.15, 0.8), 2.0)


func _process(_delta: float) -> void:
	if _done:
		return
	progress += speed
	if progress >= 1.0:
		progress = 1.0
		_done = true
	queue_redraw()


func _draw() -> void:
	if label != "":
		draw_string(ThemeDB.fallback_font, Vector2(-80, 34), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.1, 0.1, 0.12))
	if not wire_tree.is_empty():
		_draw_wire()
		return
	if pens.is_empty() or progress <= 0.0:
		return
	var n := int(progress * pens.size())
	var sc := display_scale
	var ox := display_origin
	for i in n:
		var p: Dictionary = pens[i]
		# 贴图原生坐标(x 居中 192 / y 向下 ground 660) → 锚点向上
		var a: Vector2 = Vector2((p["a"].x - 192.0) * sc, (p["a"].y - 660.0) * sc) + ox
		var b: Vector2 = Vector2((p["b"].x - 192.0) * sc, (p["b"].y - 660.0) * sc) + ox
		var w: float = p["w"] * sc
		draw_line(a, b, p["c"], w)
		draw_circle(a, w * 0.5, p["c"])
		draw_circle(b, w * 0.5, p["c"])
