class_name L2WorldData
extends RefCounted
## L2 地区数据容器 —— M 键 L3 地图点击地区下钻视图
##
## 数据来源：tools/worldgen/l2_export/export_l2_view_packs.py 产出的 l2_world.json + PNG
## （底图/地块索引图/边界图，最长边 2048；地块 label 与 L3 独立命名空间）
## hover 高亮用地块索引图像素解码（P 社 provinces.bmp 机制）

## 底图（L2 地形）
var base_texture: Texture2D = null

## 地块索引图（label 直编，0=海洋/无地块，NEAREST 采样）
var mask_image: Image = null

## 地块边界边缘图（RGBA 透明背景 + 黄边，与 mask 同源）
var border_texture: Texture2D = null

## 地块列表（label 1..N，含面积/质心/多边形）
var tiles: Array[Dictionary] = []

## 底图像素尺寸（Vector2i, 宽高）
var size := Vector2i.ZERO

## context 尺寸（含相邻地区扩展区域，渲染画布）
var context_size := Vector2i.ZERO

## 当前地区 bbox 原点在 context 中的位置（渲染偏移）
var tiles_offset := Vector2i.ZERO

## 相邻 L2 地区（灰色显示）：[{label, polygons, holes}]（context 坐标）
var neighbors: Array = []

## 湖泊多边形（浅蓝显示）：[[(y,x),...]]（context 坐标）
var lakes: Array = []

## 地区名（region_001 等）
var region_id: String = ""

## 烘焙几何（l2_geom.bin，素材阶段已三角剖分，运行时零几何计算）。
## meshes: Array[Dictionary]，顺序 [tiles, holes, lakes, neighbors]，
##   每项 {verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array}
var baked_meshes: Array = []
## 描边段（渲染坐标，已合并共线段消除毛刷）：每项 PackedVector2Array（每段 2 点）
var tile_border_segs: Array = []
var neighbor_border_segs: Array = []

var _tile_by_label: Dictionary = {}


## 从 JSON + PNG 加载
static func load_from(json_path: String, base_dir: String) -> L2WorldData:
	var world := L2WorldData.new()
	var json_text := FileAccess.get_file_as_string(json_path)
	if json_text.is_empty():
		push_error("[L2WorldData] 无法读取 %s" % json_path)
		return world
	var data: Variant = JSON.parse_string(json_text)
	if data == null or not (data is Dictionary):
		push_error("[L2WorldData] JSON 解析失败: %s" % json_path)
		return world

	world.region_id = str(data.get("region_id", ""))
	var sz: Array = data.get("size", [0, 0])
	world.size = Vector2i(int(sz[0]), int(sz[1]))
	# 上下文（相邻地区扩展区域）：context 尺寸 + 当前 bbox 原点偏移 + 邻居/湖泊多边形
	var csz: Array = data.get("context_size", sz)
	world.context_size = Vector2i(int(csz[0]), int(csz[1]))
	var toff: Array = data.get("tiles_offset", [0, 0])
	world.tiles_offset = Vector2i(int(toff[0]), int(toff[1]))
	world.neighbors = data.get("neighbors", [])
	world.lakes = data.get("lakes", [])
	world.load_baked_geom("%s/l2_geom.bin" % base_dir)
	var base_path := "%s/%s" % [base_dir, data.get("base_texture", "l2_base_2048.png")]
	var mask_path := "%s/%s" % [base_dir, data.get("mask_texture", "l2_tiles_index_2048.png")]
	var border_path := "%s/%s" % [base_dir, data.get("border_texture", "l2_tiles_border_2048.png")]
	if ResourceLoader.exists(base_path):
		world.base_texture = load(base_path) as Texture2D
	if FileAccess.file_exists(mask_path):
		var img := Image.new()
		if img.load(mask_path) == OK:
			world.mask_image = img
	if ResourceLoader.exists(border_path):
		world.border_texture = load(border_path) as Texture2D

	for td in (data.get("tiles", []) as Array):
		var t: Dictionary = td
		world.tiles.append(t)
		world._tile_by_label[int(t.get("label", 0))] = t
	return world


## 根据地图坐标查询命中的地块
## map_pos: 底图坐标系像素坐标
func query_at_map_pos(map_pos: Vector2) -> Dictionary:
	var result := {"tile": {}}
	if mask_image == null or map_pos.x < 0 or map_pos.y < 0 \
			or map_pos.x >= mask_image.get_width() or map_pos.y >= mask_image.get_height():
		return result
	var px := mask_image.get_pixel(int(map_pos.x), int(map_pos.y))
	var label := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
	if label <= 0:
		return result
	var t: Variant = _tile_by_label.get(label, null)
	if t != null:
		result["tile"] = t
	return result


func get_tile(label: int) -> Dictionary:
	return _tile_by_label.get(label, {})


## 解析 l2_geom.bin（素材阶段烘焙的三角剖分 + 描边段），运行时零几何计算。
## 格式见 tools/worldgen/l2_export/l2_bake.py 头部注释。
func load_baked_geom(bin_path: String) -> void:
	baked_meshes.clear()
	tile_border_segs.clear()
	neighbor_border_segs.clear()
	if not FileAccess.file_exists(bin_path):
		return
	var f := FileAccess.open(bin_path, FileAccess.READ)
	if f == null:
		return
	# magic + ver
	var magic := f.get_buffer(4).get_string_from_ascii()
	if magic != "L2GB":
		f.close()
		return
	var _ver: int = f.get_16()
	# 4 个 mesh section
	for _s in range(4):
		var tri_count := f.get_32()
		var verts := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		for _t in range(tri_count):
			var v0 := Vector3(f.get_float(), f.get_float(), 0.0)
			var v1 := Vector3(f.get_float(), f.get_float(), 0.0)
			var v2 := Vector3(f.get_float(), f.get_float(), 0.0)
			var r := f.get_8()
			var g := f.get_8()
			var b := f.get_8()
			f.get_8()  # alpha
			var base := verts.size()
			verts.append(v0)
			verts.append(v1)
			verts.append(v2)
			var col := Color(r / 255.0, g / 255.0, b / 255.0)
			colors.append(col)
			colors.append(col)
			colors.append(col)
			indices.append(base)
			indices.append(base + 1)
			indices.append(base + 2)
		baked_meshes.append({"verts": verts, "colors": colors, "indices": indices})
	# 2 个 border section
	tile_border_segs = _read_border_section(f)
	neighbor_border_segs = _read_border_section(f)
	f.close()


func _read_border_section(f: FileAccess) -> Array:
	var out := []
	var seg_count := f.get_32()
	for _i in range(seg_count):
		var a := Vector2(f.get_float(), f.get_float())
		var b := Vector2(f.get_float(), f.get_float())
		var line := PackedVector2Array([a, b])
		out.append(line)
	return out
