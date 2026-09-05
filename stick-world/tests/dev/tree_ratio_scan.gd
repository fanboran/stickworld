extends SceneTree
## 参数扫描：干:冠 视觉像素比 → 找最接近 5:1 的 (bare_frac, trunk_frac) 组合。
## 比值口径：冠行=行内绿像素(g>r+10 且 g>b+10)≥5 的行；冠底=自顶向下累计
## 绿像素达 97% 处的行（枝端团少量绿不拉低冠底）；干高=树底-冠底。
const TP := preload("res://tests/dev/tree_pipeline.gd")

const TARGET := 5.0


func _init() -> void:
	var best_err := 1e9
	var best := Vector2.ZERO
	for bare: float in [0.25, 0.32]:
		for trunk: float in [0.90, 0.93]:
			var acc := 0.0
			for sd: int in [7000]:
				var P := {"bare_frac": bare, "trunk_frac": trunk}
				var tree: Dictionary = TP.build_tree(sd, P, 500, 1200)
				var img := TP.rasterize(tree["pens"], tree["trunk_canvas"], tree["crown_canvas"])
				var ratio := measure(img)
				acc += ratio
			var avg := acc / 1.0
			var err := absf(avg - TARGET)
			if err < best_err:
				best_err = err
				best = Vector2(bare, trunk)
			print("bare=%.2f trunk=%.2f → 干:冠=%.2f" % [bare, trunk, avg])
	print("BEST: bare=%.2f trunk=%.2f (|err|=%.2f)" % [best.x, best.y, best_err])
	quit(0)


func measure(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var top := -1
	var bottom := -1
	var green_per_row := PackedInt32Array()
	green_per_row.resize(h)
	var total_green := 0
	for y: int in h:
		var g := 0
		for x: int in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				if top < 0:
					top = y
				bottom = y
				if c.g > c.r + 0.04 and c.g > c.b + 0.04:
					g += 1
		green_per_row[y] = g
		total_green += g
	if top < 0 or total_green < 50:
		return 0.0
	# 自顶向下累计绿像素到 97% 的行 = 冠底
	var acc := 0
	var crown_bottom := bottom
	for y: int in range(top, bottom + 1):
		acc += green_per_row[y]
		if float(acc) >= float(total_green) * 0.97:
			crown_bottom = y
			break
	var crown_h := crown_bottom - top + 1
	var trunk_h := bottom - crown_bottom
	return float(trunk_h) / float(maxi(crown_h, 1))
