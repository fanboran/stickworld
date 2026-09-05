extends SceneTree
## tree_pipeline.gd 的 headless 验证：GD 移植管线产出 vs Python 基线贴图（v0-v9）
## 同一套数值指标对比（交接文档 §1 基线特征）：
##   高宽比 1.73~2.26 / alpha 只 0/255 两档 / 内部无洞（缝隙只在边缘）/
##   干区均色 R-G 差 22~31（纯棕）/ 干笔触垂直占比 / 覆盖密度 / 各层实际落笔数
## 运行：godot --headless --path stick-world --script res://tests/dev/tree_pipeline_check.gd
## 输出 PNG → 仓库根 temp/stroke_ref/gdlab/

const TP := preload("res://tests/dev/tree_pipeline.gd")

var out_dir := ""


func _init() -> void:
	var root := ProjectSettings.globalize_path("res://")
	out_dir = root.path_join("../temp/stroke_ref/gdlab").simplify_path()
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("=== GD 管线产出（默认参数 = 基线） ===")
	for i: int in 4:
		var sd := 7000 + i * 173
		var t0 := Time.get_ticks_msec()
		var tree: Dictionary = TP.build_tree(sd, {}, 1400, 3400)
		var t1 := Time.get_ticks_msec()
		var img := TP.rasterize(tree["pens"])
		var t2 := Time.get_ticks_msec()
		img.save_png(out_dir.path_join("gd_v%d.png" % i))
		var m := analyze(img)
		print("gd_v%d  生成 %dms 栅格 %dms  %s" % [i, t1 - t0, t2 - t1, fmt(m)])
		print("   层落笔: 干 %s / 冠 %s / 枝 %d" % [
			fmt_layers(tree["stats"].get("trunk_layers", [])),
			fmt_layers(tree["stats"].get("crown_layers", [])),
			int(tree["stats"].get("branch", 0))])
	print("")
	print("=== Python 基线贴图（用户认可版） ===")
	for i: int in 10:
		var img: Image = load_png("res://assets/resources/tree_paint_tree_v%d.png" % i)
		if img == null:
			print("v%d 读取失败" % i)
			continue
		var m := analyze(img)
		print("py_v%d  %s" % [i, fmt(m)])
	quit(0)


func load_png(res_path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(res_path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	return null if err != OK else img


func fmt_layers(layers: Array) -> String:
	var parts := PackedStringArray()
	for l: Dictionary in layers:
		parts.append("%s %d/%d" % [String(l["name"]), int(l["got"]), int(l["req"])])
	return " ".join(parts)


func fmt(m: Dictionary) -> String:
	return "高宽比 %.2f | 中间alpha %.2f%% | 内部洞 %.2f%% | 干区R-G %.1f | 干笔垂直占比 %.0f%% | 密度 %.1f%% | 边缘粗糙 %.3f" % [
		float(m["aspect"]), 100.0 * float(m["mid_alpha"]), 100.0 * float(m["holes"]),
		float(m["trunk_rg"]), 100.0 * float(m["trunk_vert"]), 100.0 * float(m["density"]),
		float(m["edge_rough"])]


## 数值指标（对 GD 产物与基线贴图跑同一套）
func analyze(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var opq := PackedByteArray()
	opq.resize(w * h)
	var n_opq := 0
	var n_mid := 0
	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y: int in h:
		for x: int in w:
			var a := int(img.get_pixel(x, y).a8)
			if a > 0 and a < 255:
				n_mid += 1
			if a >= 128:
				opq[y * w + x] = 1
				n_opq += 1
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	# 内部洞：从边界洪泛透明像素，没被淹到又透明的 = 内部洞
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack: Array[int] = []
	for x: int in w:
		for y: int in [0, h - 1]:
			if not opq[y * w + x]:
				seen[y * w + x] = 1
				stack.append(y * w + x)
	for y: int in h:
		for x: int in [0, w - 1]:
			if not opq[y * w + x] and not seen[y * w + x]:
				seen[y * w + x] = 1
				stack.append(y * w + x)
	while not stack.is_empty():
		var i: int = stack.pop_back()
		var x := i % w
		var y := i / w
		for d: int in 4:
			var nx: int = x + [1, -1, 0, 0][d]
			var ny: int = y + [0, 0, 1, -1][d]
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var j: int = ny * w + nx
			if not opq[j] and not seen[j]:
				seen[j] = 1
				stack.append(j)
	var n_holes := 0
	for i: int in w * h:
		if not opq[i] and not seen[i]:
			n_holes += 1
	# 干区均色（下部中轴）与干笔触方向（结构张量）
	var sum_r := 0.0
	var sum_g := 0.0
	var n_tr := 0
	var vert_w := 0.0
	var tot_w := 0.0
	var cx := w / 2.0
	for y: int in range(int(h * 0.72), h - 1):
		for x: int in range(maxi(int(cx - w * 0.10), 1), mini(int(cx + w * 0.10), w - 1)):
			if not opq[y * w + x]:
				continue
			var c := img.get_pixel(x, y)
			sum_r += c.r8
			sum_g += c.g8
			n_tr += 1
			# 3×3 结构张量主方向（垂直于梯度）
			var gx := gray(img, x + 1, y) - gray(img, x - 1, y)
			var gy := gray(img, x, y + 1) - gray(img, x, y - 1)
			var mag := sqrt(gx * gx + gy * gy)
			if mag < 6.0:
				continue
			var ang := atan2(gy, gx) + PI / 2.0
			ang = fposmod(ang, PI)
			var vert: float = absf(cos(ang))  # 1=水平 0=垂直
			vert_w += (1.0 - vert) * mag
			tot_w += mag
	# 边缘粗糙度：不透明像素中邻接透明的比例（周长/面积）
	var n_edge := 0
	for y: int in range(1, h - 1):
		for x: int in range(1, w - 1):
			if not opq[y * w + x]:
				continue
			if not opq[y * w + x - 1] or not opq[y * w + x + 1] \
					or not opq[(y - 1) * w + x] or not opq[(y + 1) * w + x]:
				n_edge += 1
	return {
		"aspect": float(max_y - min_y + 1) / float(max_x - min_x + 1),
		"mid_alpha": float(n_mid) / float(w * h),
		"holes": float(n_holes) / float(maxi(n_opq, 1)),
		"trunk_rg": (sum_r - sum_g) / float(maxi(n_tr, 1)),
		"trunk_vert": vert_w / maxf(tot_w, 1.0),
		"density": float(n_opq) / float(w * h),
		"edge_rough": float(n_edge) / float(maxi(n_opq, 1)),
	}


func gray(img: Image, x: int, y: int) -> float:
	var c := img.get_pixel(x, y)
	return (c.r8 + c.g8 + c.b8) / 3.0
