extends SceneTree
## 诊断：枝端叶团在管线里的实际覆盖情况（blobs 数量/枝端团位置/局部覆盖率）
const TP := preload("res://tests/dev/tree_pipeline.gd")


func _init() -> void:
	var tree: Dictionary = TP.build_tree(7519, {}, 1400, 3400)
	var wire: Dictionary = tree["wire"]
	print("branches=%d blobs=%d" % [(wire["branches"] as Array).size(),
		(wire["blobs"] as Array).size()])
	var img := TP.rasterize(tree["pens"], tree["trunk_canvas"], tree["crown_canvas"])
	img.save_png("res://../temp/stroke_ref/gdlab/diag_v.png")
	# 主团 vs 枝端团的局部覆盖率
	var blobs: Array = wire["blobs"]
	var main: Dictionary = blobs[0]
	_report_cover(img, main["c"], main["r"], "主团")
	# 每根枝的 tip 与最近团心的距离 + 该枝端团覆盖率
	for br: Dictionary in wire["branches"]:
		var tip: Vector2 = br["tip"]
		var best_d := 1e9
		var best_b: Dictionary = {}
		for b: Dictionary in blobs:
			var d: float = Vector2(b["c"]).distance_to(tip)
			if d < best_d:
				best_d = d
				best_b = b
		print("枝 tip(%d,%d) 枝长%.0f 最近团r=%.0f 团距=%.0f(负=团心过梢)" % [int(tip.x), int(tip.y),
			(tip - (br["path"] as PackedVector2Array)[0]).length(),
			float(best_b["r"]), best_d])
	var small_n := 0
	for b: Dictionary in blobs:
		if float(b["r"]) < 55.0:
			small_n += 1
			if small_n <= 6:
				_report_cover(img, b["c"], float(b["r"]), "小团r=%.0f" % float(b["r"]))
	quit(0)


func _report_cover(img: Image, c: Vector2, r: float, tag: String) -> void:
	var hit := 0
	var tot := 0
	for y: int in range(maxi(int(c.y - r), 0), mini(int(c.y + r), TP.H - 1)):
		for x: int in range(maxi(int(c.x - r), 0), mini(int(c.x + r), TP.W - 1)):
			if Vector2(x, y).distance_to(c) <= r:
				tot += 1
				if img.get_pixel(x, y).a > 0.5:
					hit += 1
	print("%s at(%d,%d) r=%.0f 覆盖率 %.0f%%" % [tag, int(c.x), int(c.y), r,
		100.0 * float(hit) / float(maxi(tot, 1))])
