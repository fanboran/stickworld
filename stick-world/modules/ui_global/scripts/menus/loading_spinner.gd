extends Control
## 加载环 —— 自绘旋转圆弧（载入屏用）。
## 琥珀色圆弧绕圆心旋转，无资产依赖。

var _angle: float = 0.0


func _process(delta: float) -> void:
	_angle += delta * 4.0
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.4
	# 底环（低透明）
	draw_arc(center, radius, 0.0, TAU, 24, StickTokens.BORDER, 3.0)
	# 前景弧（琥珀，约 1/4 圆，绕圆心旋转）
	draw_arc(center, radius, _angle, _angle + TAU * 0.25, 24, StickTokens.ACCENT, 3.0)
