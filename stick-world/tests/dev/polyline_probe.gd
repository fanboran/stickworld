extends Node2D
## join 行为探针 v2：三个不同外角的 V 形，线宽 32（半宽 16）
## 顶点 y=300。外缘理论：full miter = 300 - 16/cos(ext/2)；averaged = 300 - 16
var _t := 0.0
func _draw() -> void:
	# ext≈53°（dot≈0.6）：预测 averaged=284 / miter=282.1
	draw_polyline(PackedVector2Array([Vector2(200, 500), Vector2(600, 300), Vector2(1000, 500)]), Color.BLACK, 32.0)
	# ext≈36.9°（dot≈0.8）：averaged=384 / miter=380.1（x<1200 区域）
	draw_polyline(PackedVector2Array([Vector2(1300, 500), Vector2(1700, 300), Vector2(2100, 500)]), Color.BLACK, 32.0)
func _process(delta: float) -> void:
	_t += delta
	if _t > 0.3:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://tests/dev/polyline_probe_out.png")
		print("[pl-probe] saved")
		get_tree().quit()
