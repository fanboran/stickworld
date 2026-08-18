extends Node2D
class_name L2L1Overlay
## L2 地区视图上的 L1 细分叠加层 —— 点开 L2 地块看到 L1 细分（V 键切换）
##
## 数据来源：tools/worldgen/l1/export_l1_l2_split.py 产出的 l1_split.json
## （坐标 = 该 L2 视图的正方形 context 局部，与 l2_world.json 同一坐标系）。
## 显示：每个 L1 细胞按蒙版相似色半透明填充 + 细胞边界细线 + 城市点圆点。
## 性能（沿用 L2/L3 渲染器模式）：加载时烘焙静态 ArrayMesh，每帧仅 draw_mesh。

const FILL_ALPHA := 0.55
const EDGE_COLOR := Color(0.10, 0.10, 0.10, 0.65)
const EDGE_WIDTH := 3.0           # 地图单位线宽（放大随地块比例）
const CITY_COLOR := Color(0.98, 0.42, 0.12)
const CITY_RADIUS := 10.0         # 地图单位半径

var _cells: Array = []            # [{rgb, polygons(Array[PackedVector2Array]), city}]
var _fill_mesh: ArrayMesh = null
var _edge_mesh: ArrayMesh = null
var _loaded: bool = false


## 加载某地区的 L1 细分数据（幂等）。json_path 相对 res://
func load_split(json_path: String) -> void:
	_loaded = false
	_cells.clear()
	_fill_mesh = null
	_edge_mesh = null
	var json_text := FileAccess.get_file_as_string(json_path)
	if json_text.is_empty():
		push_error("[L2L1Overlay] 无法读取 %s" % json_path)
		return
	var data: Variant = JSON.parse_string(json_text)
	if data == null or not (data is Dictionary):
		push_error("[L2L1Overlay] JSON 解析失败: %s" % json_path)
		return
	for cd in (data.get("cells", []) as Array):
		var c: Dictionary = cd
		var rgb: Array = c.get("rgb", [200, 200, 200])
		var rings := Array()
		for ring in (c.get("polygons", []) as Array):
			var poly := PackedVector2Array()
			for pt in (ring as Array):
				poly.append(Vector2(float(pt[0]), float(pt[1])))
			if poly.size() >= 3:
				rings.append(poly)
		_cells.append({
			"rgb": Color8(int(rgb[0]), int(rgb[1]), int(rgb[2])),
			"polygons": rings,
			"city": Vector2(float(c["city"][0]), float(c["city"][1])),
		})
	_build_meshes()
	_loaded = _cells.size() > 0
	print("[L2L1Overlay] %s 加载 %d 个 L1 细胞" % [json_path, _cells.size()])
	queue_redraw()


func is_loaded() -> bool:
	return _loaded


## 一次性烘焙：全部细胞填充三角形 + 边界线段为静态 ArrayMesh
func _build_meshes() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var ev := PackedVector3Array()
	var eidx := PackedInt32Array()
	for c in _cells:
		var col: Color = c["rgb"]
		col.a = FILL_ALPHA
		for ring in c["polygons"]:
			var tri := Geometry2D.triangulate_polygon(ring)
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in ring:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(col)
			for idx in tri:
				indices.append(base + idx)
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


func _draw() -> void:
	if _fill_mesh != null:
		draw_mesh(_fill_mesh, null)
	if _edge_mesh != null:
		draw_mesh(_edge_mesh, null)
	for c in _cells:
		draw_circle(c["city"], CITY_RADIUS, CITY_COLOR)