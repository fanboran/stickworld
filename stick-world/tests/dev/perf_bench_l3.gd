extends SceneTree
## 性能基准：L3 战略图加载各阶段耗时（headless 运行）
## 运行：godot --headless --script res://tests/dev/perf_bench_l3.gd

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var json_text := FileAccess.get_file_as_string("res://config/strategic_map/l3_world.json")
	var t1 := Time.get_ticks_msec()
	print("read_json: %d ms (%d bytes)" % [t1 - t0, json_text.length()])
	var parsed: Variant = JSON.parse_string(json_text)
	var t2 := Time.get_ticks_msec()
	print("parse_json: %d ms" % [t2 - t1])
	var data: Dictionary = parsed
	var mask_path := "res://config/strategic_map/%s" % data.get("mask_texture", "l3_partition_2048.png")
	var tex: Texture2D = load(mask_path)
	var t3 := Time.get_ticks_msec()
	print("load_texture: %d ms" % [t3 - t2])
	var img: Image = tex.get_image()
	var t4 := Time.get_ticks_msec()
	print("get_image: %d ms" % [t4 - t3])
	# 模拟 L3MapRenderer._build_static_mesh 的三角剖分
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var tri_time := 0
	for r in (data.get("regions", []) as Array):
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			if (poly as Array).size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(Vector2(p[1], p[0]))
			var ts := Time.get_ticks_msec()
			var tri := Geometry2D.triangulate_polygon(pts2)
			tri_time += Time.get_ticks_msec() - ts
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in pts2:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(Color.WHITE)
			for idx in tri:
				indices.append(base + idx)
	var t5 := Time.get_ticks_msec()
	print("triangulate_all: %d ms (verts=%d)" % [tri_time, verts.size()])
	print("TOTAL data+mesh: %d ms" % [t5 - t0])
	quit()
