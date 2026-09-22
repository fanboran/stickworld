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
	return polyline_bbox(pts(lake), tol)


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


## 折线包围盒（外扩 reach）——河流/湖泊贴边判定预筛用
static func polyline_bbox(rpts: PackedVector2Array, grow: float) -> Rect2:
	var bb := Rect2()
	var first := true
	for pt in rpts:
		if first:
			bb = Rect2(pt, Vector2.ZERO)
			first = false
		else:
			bb = bb.expand(pt)
	return bb.grow(grow)


# ───────────────────────── 矩形裁剪（邻省完整渲染用）─────────────────────────
## 邻包 context 与本包窗口只部分相交，邻包的城块多边形/城块界必须裁进窗口才能画
## （不裁会把窗口外的半张省画到装裱框外的海洋背景上）。裁剪区一律是轴对齐矩形。

## 凸多边形矩形裁剪（Sutherland–Hodgman，四条边依次裁）。裁剪区为矩形（凸）时
## 结果是一条闭合多边形（沿裁剪边可能出现共线点，填充无碍）。退化返回空数组。
static func clip_polygon_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var out := poly
	for edge in 4:
		out = _clip_polygon_edge(out, edge, rect)
		if out.size() < 3:
			return PackedVector2Array()
	return out


## 单边裁剪（edge：0 左 / 1 右 / 2 上 / 3 下）
static func _clip_polygon_edge(poly: PackedVector2Array, edge: int, rect: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	if n == 0:
		return out
	for i in n:
		var cur := poly[i]
		var prev := poly[(i - 1 + n) % n]
		var cur_in := _inside_edge(cur, edge, rect)
		var prev_in := _inside_edge(prev, edge, rect)
		if cur_in:
			if not prev_in:
				out.append(_cross_edge(prev, cur, edge, rect))
			out.append(cur)
		elif prev_in:
			out.append(_cross_edge(prev, cur, edge, rect))
	return out


static func _inside_edge(p: Vector2, edge: int, rect: Rect2) -> bool:
	match edge:
		0: return p.x >= rect.position.x
		1: return p.x <= rect.end.x
		2: return p.y >= rect.position.y
		_: return p.y <= rect.end.y


## 线段与裁剪边交点的参数插值（边与线段不平行；调用方保证两端一内一外）
static func _cross_edge(a: Vector2, b: Vector2, edge: int, rect: Rect2) -> Vector2:
	var d := b - a
	var t := 0.0
	match edge:
		0:
			t = (rect.position.x - a.x) / d.x if absf(d.x) > 0.000001 else 0.0
		1:
			t = (rect.end.x - a.x) / d.x if absf(d.x) > 0.000001 else 0.0
		2:
			t = (rect.position.y - a.y) / d.y if absf(d.y) > 0.000001 else 0.0
		_:
			t = (rect.end.y - a.y) / d.y if absf(d.y) > 0.000001 else 0.0
	return a + d * clampf(t, 0.0, 1.0)


## 折线矩形裁剪：逐段 Liang–Barsky，相邻存活段接续成链（不引入沿裁剪边的假边——
## 城块界在窗口边界处必须收笔，否则会沿装裱框画出一圈灰线）。返回若干条折线。
static func clip_polyline_rect(pts: PackedVector2Array, rect: Rect2) -> Array:
	var out: Array = []
	var run := PackedVector2Array()
	for i in range(pts.size() - 1):
		var seg := clip_segment_rect(pts[i], pts[i + 1], rect)
		if seg.is_empty():
			if run.size() >= 2:
				out.append(run)
			run = PackedVector2Array()
			continue
		if run.is_empty():
			run = PackedVector2Array([seg[0]])
		run.append(seg[1])
	if run.size() >= 2:
		out.append(run)
	return out


## 单段 Liang–Barsky 裁剪：返回空（全外）/ [入点, 出点]
static func clip_segment_rect(a: Vector2, b: Vector2, rect: Rect2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var p := PackedFloat32Array([-dx, dx, -dy, dy])
	var q := PackedFloat32Array([
		a.x - rect.position.x, rect.end.x - a.x,
		a.y - rect.position.y, rect.end.y - a.y,
	])
	var t0 := 0.0
	var t1 := 1.0
	for i in 4:
		var pi: float = p[i]
		if absf(pi) < 0.000001:
			if q[i] < 0.0:
				return PackedVector2Array()   # 平行且在裁剪区外
			continue
		var r: float = q[i] / pi
		if pi < 0.0:
			if r > t1:
				return PackedVector2Array()
			if r > t0:
				t0 = r
		else:
			if r < t0:
				return PackedVector2Array()
			if r < t1:
				t1 = r
	if t1 < t0:
		return PackedVector2Array()
	return PackedVector2Array([a + Vector2(dx, dy) * t0, a + Vector2(dx, dy) * t1])


## 边中点是否贴着某条河（骨架中心线 + 半河宽）：贴陆后河岸即城块界线，
## 描边会沿河岸把河框起来读作「河流被描边」——贴河边与贴湖边同样跳过不描。
## 河折线**端点**（入海口/入湖口）邻域同样跳过：海岸描边语义到河口收笔，
## 否则两侧海岸描边在河口合拢，河口读作被框住的「小海湾」。
static func edge_touches_river_fast(a: Vector2, b: Vector2, tol: float,
		river_lines: Array, river_widths: PackedFloat32Array,
		river_boxes: Array[Rect2]) -> bool:
	if river_boxes.is_empty():
		return false
	var mid := (a + b) * 0.5
	for ri in range(river_boxes.size()):
		if not river_boxes[ri].has_point(mid):
			continue
		var lpts: PackedVector2Array = river_lines[ri]
		var reach := tol + float(river_widths[ri]) * 0.5
		if mid.distance_to(lpts[0]) <= reach or mid.distance_to(lpts[lpts.size() - 1]) <= reach:
			return true
		for i in range(lpts.size() - 1):
			if dist_point_segment(mid, lpts[i], lpts[i + 1]) <= reach:
				return true
	return false


## 构建不随 zoom/hover 变化的静态几何缓存（写回宿主 _cached_tile_chains / _cached_l1_closed /
## _cached_neighbor_outlines / _river_lines / _river_widths / _road_dirt_lines /
## _road_paved_lines / _segs_valid）：城界描边**链**（跳过贴水面边[湖/河]）+ 出生 L1 轮廓
## + 邻居空心轮廓（A3）+ 河流折线。仅 set_data / 首帧调用一次。
## feedback1 去抖动：缓存存原始平滑点列（直绘，Godot antialiased）。
## ⚠️ 城界由「无向边去重段 + draw_multiline」改为「逐地块成链 + draw_polyline」：
## draw_multiline 逐段各带自己的端点外伸，三岔口三条边各自探头 → 灰线读作分叉
## （创始人反馈）；成链后链内相邻段共顶点成折角，交汇处不再外伸。共享边两侧地块
## 各画一遍（同色同宽，叠画无痕），代价是段数 ×2，地块数量级（8~29）下可忽略。
static func build_cached_geometry(h) -> void:
	h._cached_l1_closed = PackedVector2Array()
	# 宿主缓存为元素类型化数组（Array[PackedVector2Array]）：跨脚本动态赋普通 []
	# 会被运行时拒绝（Invalid assignment）且中止本函数，后续构建全部跳过；
	# 类型化数组须 clear() 就地清空
	h._cached_neighbor_outlines.clear()
	h._cached_tile_chains.clear()
	h._river_lines.clear()
	h._river_widths = PackedFloat32Array()
	# 邻居空心轮廓（闭合折线缓存）
	for ni in h._data.neighbors.size():
		for poly in h._data.neighbors[ni].get("polygons", []):
			var npts := pts(poly)
			if npts.size() >= 3:
				h._cached_neighbor_outlines.append(closed(npts))
	# 河流折线（矢量水体层 + 城界描边贴河判定的数据源；宽随河流数据）
	for ri in h._data.rivers.size():
		var rv: Dictionary = h._data.rivers[ri]
		var rpts: PackedVector2Array = rv.get("pts", PackedVector2Array())
		if rpts.size() >= 2:
			h._river_lines.append(rpts)
			h._river_widths.append(maxf(float(rv.get("w", 2.0)), h.RIVER_MIN_WIDTH))
	var water_tol := lake_edge_tol(h._data)
	# 湖/河 bbox（外扩 tol）预筛：段中点不在任何 bbox 内 → 直接不贴，省精确距离计算
	var lake_boxes: Array[Rect2] = []
	for lake in h._data.lakes:
		lake_boxes.append(lake_bbox(lake, water_tol))
	var river_boxes: Array[Rect2] = []
	for ri in range(h._river_lines.size()):
		river_boxes.append(polyline_bbox(
			h._river_lines[ri], water_tol + float(h._river_widths[ri]) * 0.5))
	# 城界描边链：逐地块按点序成链（跳过贴水面段[湖/河] → 连续保留边自成一条链）；
	# 平行数组记 owner tile_id（政治模式国色描边按地块取色）
	for tile in h._data.tiles:
		if tile.polygon.size() < 3:
			continue
		for chain in tile_border_chains(h._data, tile.polygon, water_tol, lake_boxes,
				h._river_lines, h._river_widths, river_boxes):
			h._cached_tile_chains.append(chain)
	# 三岔交汇点（补圆盖外凸尖用）
	h._cached_junctions = junction_points(h._data)
	# L1 权威轮廓 = 主大陆单环（export 已保证 l1_polygon 只含最大环）——闭合缓存
	if h._data.l1_polygon.size() >= 3:
		h._cached_l1_closed = closed(h._data.l1_polygon)
	# 道路分级（R6 实线分级，废 F5 虚线切分）：土路细 / 官道粗；
	# 交通层开关打开时矢量绘制（底图不含道路，交通层为本包道路的唯一呈现）
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


## 交汇点（≥3 个地块共享的顶点，按 0.05px 量化归并）。
## 用途：绘制端在这些点补一个同色小圆——"灰线分叉"的真因是各环在交汇处各自成折角，
## 折角外侧倒角沿各自方向外凸（实测三块边界几何共点，最小线段距 0.000px，纯渲染层问题），
## 补圆把外凸尖盖住，三条线读作汇于一点。仅 set_data/首帧构建一次。
static func junction_points(data: L1WorldData) -> PackedVector2Array:
	var users: Dictionary = {}
	for tile in data.tiles:
		if tile.polygon.size() < 3:
			continue
		for p in tile.polygon:
			var key := "%d_%d" % [roundi(p.x * 20.0), roundi(p.y * 20.0)]
			if not users.has(key):
				users[key] = {"pt": p, "n": 0, "tiles": {}}
			var e: Dictionary = users[key]
			if not (e["tiles"] as Dictionary).has(tile.tile_id):
				(e["tiles"] as Dictionary)[tile.tile_id] = true
				e["n"] = int(e["n"]) + 1
	var out := PackedVector2Array()
	for key in users:
		var e: Dictionary = users[key]
		if int(e["n"]) >= 3:
			out.append(e["pt"])
	return out


## 单地块城界链：整环一条闭合链（首点续尾）。链内相邻段共顶点 ⇒ draw_polyline
## 在交汇处成折角、端点不外伸（三岔口不再分叉）。
## 跳水面段（贴湖/河断开）已退役：政治国色描边删除后该逻辑只剩「省界虚线」
## 副作用（河沿岸段全断读作虚线，创始人 2026-09-22 复检指出）——P 社省界
## 语义 = 沿湖/河也连续画。
static func tile_border_chains(data: L1WorldData, poly: PackedVector2Array,
		water_tol: float, lake_boxes: Array[Rect2],
		river_lines: Array, river_widths: PackedFloat32Array,
		river_boxes: Array[Rect2]) -> Array:
	var out: Array = []
	if poly.size() < 3:
		return out
	var ring := PackedVector2Array(poly)
	ring.append(poly[0])
	out.append(ring)
	return out


## 邻省块填充色（政治模式）：该老 L1 省**主导政权色暗一阶**——地形照常透出，
## 周边比本省低一档亮度（创始人：周围灰色地区 → 地形图 + 政权色，暗一阶）。
## 侧表缺失或该省无主导政权 → 回退旧灰底（L1_NEIGHBOR_COLOR）。
static func neighbor_block_color(h, neighbor: Dictionary) -> Color:
	var label := int(neighbor.get("label", 0))
	var pol: ProvincePolitics = h.province_politics()
	if pol != null and label > 0:
		var c := pol.color_of(label)
		if c.a > 0.0:
			return c.darkened(h.L1_NEIGHBOR_DIM)
	return h.NEIGHBOR_COLOR


## 烘焙静态色块层（写回宿主 _tiles_mesh / _lakes_mesh / _neighbors_mesh）：
## 城市色块 / 湖泊 / 邻省块各一张 ArrayMesh（顶点色，三角形独立顶点）。
## Geometry2D.triangulate_polygon 一次性 earcut（C++，含凹多边形），仅 set_data / 首帧调用一次。
## 邻省块取色 = 该省主导政权色暗一阶（neighbor_block_color；侧表缺失回退灰底），
## 已完整装载的邻省交给邻省完整渲染层（见 bake_neighbors_mesh）。
## 拆两张 mesh：河流画在两层层间（tiles 上、lakes 下），见宿主 _draw 1.5 层。
static func bake_base_meshes(h) -> void:
	h._tiles_mesh = null
	h._lakes_mesh = null
	var ctx = h._data.context_size
	if ctx.x <= 0 or ctx.y <= 0:
		bake_neighbors_mesh(h)
		return
	# 收集 (多边形, 颜色)：海洋 = 全矩形底由渲染器背景承担（OCEAN 回退分支 + 相机外区域）
	var tile_pairs: Array = []   # [[PackedVector2Array, Color], ...]
	var lake_pairs: Array = []
	for lake in h._data.lakes:
		lake_pairs.append([pts(lake), h.LAKE_COLOR])
	for tile in h._data.tiles:
		if tile.polygon.size() >= 3:
			# 取色归宿主 tile_fill_color：玩家已占地块染玩家疆域色，其余按政权色
			tile_pairs.append([tile.polygon, h.tile_fill_color(tile)])
	h._tiles_mesh = mesh_from_pairs(tile_pairs)
	h._lakes_mesh = mesh_from_pairs(lake_pairs)
	bake_neighbors_mesh(h)


## 邻省块兜底灰底/暗色块 mesh（只含**未**完整装载的邻省）。
## 邻省完整渲染装载完成后该省从本 mesh 退出：同层两份半透明填充会叠暗，
## 且完整层（逐城块真实政权色）已覆盖其窗口——退出的省读起来是"升级"不是"变色"。
static func bake_neighbors_mesh(h) -> void:
	h._neighbors_mesh = null
	var neighbor_pairs: Array = []
	for ni in h._data.neighbors.size():
		var nb: Dictionary = h._data.neighbors[ni]
		if h._nb_loaded.has(int(nb.get("label", 0))):
			continue
		var nb_color: Color = neighbor_block_color(h, nb)
		# 洞环（内陆海洞/湖等 label 0 区）逐个从外环裁掉（Geometry2D 布尔），
		# 否则邻块填色盖住水域（守门 I2a 同口径）
		var nb_holes: Array = nb.get("holes", [])
		for poly in nb.get("polygons", []):
			var npts := pts(poly)
			if npts.size() < 3:
				continue
			var pieces: Array = [npts]
			for hole in nb_holes:
				var hpts := pts(hole)
				if hpts.size() < 3:
					continue
				var next_pieces: Array = []
				for piece in pieces:
					next_pieces.append_array(Geometry2D.clip_polygons(piece, hpts))
				pieces = next_pieces
			for piece in pieces:
				if piece.size() >= 3:
					neighbor_pairs.append([piece, nb_color])
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
