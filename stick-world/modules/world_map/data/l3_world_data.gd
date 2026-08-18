class_name L3WorldData
extends RefCounted
## L3 大世界数据容器 —— M 键战略图（13 个 L2 地区分块）
##
## 数据来源：tools/worldgen/l2_export/export_l3_view.py 产出的 l3_world.json + PNG
## 渲染为纯矢量（色块+描边，见 L3MapRenderer），这里只提供：
##   - 索引图（hover/下钻像素查询，P 社 provinces.bmp 机制）
##   - 地区元数据（label/多边形/颜色）

## 分区索引图（label 直编，含海洋归边，NEAREST 采样）
var mask_image: Image = null

## 地区列表（label 1..N）
var regions: Array[Dictionary] = []

## 隔海直线链接（渲染描边用）：{"a","b","p1","p2"}
var sea_links: Array[Dictionary] = []

## 底图像素尺寸（渲染坐标系，8192 级网格）
var size: int = 0

## 烘焙几何（l3_geom.bin，素材阶段已三角剖分，运行时零几何计算）。
## 顺序 [land, holes]，每项 {verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array}
## （与 L2WorldData.baked_meshes 同构，生成见 tools/worldgen/l3_bake.gd）
var baked_meshes: Array = []

var _region_by_label: Dictionary = {}


## 从 JSON + PNG 加载
static func load_from(json_path: String, base_dir: String) -> L3WorldData:
	var world := L3WorldData.new()
	var json_text := FileAccess.get_file_as_string(json_path)
	if json_text.is_empty():
		push_error("[L3WorldData] 无法读取 %s" % json_path)
		return world
	var data: Variant = JSON.parse_string(json_text)
	if data == null or not (data is Dictionary):
		push_error("[L3WorldData] JSON 解析失败: %s" % json_path)
		return world

	world.size = int(data.get("size", 8192))
	var mask_path := "%s/%s" % [base_dir, data.get("mask_texture", "l3_partition_2048.png")]
	if ResourceLoader.exists(mask_path):
		# 经导入资源加载（export 安全）：直接 Image.load() 从项目路径读原始文件
		# 无法在导出包内工作，且会告警。此处 get_image() 已验证字节保真（RGBA8）。
		var tex: Texture2D = load(mask_path)
		if tex != null:
			world.mask_image = tex.get_image()

	for rd in (data.get("regions", []) as Array):
		var r: Dictionary = rd
		world.regions.append(r)
		world._region_by_label[int(r.get("label", 0))] = r
	for sd in (data.get("sea_links", []) as Array):
		world.sea_links.append(sd)
	world.load_baked_geom("%s/l3_geom.bin" % base_dir)
	return world


## 解析 l3_geom.bin（素材阶段烘焙的三角剖分，运行时零几何计算）。
## 格式见 tools/worldgen/l3_bake.gd 头部注释：magic "L3GB" + ver u16 + 2 个 mesh 段（land/holes）。
## 无 bin 时静默返回空（渲染器回退运行时三角剖分，仅开发环境）。
func load_baked_geom(bin_path: String) -> void:
	baked_meshes.clear()
	if not FileAccess.file_exists(bin_path):
		return
	var f := FileAccess.open(bin_path, FileAccess.READ)
	if f == null:
		return
	var magic := f.get_buffer(4).get_string_from_ascii()
	if magic != "L3GB":
		f.close()
		return
	var _ver: int = f.get_16()
	# 整段读入 + 批量解码（6.5MB / 21 万三角形，逐 tri 读浮点会慢 10 倍）
	for _s in range(2):
		var tri_count := f.get_32()
		var buf := f.get_buffer(tri_count * 28)
		var flts := buf.to_float32_array()
		var verts := PackedVector3Array()
		verts.resize(tri_count * 3)
		var colors := PackedColorArray()
		colors.resize(tri_count * 3)
		var indices := PackedInt32Array()
		indices.resize(tri_count * 3)
		# 每三角形 28B：6 个坐标 float（24B）+ 4B 颜色。to_float32_array 会把颜色 4B 也
		# 当作第 7 个 float 解码（垃圾值），故坐标在 flts[base..base+5]，颜色字节在 buf[base*4+24..]
		for t in range(tri_count):
			var base := t * 7
			var vi := t * 3
			verts[vi] = Vector3(flts[base], flts[base + 1], 0.0)
			verts[vi + 1] = Vector3(flts[base + 2], flts[base + 3], 0.0)
			verts[vi + 2] = Vector3(flts[base + 4], flts[base + 5], 0.0)
			indices[vi] = vi
			indices[vi + 1] = vi + 1
			indices[vi + 2] = vi + 2
			var cb := base * 4 + 24
			var r := buf[cb]
			var g := buf[cb + 1]
			var b := buf[cb + 2]
			var col := Color(r / 255.0, g / 255.0, b / 255.0)
			colors[vi] = col
			colors[vi + 1] = col
			colors[vi + 2] = col
		baked_meshes.append({"verts": verts, "colors": colors, "indices": indices})
	f.close()


## 根据地图坐标查询命中的地区
## map_pos: 底图坐标系像素坐标
func query_at_map_pos(map_pos: Vector2) -> Dictionary:
	var result := {"region": {}}
	if mask_image == null or map_pos.x < 0 or map_pos.y < 0 \
			or map_pos.x >= mask_image.get_width() or map_pos.y >= mask_image.get_height():
		return result
	var px := mask_image.get_pixel(int(map_pos.x), int(map_pos.y))
	# 分区索引图 = label 直编（RGB 编码，P 社 provinces.bmp 机制）
	var label := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
	if label <= 0:
		return result
	var r: Variant = _region_by_label.get(label, null)
	if r != null:
		result["region"] = r
	return result


func get_region(label: int) -> Dictionary:
	return _region_by_label.get(label, {})


func get_region_color(_label: int) -> Color:
	# 从 mask 采样该地区的一个像素取色（无独立色表）
	return Color(0.6, 0.8, 1.0)
