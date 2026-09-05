extends Node2D
## 单棵预览树 —— 持有笔列表，逐笔生长动画（渲染过程展示），画完静止。
## 笔列表为贴图本地坐标（y 向下、ground=H-12），绘制时按 origin/scale 变换。

var pens: Array = []
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


func _process(_delta: float) -> void:
	if _done:
		return
	progress += speed
	if progress >= 1.0:
		progress = 1.0
		_done = true
	queue_redraw()


func _draw() -> void:
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
