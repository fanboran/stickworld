class_name L3WorldData
extends RefCounted
## L3 大世界数据容器 —— M 键战略图（13 个 L2 地区分块）
##
## 数据来源：tools/worldgen/export_l3_view.py 产出的 l3_world.json + PNG
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
	if FileAccess.file_exists(mask_path):
		var img := Image.new()
		if img.load(mask_path) == OK:
			world.mask_image = img

	for rd in (data.get("regions", []) as Array):
		var r: Dictionary = rd
		world.regions.append(r)
		world._region_by_label[int(r.get("label", 0))] = r
	for sd in (data.get("sea_links", []) as Array):
		world.sea_links.append(sd)
	return world


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


func get_region_color(label: int) -> Color:
	# 从 mask 采样该地区的一个像素取色（无独立色表）
	return Color(0.6, 0.8, 1.0)
