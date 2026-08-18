extends Node2D
class_name L3MapRenderer
## L3 大世界渲染器 —— 静态几何缓存（ArrayMesh）+ hover 灰色描边
##
## 性能方案（Godot 官方推荐）：
##  - 地区陆地几何在 set_data 时一次性三角剖分，构建 ArrayMesh（顶点+颜色+索引）
##  - 每帧仅 1 次 draw_mesh（零 CPU 三角剖分）——解决每帧 draw_colored_polygon 卡顿
##  - 洞（C 形地区内海洋）数量少，每帧直接覆盖海洋色
##  - hover 描边用 draw_polyline（单条，开销可忽略）
## 索引图仅用于 hover 像素查询（不动）

var _data: L3WorldData = null
var _camera: MapCamera = null

## hover 命中的地区（Dictionary，未命中为空）
var hovered_region: Dictionary = {}

## hover 描边色（灰色）
const EDGE_COLOR := Color(0.55, 0.55, 0.55)
const EDGE_WIDTH := 5.0          # 地图单位线宽（与地块比例恒定，放大不显细）
const MIN_SCREEN_PX := 2.0       # 最小屏幕像素线宽（缩小保底，细到看不见）

## L2 地区编号（F3 调试模式显示，标在地区质心）
const L2_LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const L2_LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
const L2_LABEL_SIZE := 40.0        # 地图单位字号
## L2 地区常驻描边（L1 视觉层时标识可下钻单元）
const L2_BORDER_COLOR := Color(0.16, 0.16, 0.16, 0.85)
var _debug_was_visible: bool = false

## 海洋背景色
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)

var _static_mesh: ArrayMesh = null
var _holes_mesh: ArrayMesh = null   # 洞挖空（海洋色，预剖分）


func set_data(data: L3WorldData) -> void:
	_data = data
	_build_static_mesh()
	queue_redraw()


func get_data() -> L3WorldData:
	return _data


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func refresh() -> void:
	queue_redraw()


## 一次性构建静态网格（所有地区合并为单个 ArrayMesh）
func _build_static_mesh() -> void:
	_static_mesh = null
	_holes_mesh = null
	if _data == null:
		return
	# 视觉层优先级：老 L1（L3 直接显示 L1 地块，丰富配色）→ 回退 13 地区色块
	var units: Array = _data.l1_tiles if not _data.l1_tiles.is_empty() else _data.regions
	var is_l1: bool = not _data.l1_tiles.is_empty()
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hverts := PackedVector3Array()
	var hcols := PackedColorArray()
	var hindices := PackedInt32Array()
	for r in units:
		var col: Array = r.get("color", [])
		var fill := Color(0.6, 0.7, 0.8)
		if col.size() >= 3:
			fill = Color(col[0] / 255.0, col[1] / 255.0, col[2] / 255.0)
		# 陆地外轮廓（全部岛屿/地块）-> 三角剖分
		const POLY_KEYS_L1 := ["polygons", "holes"]
		const POLY_KEYS_REG := ["land_polygons", "land_holes"]
		var pkeys: Array = POLY_KEYS_L1 if is_l1 else POLY_KEYS_REG
		for poly in r.get(pkeys[0], [r.get("polygon", [])]):
			if (poly as Array).size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(Vector2(p[1], p[0]))
			var tri := Geometry2D.triangulate_polygon(pts2)
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in pts2:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(fill)
			for idx in tri:
				indices.append(base + idx)
		# 洞 -> 预剖分（海洋色覆盖）
		for hole in r.get(pkeys[1], []):
			if (hole as Array).size() < 3:
				continue
			var hpts := PackedVector2Array()
			for p in hole:
				hpts.append(Vector2(p[1], p[0]))
			var htri := Geometry2D.triangulate_polygon(hpts)
			if htri.is_empty():
				continue
			var hb := hverts.size()
			for v in hpts:
				hverts.append(Vector3(v.x, v.y, 0.0))
				hcols.append(OCEAN_COLOR)
			for idx in htri:
				hindices.append(hb + idx)
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		_static_mesh = mesh
	if not hverts.is_empty():
		var harr := []
		harr.resize(Mesh.ARRAY_MAX)
		harr[Mesh.ARRAY_VERTEX] = hverts
		harr[Mesh.ARRAY_COLOR] = hcols
		harr[Mesh.ARRAY_INDEX] = hindices
		var hmesh := ArrayMesh.new()
		hmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, harr)
		_holes_mesh = hmesh


func _process(_delta: float) -> void:
	if not visible or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	# 渲染坐标（8192 级网格）-> 索引图坐标（2048 级查询）
	if _data.mask_image != null and _data.size > 0:
		mouse_pos *= float(_data.mask_image.get_width()) / float(_data.size)
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var region: Dictionary = query.get("region", {})
	var label: int = int(region.get("label", -1))
	if label != int(hovered_region.get("label", -1)):
		hovered_region = region
		queue_redraw()
	# F3 调试模式变化时刷新（L2 编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 海洋背景（纯色）
	draw_rect(Rect2(Vector2.ZERO, Vector2(_data.size, _data.size)), OCEAN_COLOR)
	# 2. 全部地区陆地静态网格（一次 draw_mesh，零三角剖分）
	if _static_mesh != null:
		draw_mesh(_static_mesh, null)
	# 3. 洞挖空（C 形地区内海洋；预剖分 mesh）
	if _holes_mesh != null:
		draw_mesh(_holes_mesh, null)
	# 4. hover 地区轮廓描边（陆地全部岛屿轮廓；抗锯齿矢量线，闭合，最上层）
	var hpolys: Array = hovered_region.get("land_polygons", [hovered_region.get("land_polygon", [])])
	for hp in hpolys:
		if (hp as Array).size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		# 线宽：地图单位保底 2 屏像素（缩小也可见；放大随地图比例）
		var w := EDGE_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				w = maxf(EDGE_WIDTH, MIN_SCREEN_PX / z)
		draw_polyline(hpts, EDGE_COLOR, w, true)
	# 4.5 L2 地区常驻描边（L1 视觉层开启时：底是老 L1 细块，用粗地区边界标识可下钻单元）
	if _data != null and not _data.l1_tiles.is_empty():
		var bw: float = BORDER_WIDTH()
		for r in _data.regions:
			for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
				if (poly as Array).size() < 3:
					continue
				var bpts := PackedVector2Array()
				for pp in poly:
					bpts.append(Vector2(pp[1], pp[0]))
				bpts.append(bpts[0])
				draw_polyline(bpts, L2_BORDER_COLOR, bw, true)
	# 5. L2 地区编号（F3 调试模式，标在地区质心，调试认地区用）
	if DebugApi != null and DebugApi.is_visible() and _data != null:
		_draw_l2_labels()


func BORDER_WIDTH() -> float:
	var w := 9.0
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			w = maxf(w, MIN_SCREEN_PX / z)
	return w


## F3 调试：给每个 L2 地区打编号（地区质心）。注意 centroid 是 2048 级，渲染 8192 级：
## 需 ×(8192/2048=4) 才能落在正确位置（否则文字堆左上角、不随缩放）。
func _draw_l2_labels() -> void:
	var font := ThemeDB.fallback_font
	var scale := 1.0
	if _data != null and _data.size > 0 and _data.mask_image != null:
		scale = float(_data.size) / float(_data.mask_image.get_width())
	for r in _data.regions:
		var label: int = int(r.get("label", 0))
		if label <= 0:
			continue
		var c: Array = r.get("centroid", [0, 0])
		if c.size() < 2:
			continue
		var pos := Vector2(float(c[0]), float(c[1])) * scale
		var txt := "L2#%d" % label
		for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			draw_string(font, pos + off * 2.0, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, L2_LABEL_BG)
		draw_string(font, pos + Vector2(4.0, -L2_LABEL_SIZE * 0.3), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, L2_LABEL_COLOR)
