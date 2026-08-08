class_name L2WorldData
extends RefCounted
## L2 地区数据容器 —— M 键 L3 地图点击地区下钻视图
##
## 数据来源：tools/worldgen/export_l2_view_packs.py 产出的 l2_world.json + PNG
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

## 地区名（region_001 等）
var region_id: String = ""

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
