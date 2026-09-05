extends Node2D
## 单棵预览树 —— 三种模式：
##   "wire"  结构线框（管线阶段①）
##   "pens"  笔列表直绘（贴图原生坐标，y 向下、ground=H-12；过程可视化用）
##   "tex"   成品贴图（rasterize 产物 ImageTexture，即最终视觉）
## pens/tex 坐标约定：贴图原生坐标（x 居中 192、y 向下、ground=660），
## 绘制时按 display_origin/display_scale 变换（锚点 = 画布中轴 × 地面线）。

const TP := preload("res://tests/dev/tree_pipeline.gd")

var mode := "pens"
var pens: Array = []
var tex: Texture2D
var label := ""
var wire_tree: Dictionary = {}  # mode="wire" 时的结构数据
var progress := 0.0
var speed := 0.035  # 每帧推进比例（约 0.5-1s 画完）
var display_origin := Vector2.ZERO
var display_scale := 1.0
var _done := true


func setup(p_pens: Array, p_origin: Vector2, p_scale: float, p_delay: float = 0.0) -> void:
	mode = "pens"
	pens = p_pens
	tex = null
	display_origin = p_origin
	display_scale = p_scale
	progress = -p_delay  # 负值 = 延迟入场（按排依次生长）
	_done = false
	queue_redraw()


func setup_tex(p_tex: Texture2D, p_origin: Vector2, p_scale: float) -> void:
	mode = "tex"
	tex = p_tex
	pens = []
	display_origin = p_origin
	display_scale = p_scale
	progress = 1.0
	_done = true
	queue_redraw()


func setup_wire(p_tree: Dictionary, p_origin: Vector2, p_scale: float) -> void:
	mode = "wire"
	wire_tree = p_tree
	pens = []
	tex = null
	display_origin = p_origin
	display_scale = p_scale
	progress = 1.0
	_done = true
	queue_redraw()


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
	match mode:
		"wire":
			_draw_wire()
		"tex":
			if tex != null:
				var w := float(TP.W) * display_scale
				var h := float(TP.H) * display_scale
				# 贴图锚点 = 画布中轴 × 地面线（y=660）——tex 绘制以左上角定位
				var top_left := display_origin - Vector2(w * 0.5, 660.0 * display_scale)
				draw_texture_rect(tex, Rect2(top_left, Vector2(w, h)), false)
		"pens":
			_draw_pens()


func _draw_pens() -> void:
	if pens.is_empty() or progress <= 0.0:
		return
	var n := int(progress * pens.size())
	var sc := display_scale
	var ox := display_origin
	for i: int in n:
		var p: Dictionary = pens[i]
		# 贴图原生坐标(x 居中 192 / y 向下 ground 660) → 锚点向上
		var a: Vector2 = Vector2((p["a"].x - 192.0) * sc, (p["a"].y - 660.0) * sc) + ox
		var b: Vector2 = Vector2((p["b"].x - 192.0) * sc, (p["b"].y - 660.0) * sc) + ox
		var w: float = float(p["w"]) * sc
		var c: Color = p["c"]
		var al: float = p.get("al", 1.0)
		if al < 0.999:
			c.a = clampf(c.a * al + 0.02, 0.0, 1.0)  # 低 alpha 笔（罩染）示意
		draw_line(a, b, c, w)
		draw_circle(a, w * 0.5, c)
		draw_circle(b, w * 0.5, c)


## 结构线框：干矩形描边 + 枝线 + 冠圆描边（管线阶段①可视化）
func _draw_wire() -> void:
	var t := wire_tree
	var sc := display_scale
	var ox := display_origin
	var xf := func(p: Vector2) -> Vector2:
		return Vector2((p.x - 192.0) * sc, (p.y - 660.0) * sc) + ox
	var segs: Array = t.get("segs", [])
	for seg: Dictionary in segs:
		var x0: float = float(seg["xc"]) - float(seg["w"]) * 0.5
		var x1: float = float(seg["xc"]) + float(seg["w"]) * 0.5
		var tl: Vector2 = xf.call(Vector2(x0, float(seg["y_top"])))
		var tr: Vector2 = xf.call(Vector2(x1, float(seg["y_top"])))
		var bl: Vector2 = xf.call(Vector2(x0, float(seg["y_bot"])))
		var br: Vector2 = xf.call(Vector2(x1, float(seg["y_bot"])))
		var col := Color(0.15, 0.12, 0.08, 0.9)
		draw_line(tl, tr, col, 2.0)
		draw_line(bl, br, col, 2.0)
		draw_line(tl, bl, col, 2.0)
		draw_line(tr, br, col, 2.0)
	for br: Dictionary in t.get("branches", []):
		var path: PackedVector2Array = br["path"]
		for i: int in range(path.size() - 1):
			draw_line(xf.call(path[i]), xf.call(path[i + 1]), Color(0.3, 0.2, 0.1, 0.9), 2.0)
	for b: Dictionary in t.get("blobs", []):
		var c: Vector2 = xf.call(b["c"])
		draw_arc(c, float(b["r"]) * sc, 0.0, TAU, 40, Color(0.2, 0.35, 0.15, 0.8), 2.0)
		for sub: Vector3 in b.get("sub", []):
			draw_arc(xf.call(Vector2(sub.x, sub.y)), sub.z * sc, 0.0, TAU, 32,
				Color(0.2, 0.35, 0.15, 0.45), 1.5)
