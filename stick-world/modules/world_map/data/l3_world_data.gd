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

## 老 L1 视觉层（可选，l3_l1.json）：L3 直接显示 69 块老 L1（丰富配色），
## 交互（hover/下钻）仍按 L2 地区索引图
var l1_tiles: Array = []
## 城市视觉层（可选，l3_city.json）：原始矢量数据（备用；运行时城市模式直接用栅格贴图更快）
var city_tiles: Array = []
## 城市模式栅格贴图（l3_city_preview_2048.png，即 city_preview，花花绿绿最大方）
var city_preview_texture: Texture2D = null
## 老 L1 索引图（label 直编 2048）：hover 查询返回老 L1 地块
var l1_index_image: Image = null

var _l1_by_label: Dictionary = {}
var _city_by_label: Dictionary = {}

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
	# 老 L1 视觉层（可选加载，不影响 L2 交互）
	var l1_path := "%s/l3_l1.json" % base_dir
	if FileAccess.file_exists(l1_path):
		var l1_text := FileAccess.get_file_as_string(l1_path)
		if not l1_text.is_empty():
			var l1_data: Variant = JSON.parse_string(l1_text)
			if l1_data is Dictionary:
				world.l1_tiles = l1_data.get("tiles", [])
	# 城市视觉层（可选；L3"模式:城市"用）
	var city_path := "%s/l3_city.json" % base_dir
	if FileAccess.file_exists(city_path):
		var city_text := FileAccess.get_file_as_string(city_path)
		if not city_text.is_empty():
			var city_data: Variant = JSON.parse_string(city_text)
			if city_data is Dictionary:
				world.city_tiles = city_data.get("tiles", [])
	# 老 L1 索引图（hover 查询）
	var l1idx_path := "%s/l3_l1_index_2048.png" % base_dir
	if ResourceLoader.exists(l1idx_path):
		var tex: Texture2D = load(l1idx_path)
		if tex != null:
			world.l1_index_image = tex.get_image()
	# 城市模式栅格贴图
	var cityprev_path := "%s/l3_city_preview_2048.png" % base_dir
	if ResourceLoader.exists(cityprev_path):
		world.city_preview_texture = load(cityprev_path) as Texture2D
	for r in world.l1_tiles:
		world._l1_by_label[int(r.get("label", 0))] = r
	for r in world.city_tiles:
		world._city_by_label[int(r.get("label", 0))] = r
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


## 根据地图坐标查询命中的老 L1 地块（hover 用，l1 索引图标直编）
## map_pos: 底图坐标系像素坐标
func query_l1_at_map_pos(map_pos: Vector2) -> Dictionary:
	var result := {"l1": {}}
	if l1_index_image == null or map_pos.x < 0 or map_pos.y < 0 \
			or map_pos.x >= l1_index_image.get_width() or map_pos.y >= l1_index_image.get_height():
		return result
	var px := l1_index_image.get_pixel(int(map_pos.x), int(map_pos.y))
	var label := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
	if label <= 0:
		return result
	var t: Variant = _l1_by_label.get(label, null)
	if t != null:
		result["l1"] = t
	return result


func get_l1(label: int) -> Dictionary:
	return _l1_by_label.get(label, {})


func get_region_color(_label: int) -> Color:
	# 从 mask 采样该地区的一个像素取色（无独立色表）
	return Color(0.6, 0.8, 1.0)
