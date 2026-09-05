extends Node2D
## 烘焙画布 —— SubViewport 内全量绘制一棵笔触树（笔列表为贴图原生坐标，直接画）。


var pens: Array = []


func setup(p_pens: Array) -> void:
	pens = p_pens
	queue_redraw()


func _draw() -> void:
	for p in pens:
		var a: Vector2 = p["a"]
		var b: Vector2 = p["b"]
		var w: float = p["w"]
		draw_line(a, b, p["c"], w)
		draw_circle(a, w * 0.5, p["c"])
		draw_circle(b, w * 0.5, p["c"])
