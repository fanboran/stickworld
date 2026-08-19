extends SceneTree

func _init() -> void:
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill_rect(Rect2i(0, 0, 16, 16), Color(0.1, 0.2, 0.3))
	var pts := PackedVector2Array([Vector2(2, 2), Vector2(10, 2), Vector2(10, 6), Vector2(6, 6), Vector2(6, 12), Vector2(2, 12)])
	img.fill_polygon(pts, Color(0.9, 0.1, 0.1))
	var o1: Color = img.get_pixel(11, 3)
	var o2: Color = img.get_pixel(3, 13)
	var i1: Color = img.get_pixel(3, 3)
	var i2: Color = img.get_pixel(7, 10)
	var ok: bool = i1.r > 0.8 and i2.r > 0.8 and o1.r < 0.5 and o2.r < 0.5
	print("concave fill ok=", ok, " inner=", i1, ",", i2, " gap=", o1, ",", o2)
	quit()
