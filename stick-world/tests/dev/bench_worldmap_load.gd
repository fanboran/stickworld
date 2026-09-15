extends Node
## 战略图（world_map）加载/生成期热路径无头基准
##
## 运行：godot --headless --path . res://tests/dev/bench_worldmap_load.tscn
## 输出两种行（便于前后 diff 对比）：
##   BENCH <名称> <微秒>      —— 该项耗时（多次取最小）
##   FINGERPRINT <键> <哈希>  —— 加载产物/几何缓存逐点指纹（零回归校验用）
##
## 局限：_draw 内绘制命令的 GPU 成本无头测不到，这里只对 GDScript 侧
## 解析/几何/查询成本负责。

const DIR := "res://config/strategic_map"
const QUERY_N := 10000

var _results: Array = []  # [名称, usec]


func _ready() -> void:
	# 固定每局扰动种子：population_score jitter 确定性 → 指纹可跨运行复现
	WorldState.run_seed = 20260908
	_bench_loads()
	_bench_bakes()
	_bench_blob()
	_bench_queries()
	_bench_travel()
	_bench_flow_outline()
	_fingerprints()
	for r in _results:
		print("BENCH %s %d" % [r[0], int(r[1])])
	get_tree().quit(0)


# ===== 计时辅助：跑 reps 次取最小（消抖动），返回最后一次产物 =====

func _time(name: String, reps: int, fn: Callable) -> Variant:
	var best := INF
	var out: Variant = null
	for _i in reps:
		var t0 := Time.get_ticks_usec()
		out = fn.call()
		var dt := Time.get_ticks_usec() - t0
		if float(dt) < best:
			best = float(dt)
	_results.append([name, best])
	return out


## 纯 JSON 回退路径计时（get_file_as_string + parse + compact，模拟 bin 缺失时的真实成本）
static func _json_full(json_path: String, compact: bool) -> Variant:
	var jt := FileAccess.get_file_as_string(json_path)
	var parsed: Variant = JSON.parse_string(jt)
	if compact and parsed is Dictionary:
		return L3WorldData._compact_dict(parsed)
	return parsed


# ===== 1. 数据加载（bin 反序列化 vs JSON 解析分开计）=====

func _bench_loads() -> void:
	# --- L3（M 键打开时一次性加载：l3_world + l3_l1 + l3_city）---
	_time("L3.load_from 完整（bin 优先）", 2, func() -> Variant:
		return L3WorldData.load_from(DIR + "/l3_world.json", DIR))
	_time("L3.l3_world bin 反序列化", 2, func() -> Variant:
		return L3WorldData._read_data_dict(DIR + "/l3_world.json"))
	_time("L3.l3_world JSON 解析(含compact)", 1, func() -> Variant:
		return _json_full(DIR + "/l3_world.json", true))
	_time("L3.l3_l1 bin 反序列化", 2, func() -> Variant:
		return L3WorldData._read_data_dict(DIR + "/l3_l1.json"))
	_time("L3.l3_city bin 反序列化", 2, func() -> Variant:
		return L3WorldData._read_data_dict(DIR + "/l3_city.json"))

	# --- L1（出生包启动加载 + l1_packs 下钻按需）---
	_time("L1.出生包 load_from（bin）", 2, func() -> Variant:
		return L1WorldData.load_from(DIR + "/l1_world.json", DIR))
	_time("L1.出生包 JSON 解析", 1, func() -> Variant:
		return _json_full(DIR + "/l1_world.json", false))
	_time("L1.pack001 load_from（bin）", 2, func() -> Variant:
		return L1WorldData.load_from(DIR + "/l1_packs/l1_001/l1_world.json",
				DIR + "/l1_packs/l1_001"))

	# --- L2（L3 下钻按需：l2_world + l2_geom）---
	_time("L2.region_001 load_from 完整（bin）", 2, func() -> Variant:
		return L2WorldData.load_from(DIR + "/l2_packs/region_001/l2_world.json",
				DIR + "/l2_packs/region_001"))
	var l2 := L2WorldData.new()
	_time("L2.l2_world bin 反序列化", 2, func() -> Variant:
		return L2WorldData._read_data_dict(DIR + "/l2_packs/region_001/l2_world.json"))
	_time("L2.l2_world JSON 解析(含compact)", 1, func() -> Variant:
		return _json_full(DIR + "/l2_packs/region_001/l2_world.json", true))
	_time("L2.load_baked_geom(l2_geom.bin)", 3, func() -> Variant:
		l2.load_baked_geom(DIR + "/l2_packs/region_001/l2_geom.bin")
		return null)


# ===== 2. 渲染器烘焙（真实数据）=====

func _bench_bakes() -> void:
	# L3 渲染器：l1 层 mesh + blob 层 + L2 边界折线 + 蓝光轮廓
	var l3 := L3WorldData.load_from(DIR + "/l3_world.json", DIR)
	var r3: L3MapRenderer = L3MapRenderer.new()
	r3._data = l3
	var tiles: Array = l3.l1_tiles
	_time("L3._build_layer_mesh(69块老L1)", 2, func() -> Variant:
		return r3._build_layer_mesh(tiles))
	_time("L3._bake_blob_meshes(1040城)", 2, func() -> Variant:
		r3._bake_blob_meshes()
		return null)
	_time("L3._build_l2_border_cache", 2, func() -> Variant:
		r3._build_l2_border_cache()
		return null)
	_time("L3._build_glow_outlines", 2, func() -> Variant:
		r3._build_glow_outlines()
		return null)

	# L2 渲染器：静态 mesh（读烘焙几何）+ blob 层 + 描边展平
	var l2 := L2WorldData.load_from(DIR + "/l2_packs/region_001/l2_world.json",
			DIR + "/l2_packs/region_001")
	var r2: L2MapRenderer = L2MapRenderer.new()
	r2._data = l2
	_time("L2._build_static_mesh(region_001)", 3, func() -> Variant:
		r2._build_static_mesh()
		return null)

	# L1 渲染器（出生包）：blob 轮廓 + 静态几何缓存（描边段/道路分级）
	var l1 := L1WorldData.load_from(DIR + "/l1_world.json", DIR)
	var r1: MapRenderer = MapRenderer.new()
	r1._data = l1
	_time("L1.set_data（blob烘焙+glow）", 3, func() -> Variant:
		r1._segs_valid = false
		r1._bake_blob_outlines()
		r1._build_glow_outline()
		return null)
	_time("L1._build_cached_geometry", 3, func() -> Variant:
		r1._segs_valid = false
		r1._build_cached_geometry()
		return null)


# ===== 3. SettlementBlob.generate_outline 批量（L3 1040 城真实参数）=====

func _bench_blob() -> void:
	var l3 := L3WorldData.load_from(DIR + "/l3_world.json", DIR)
	var city_tiles: Array = l3.city_tiles
	_time("SettlementBlob.generate_outline x%d" % city_tiles.size(), 3, func() -> Variant:
		var acc := 0.0
		for t in city_tiles:
			var td: Dictionary = t
			var cap_var: Variant = td.get("blob_capacity", [])
			var cap := PackedFloat32Array()
			if cap_var is PackedFloat32Array:
				cap = cap_var
			elif cap_var is Array:
				for v in cap_var:
					cap.append(float(v))
			var src: Array = td.get("anchor", td.get("centroid", []))
			if src.size() < 2:
				continue
			var outline := SettlementBlob.generate_outline(
					"settlement_city_%03d" % int(td.get("label", 0)),
					int(td.get("level", 1)), cap, float(td.get("population_score", 0.0)))
			acc += outline[0].x
		return acc)
	_time("SettlementBlob.generate_outline 单城", 200, func() -> Variant:
		return SettlementBlob.generate_outline("settlement_city_001", 3,
				PackedFloat32Array(), 0.5))


# ===== 4. 高频查询：随机点 1 万次 =====

func _bench_queries() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var l3 := L3WorldData.load_from(DIR + "/l3_world.json", DIR)
	# 老 L1 索引图（异步加载完成后的稳态）：手动同步解码后挂上
	var f := FileAccess.open(DIR + "/l3_l1_index_8192.png", FileAccess.READ)
	var img := Image.new()
	img.load_png_from_buffer(f.get_buffer(f.get_length()))
	l3.l1_index_image = img
	var pts8k := PackedVector2Array()
	pts8k.resize(QUERY_N)
	for i in QUERY_N:
		pts8k[i] = Vector2(rng.randf() * 8192.0, rng.randf() * 8192.0)
	_time("L3.query_l1_at_map_pos x1万(8192索引图)", 3, func() -> Variant:
		var acc := 0
		for i in QUERY_N:
			acc += int((l3.query_l1_at_map_pos(pts8k[i])["l1"] as Dictionary).get("label", 0))
		return acc)
	var pts2k := PackedVector2Array()
	pts2k.resize(QUERY_N)
	for i in QUERY_N:
		pts2k[i] = pts8k[i] * (2048.0 / 8192.0)
	_time("L3.query_at_map_pos x1万(2048mask)", 3, func() -> Variant:
		var acc := 0
		for i in QUERY_N:
			acc += int((l3.query_at_map_pos(pts2k[i])["region"] as Dictionary).get("label", 0))
		return acc)

	# L2 索引图查询
	var l2 := L2WorldData.load_from(DIR + "/l2_packs/region_001/l2_world.json",
			DIR + "/l2_packs/region_001")
	var mw := float(l2.mask_image.get_width())
	var mh := float(l2.mask_image.get_height())
	_time("L2.query_at_map_pos x1万(索引图)", 3, func() -> Variant:
		var acc := 0
		for i in QUERY_N:
			var p := Vector2(rng.randf() * mw, rng.randf() * mh)
			acc += int((l2.query_at_map_pos(p)["tile"] as Dictionary).get("label", 0))
		return acc)


# ===== 5. travel_planner：真实路网 + 合成 1024 节点网格（vs AStar2D）=====

func _bench_travel() -> void:
	# 真实路网：出生 L1（当前 8 城邦规模）
	var l1 := L1WorldData.load_from(DIR + "/l1_world.json", DIR)
	var tp := TravelPlanner.new()
	var roads: Array = l1.roads
	_time("Travel.setup 真实路网(%d边)" % roads.size(), 3, func() -> Variant:
		tp.setup(roads)
		return null)
	var nodes := tp.get_nodes().size()
	_time("Travel.compute 真实路网(%d节点)" % nodes, 5, func() -> Variant:
		return tp.compute(tp.get_nodes()[0]))

	# 合成 1024 节点网格图（32x32，4 邻接；模拟"全大陆跨 L1 路网千级节点"）
	var GRID := 32
	var syn_roads: Array = []
	for y in GRID:
		for x in GRID:
			var a := "n_%03d" % (y * GRID + x)
			if x + 1 < GRID:
				syn_roads.append({"from": a, "to": "n_%03d" % (y * GRID + x + 1),
						"length_px": 10.0 + float((x + y) % 7), "polyline": [[0.0, 0.0], [10.0, 0.0]]})
			if y + 1 < GRID:
				syn_roads.append({"from": a, "to": "n_%03d" % ((y + 1) * GRID + x),
						"length_px": 10.0 + float((x * 3 + y) % 7), "polyline": [[0.0, 0.0], [10.0, 0.0]]})
	var tp2 := TravelPlanner.new()
	_time("Travel.setup 合成网格1024节点", 3, func() -> Variant:
		tp2.setup(syn_roads)
		return null)
	var q_from: String = tp2.get_nodes()[0]
	_time("Travel.compute 合成网格 单源 O(V²)", 3, func() -> Variant:
		return tp2.compute(q_from))
	# 50 对随机查询（find_path 每次全图 compute，与现 api 调用模式一致）
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pairs: Array = []
	var ids: Array[String] = tp2.get_nodes()
	for i in 50:
		pairs.append([ids[rng.randi_range(0, ids.size() - 1)], ids[rng.randi_range(0, ids.size() - 1)]])
	_time("Travel.find_path x50 合成网格", 3, func() -> Variant:
		var acc := 0.0
		for pr in pairs:
			acc += float(tp2.find_path(pr[0], pr[1])["length_px"])
		return acc)

	# Godot AStar2D 对照（同图同查询）：网格点按真实坐标摆放 → 边权 = 两点距离
	# = 合成图边长（10±扰动的近似），A* 启发式也对角可用——代表实际升级方案的最快形态
	var astar2 := AStar2D.new()
	var idx_of := {}
	for i in ids.size():
		var nid := int(ids[i].substr(2))
		@warning_ignore("integer_division")
		astar2.add_point(i + 1, Vector2(float(nid % GRID), float(nid / GRID)))
		idx_of[ids[i]] = i + 1
	for rd in syn_roads:
		astar2.connect_points(int(idx_of[str(rd["from"])]), int(idx_of[str(rd["to"])]), true)
	_time("AStar2D.find_path x50 合成网格", 3, func() -> Variant:
		var acc := 0.0
		for pr in pairs:
			var p := astar2.get_id_path(int(idx_of[pr[0]]), int(idx_of[pr[1]]))
			acc += float(p.size())
		return acc)
	_time("AStar2D.单对 get_id_path", 5, func() -> Variant:
		return astar2.get_id_path(1, ids.size()))


# ===== 6. FlowOutline.resample_closed 单次成本（真实 L1 出生轮廓）=====

func _bench_flow_outline() -> void:
	var l1 := L1WorldData.load_from(DIR + "/l1_world.json", DIR)
	var poly: PackedVector2Array = l1.l1_polygon
	_time("FlowOutline.resample_closed(%d点) 单次" % poly.size(), 500, func() -> Variant:
		return FlowOutline.resample_closed(poly))


# ===== 指纹：加载产物 + 几何缓存逐点哈希（前后 diff 验零回归）=====

func _fingerprints() -> void:
	# L3 数据 + 渲染烘焙产物
	var l3 := L3WorldData.load_from(DIR + "/l3_world.json", DIR)
	_fp("l3.regions", _fp_regions(l3))
	_fp("l3.l1_tiles", _hash(l3.l1_tiles))
	_fp("l3.city_tiles", _hash(l3.city_tiles))
	var r3: L3MapRenderer = L3MapRenderer.new()
	r3._data = l3
	r3._build_static_meshes()
	r3._build_glow_outlines()
	r3._build_l2_border_cache()
	_fp("l3mesh.l1_fill", _fp_mesh(r3._l1_mesh))
	_fp("l3mesh.l1_holes", _fp_mesh(r3._l1_holes_mesh))
	_fp("l3mesh.blob_fill", _fp_mesh(r3._blob_fill_mesh))
	_fp("l3mesh.blob_line", _fp_mesh(r3._blob_line_mesh))
	_fp("l3mesh.l2_borders", _fp_packed_list(r3._l2_border_polylines))
	_fp("l3mesh.glow", _fp_packed_list(r3._glow_outlines))

	# L2 数据 + 渲染烘焙产物
	var l2 := L2WorldData.load_from(DIR + "/l2_packs/region_001/l2_world.json",
			DIR + "/l2_packs/region_001")
	_fp("l2.tiles", _hash(l2.tiles))
	_fp("l2.cities", _hash(l2.cities))
	_fp("l2.rivers", _fp_rivers(l2.rivers))
	for i in l2.baked_meshes.size():
		_fp("l2.baked_mesh[%d]" % i, _fp_baked(l2.baked_meshes[i]))
	_fp("l2.border_segs", _fp_packed_list(l2.tile_border_segs))
	_fp("l2.neighbor_segs", _fp_packed_list(l2.neighbor_border_segs))
	var r2: L2MapRenderer = L2MapRenderer.new()
	r2._data = l2
	r2._build_static_mesh()
	_fp("l2mesh.blob_fill", _fp_mesh(r2._blob_fill_mesh))
	_fp("l2mesh.blob_line", _fp_mesh(r2._blob_line_mesh))
	_fp("l2mesh.tile_points", _hash(r2._tile_border_points))
	_fp("l2mesh.neighbor_points", _hash(r2._neighbor_border_points))

	# L1 数据 + 渲染烘焙产物
	var l1 := L1WorldData.load_from(DIR + "/l1_world.json", DIR)
	_fp("l1.tiles_polys", _fp_l1_tiles(l1))
	_fp("l1.roads", _fp_roads(l1.roads))
	var r1: MapRenderer = MapRenderer.new()
	r1._data = l1
	r1._bake_blob_outlines()
	r1._build_glow_outline()
	r1._build_cached_geometry()
	var blob_keys := r1._blob_outlines.keys()
	blob_keys.sort()
	var blob_fp := {}
	for k in blob_keys:
		blob_fp[k] = _hash(r1._blob_outlines[k])
	_fp("l1mesh.blobs", _hash(blob_fp))
	_fp("l1mesh.cached_segs", _hash(r1._cached_segs))
	_fp("l1mesh.l1_closed", _hash(r1._cached_l1_closed))
	_fp("l1mesh.glow", _hash(r1._glow_outline))
	_fp("l1mesh.neighbor_outlines", _fp_packed_list(r1._cached_neighbor_outlines))
	_fp("l1mesh.road_dirt", _hash(r1._road_dirt_segs))
	_fp("l1mesh.road_paved", _fp_packed_list(r1._road_paved_lines))

	# L2 blob/描边几何已含上面；travel 结果语义指纹（真实路网 + 合成网格）
	var tp := TravelPlanner.new()
	tp.setup(l1.roads)
	_fp("travel.birth_compute", _hash(tp.compute(tp.get_nodes()[0])))


func _fp(key: String, v: Variant) -> void:
	print("FINGERPRINT %s %d" % [key, hash(v)])


func _hash(v: Variant) -> Variant:
	return v


## regions：逐地区 label + land_polygons 顶点序列（bin/json 形态差异免疫：统一转 Vector2）
func _fp_regions(l3: L3WorldData) -> Array:
	var out: Array = []
	for r in l3.regions:
		var rd: Dictionary = r
		var polys: Array = rd.get("land_polygons", [rd.get("land_polygon", [])])
		var fps: Array = []
		for poly in polys:
			fps.append(_fp_poly(poly))
		out.append({"label": rd.get("label", 0), "polys": fps,
				"centroid": rd.get("centroid", [])})
	return out


## 多边形顶点统一 Vector2(x,y) 序列后哈希（兼容 [y,x] 数组 / Vector2 双形态）
func _fp_poly(poly: Variant) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if poly is PackedVector2Array:
		return poly
	if poly is Array:
		for p in poly:
			pts.append(p if p is Vector2 else Vector2(float(p[1]), float(p[0])))
	return pts


func _fp_packed_list(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(_fp_poly(v))
	return out


func _fp_mesh(mesh: ArrayMesh) -> Array:
	if mesh == null:
		return []
	var out: Array = []
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		out.append([
			_hash(arrays[Mesh.ARRAY_VERTEX] if arrays.size() > Mesh.ARRAY_VERTEX else null),
			_hash(arrays[Mesh.ARRAY_COLOR] if arrays.size() > Mesh.ARRAY_COLOR else null),
			_hash(arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null),
		])
	return out


func _fp_baked(baked: Dictionary) -> Array:
	return [_hash(baked.get("verts")), _hash(baked.get("colors")), _hash(baked.get("indices"))]


func _fp_l1_tiles(l1: L1WorldData) -> Array:
	var out: Array = []
	for t in l1.tiles:
		out.append({"id": t.tile_id, "owner": t.owner_state_id, "poly": _hash(t.polygon),
				"sid": t.settlement.settlement_id if t.settlement != null else "",
				"score": t.settlement.population_score if t.settlement != null else -1.0,
				"cap": _hash(t.settlement.blob_capacity) if t.settlement != null else 0})
	return out


func _fp_roads(roads: Array) -> Array:
	var out: Array = []
	for rd in roads:
		out.append([_hash(rd.get("pts")), rd.get("from"), rd.get("to"),
				rd.get("tier"), rd.get("length_px"), _hash(rd.get("biomes"))])
	return out


func _fp_rivers(rivers: Array) -> Array:
	var out: Array = []
	for rv in rivers:
		out.append([_hash(rv.get("pts")), rv.get("w")])
	return out
