extends Node2D
class_name L1Overlay
## L3 大世界视图上的 L1 地块蒙版叠加层（V 键切换，由 L3MapController 控制）
##
## 数据来源：tools/worldgen/l1/l1_world_split.py 产出的 l1_data.json（2048 级，
## 坐标 (x, y) 列先行后）。渲染坐标系 = L3 地图空间（8192 级网格），因此缩放 4x。
## 显示内容：
##   - 每个 L1 地块多边形按蒙版色半透明填充（同 L2 地区相似色系）
##   - 地块边界细线 + 城市点圆点
##
## 性能（沿用 L2/L3 渲染器模式）：加载时把全部地块三角剖分/线段烘焙为静态
## ArrayMesh，每帧只 draw_mesh 1-2 次（零逐帧 CPU 剖分）。

## 2048 级数据坐标 -> 8192 级渲染坐标的缩放
const SCALE := 4.0
const FILL_ALPHA := 0.45
const EDGE_ALPHA := 0.6
const EDGE_COLOR := Color(0.12, 0.12, 0.12, EDGE_ALPHA)
const VERTEX_COLOR := Color(0.95, 0.32, 0.10)
const CITY_RADIUS := 8.0          # 地图单位半径（放大后与地块比例恒定）

var _tiles: Array = []
var _fill_mesh: ArrayMesh = null
var _edge_mesh: ArrayMesh = null
var _loaded: bool = false

## L1 地块标号（F3 调试模式时显示；不加自定义快捷键）
var _debug_was_visible: bool = false


## 加载蒙版数据并烘焙网格（幂等）。json_path 相对 res://
func load_overlay(json_path: String) -> void:
	if _loaded:
		return
	var json_text := FileAccess.get_file_as_string(json_path)
	if json_text.is_empty():
		push_error("[L1Overlay] 无法读取 %s" % json_path)
		return
	var data: Variant = JSON.parse_string(json_text)
	if data == null or not (data is Dictionary):
		push_error("[L1Overlay] JSON 解析失败: %s" % json_path)
		return
	for td in (data.get("tiles", []) as Array):
		var t: Dictionary = td
		var rgb: Array = t.get("rgb", [200, 200, 200])
		var tcol: Color = Color8(int(rgb[0]), int(rgb[1]), int(rgb[2]))
		_tiles.append({
			"label": int(t.get("label", 0)),
			"region": int(t.get("region", 0)),
			"rgb": tcol,
			"polygons": _collect_rings(t),
			"city": Vector2(float(t["city"][0]), float(t["city"][1])) * SCALE,
		})
	_build_meshes()
	_loaded = true
	print("[L1Overlay] 加载 %d 个 L1 地块蒙版" % _tiles.size())
	queue_redraw()


## 解析外环列表（"polygons" 优先，回退 "polygon"）为 Array[PackedVector2Array]
func _collect_rings(t: Dictionary) -> Array:
	var out := []
	var all: Array = t.get("polygons", [])
	if all.is_empty():
		all = [t.get("polygon", [])]
	for ring in all:
		var poly := PackedVector2Array()
		for pt in (ring as Array):
			poly.append(Vector2(float(pt[0]), float(pt[1])) * SCALE)
		if poly.size() >= 3:
			out.append(poly)
	return out


## 一次性烘焙：全部地块填充三角形 + 边界线段为静态 ArrayMesh
func _build_meshes() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var ev := PackedVector3Array()   # 描边线段顶点（每段 2 点）
	var eidx := PackedInt32Array()
	for t in _tiles:
		var col: Color = t["rgb"]
		col.a = FILL_ALPHA
		for ring in t["polygons"]:
			var tri := Geometry2D.triangulate_polygon(ring)
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in ring:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(col)
			for idx in tri:
				indices.append(base + idx)
			# 边界线段（闭合环逐边）
			for i in ring.size():
				var a := ev.size()
				ev.append(Vector3(ring[i].x, ring[i].y, 0.0))
				ev.append(Vector3(ring[(i + 1) % ring.size()].x, ring[(i + 1) % ring.size()].y, 0.0))
				eidx.append(a)
				eidx.append(a + 1)
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		_fill_mesh = ArrayMesh.new()
		_fill_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if not ev.is_empty():
		var earr := []
		earr.resize(Mesh.ARRAY_MAX)
		earr[Mesh.ARRAY_VERTEX] = ev
		var ecol := PackedColorArray()
		ecol.resize(ev.size())
		ecol.fill(EDGE_COLOR)
		earr[Mesh.ARRAY_COLOR] = ecol
		earr[Mesh.ARRAY_INDEX] = eidx
		_edge_mesh = ArrayMesh.new()
		_edge_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, earr)


func is_loaded() -> bool:
	return _loaded


func _draw() -> void:
	if _fill_mesh != null:
		draw_mesh(_fill_mesh, null)
	if _edge_mesh != null:
		draw_mesh(_edge_mesh, null)
	# 城市点（数量少，逐点画）
	for t in _tiles:
		draw_circle(t["city"], CITY_RADIUS, VERTEX_COLOR)
	# L1 地块标号（F3 调试模式时显示）
	if DebugApi != null and DebugApi.is_visible():
		var font := ThemeDB.fallback_font
		for t in _tiles:
			var pos: Vector2 = t["city"]
			var txt := str(t["label"])
			# 描边（4 方向偏移黑字）
			for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
				draw_string(font, pos + off * 2.0, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.0, 0.0, 0.0, 0.85))
			draw_string(font, pos + Vector2(2.0, -14.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(1.0, 1.0, 1.0, 0.95))


func _process(_delta: float) -> void:
	# F3 调试模式变化时刷新标号
	if DebugApi != null:
		var now := DebugApi.is_visible()
		if now != _debug_was_visible:
			_debug_was_visible = now
			queue_redraw()