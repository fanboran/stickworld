extends RefCounted
## MapRenderer 静态几何库 —— 战略图渲染的纯几何工具与静态层烘焙（全 static、无状态；
## 宿主 map_renderer.gd 经 const preload 调用，不写 class_name 防全局类循环引用）。
##
## 子域索引：
##   点列工具：pts / closed / dist_point_segment
##   邻湖判定（城界描边跳过湖边用）：lake_edge_tol / lake_bbox / edge_touches_lake_fast
##   静态几何缓存：build_cached_geometry（城界无向边去重段 / 出生 L1 轮廓 /
##     邻居空心轮廓 / 河流折线 / 道路分级）
##   静态底色 mesh：bake_base_meshes / mesh_from_pairs
## 需要读写宿主状态的方法第一参传宿主 h（FlowOutline 传 canvas 同款先例），
## 其余为纯函数；线宽/色 token 真相源在宿主 MapTokens 别名层（经 h 取用），
## 本文件零新增数值/色值字面量（与拆分前逐行等价）。


## Array[[x,y],...] -> PackedVector2Array
static func pts(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in arr:
		if pt is Array and pt.size() >= 2:
			out.append(Vector2(float(pt[0]), float(pt[1])))
	return out


## 闭合多边形点列（首尾相连）
static func closed(pts_in: PackedVector2Array) -> PackedVector2Array:
	if pts_in.size() < 3:
		return pts_in
	var out := pts_in.duplicate()
	out.append(out[0])
	return out


## 点到线段的最短距离
static func dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 邻湖判定容差（地图单元）：边中点距湖多边形 ≤ 该值视为"地块-湖泊"边界不描边。
## 8192 级 context 下沿湖边 ~0-10、最近非湖边 ~10.1，取 context 1%（798≈8）安全。
static func lake_edge_tol(data: L1WorldData) -> float:
	var tol := 4.0
	if data.context_size.x > 0:
		tol = data.context_size.x * 0.01
	return tol


## 湖多边形包围盒（外扩 tol）——邻湖判定预筛用
static func lake_bbox(lake: Array, tol: float) -> Rect2:
	var bb := Rect2()
	var first := true
	for pt in pts(lake):
		if first:
			bb = Rect2(pt, Vector2.ZERO)
			first = false
		else:
			bb = bb.expand(pt)
	return bb.grow(tol)


## 边中点是否贴着某湖（bbox 预筛加速版）：中点不在任何湖 bbox 内直接 false
static func edge_touches_lake_fast(data: L1WorldData, a: Vector2, b: Vector2, tol: float,
		lake_boxes: Array[Rect2]) -> bool:
	if lake_boxes.is_empty():
		return false
	var mid := (a + b) * 0.5
	for li in range(lake_boxes.size()):
		if not lake_boxes[li].has_point(mid):
			continue
		var lpts := pts(data.lakes[li])
		var ln := lpts.size()
		for i in range(ln):
			if dist_point_segment(mid, lpts[i], lpts[(i + 1) % ln]) <= tol:
				return true
	return false


## 构建不随 zoom/hover 变化的静态几何缓存（写回宿主 _cached_segs / _cached_l1_closed /
## _cached_neighbor_outlines / _river_lines / _river_widths / _road_dirt_lines /
## _road_paved_lines / _segs_valid）：城市描边段（跳过邻湖边）+ 出生 L1 轮廓
## + 邻居空心轮廓（A3）+ 河流折线。仅 set_data / 首帧调用一次。
## feedback1 去抖动：缓存存原始平滑点列（直绘，Godot antialiased）；
## 无向边去重保留——共享边只描一次，线条严丝合缝不叠双线。
static func build_cached_geometry(h) -> void:
	h._cached_segs = PackedVector2Array()
	h._cached_l1_closed = PackedVector2Array()
	# 宿主缓存为元素类型化数组（Array[PackedVector2Array]）：跨脚本动态赋普通 []
	# 会被运行时拒绝（Invalid assignment），类型化数组须 clear() 就地清空
	# 宿主缓存为元素类型化数组（Array[PackedVector2Array]）：跨脚本动态赋普通 []
	# 会被运行时拒绝（Invalid assignment）且中止本函数，后续构建全部跳过；
	# 类型化数组须 clear() 就地清空
	h._cached_neighbor_outlines.clear()
	h._river_lines.clear()
	h._river_widths = PackedFloat32Array()
	# 邻居空心轮廓（闭合折线缓存）
	for ni in h._data.neighbors.size():
		for poly in h._data.neighbors[ni].get("polygons", []):
			var npts := pts(poly)
			if npts.size() >= 3:
				h._cached_neighbor_outlines.append(closed(npts))
	var lake_tol := lake_edge_tol(h._data)
	# 湖 bbox（外扩 tol）预筛：段中点不在任何湖 bbox 内 → 直接非邻湖，省精确距离计算
	var lake_boxes: Array[Rect2] = []
	for lake in h._data.lakes:
		lake_boxes.append(lake_bbox(lake, lake_tol))
	# 城界描边段：无向边去重（相邻 tile 共享边只描一次——同一物理边一份描边，
	# 端点与邻边共点，三岔交界严丝合缝）
	var seen_edges := {}
	for tile in h._data.tiles:
		if tile.polygon.size() < 3:
			continue
		var tpts = tile.polygon
		var n = tpts.size()
		for i in range(n):
			var a = tpts[i]
			var b = tpts[(i + 1) % n]
			if edge_touches_lake_fast(h._data, a, b, lake_tol, lake_boxes):
				continue
			var key := MapSketch.edge_key(a, b)
			if seen_edges.has(key):
				continue
			seen_edges[key] = true
			h._cached_segs.append(a)
			h._cached_segs.append(b)
	# L1 权威轮廓 = 主大陆单环（export 已保证 l1_polygon 只含最大环）——闭合缓存
	if h._data.l1_polygon.size() >= 3:
		h._cached_l1_closed = closed(h._data.l1_polygon)
	# 河流折线（矢量回退层；宽随河流数据）
	for ri in h._data.rivers.size():
		var rv: Dictionary = h._data.rivers[ri]
		var rpts: PackedVector2Array = rv.get("pts", PackedVector2Array())
		if rpts.size() >= 2:
			h._river_lines.append(rpts)
			h._river_widths.append(maxf(float(rv.get("w", 2.0)), h.RIVER_MIN_WIDTH))
	# 道路分级（R6 实线分级，废 F5 虚线切分）：土路细 / 官道粗；
	# 仅交通模式矢量回退时绘制（正常观感走 l1_travel.png 贴图）
	h._road_dirt_lines.clear()
	h._road_paved_lines.clear()
	for rd in h._data.roads:
		var rdpts: PackedVector2Array = rd.get("pts", PackedVector2Array())
		if rdpts.size() < 2:
			continue
		if str(rd.get("tier", "DIRT")) == "PAVED":
			h._road_paved_lines.append(rdpts)
		else:
			h._road_dirt_lines.append(rdpts)
	h._segs_valid = true


## 烘焙静态色块层（写回宿主 _tiles_mesh / _lakes_mesh / _neighbors_mesh）：
## 城市色块与湖泊各一张 ArrayMesh（顶点色，三角形独立顶点）。
## Geometry2D.triangulate_polygon 一次性 earcut（C++，含凹多边形），仅 set_data / 首帧调用一次。
## 邻居老 L1 块不参与（A3 空心化：只描边不填充，轮廓走 build_cached_geometry 缓存）。
## 拆两张 mesh：河流画在两层层间（tiles 上、lakes 下），见宿主 _draw 1.5 层。
static func bake_base_meshes(h) -> void:
	h._tiles_mesh = null
	h._lakes_mesh = null
	h._neighbors_mesh = null
	var ctx = h._data.context_size
	if ctx.x <= 0 or ctx.y <= 0:
		return
	# 收集 (多边形, 颜色)：海洋 = 全矩形底由渲染器背景承担（OCEAN 回退分支 + 相机外区域）
	var tile_pairs: Array = []   # [[PackedVector2Array, Color], ...]
	var lake_pairs: Array = []
	var neighbor_pairs: Array = []
	for tile in h._data.tiles:
		if tile.polygon.size() >= 3:
			tile_pairs.append([tile.polygon, h._data.get_state_color(tile.owner_state_id)])
	for lake in h._data.lakes:
		lake_pairs.append([pts(lake), h.LAKE_COLOR])
	for ni in h._data.neighbors.size():
		for poly in h._data.neighbors[ni].get("polygons", []):
			var npts := pts(poly)
			if npts.size() >= 3:
				neighbor_pairs.append([npts, h.NEIGHBOR_COLOR])
	h._tiles_mesh = mesh_from_pairs(tile_pairs)
	h._lakes_mesh = mesh_from_pairs(lake_pairs)
	h._neighbors_mesh = mesh_from_pairs(neighbor_pairs)


## 多边形组 → 顶点色 ArrayMesh（每三角形独立顶点，避免共享顶点颜色冲突）
static func mesh_from_pairs(pairs: Array) -> ArrayMesh:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	for pair in pairs:
		var pair_pts: PackedVector2Array = pair[0]
		if pair_pts.size() < 3:
			continue
		var tris := Geometry2D.triangulate_polygon(pair_pts)
		if tris.is_empty():
			continue
		for i in range(0, tris.size(), 3):
			for k in range(3):
				verts.append(pair_pts[tris[i + k]])
				cols.append(pair[1])
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
