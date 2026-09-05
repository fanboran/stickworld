class_name L1WorldData
extends RefCounted
## L1 世界数据容器 —— P0 战略图单层数据（玩家第一阶段世界图 = 8 城邦）
##
## 详见 docs/技术/架构/战略图架构.md §3（L1 单层版）
## 数据来源：tools/worldgen/l1/l1_worldgen.py 产出的 l1_world.json + l1_base.png + l1_mask.png
##
## 设计约束（08-程序化世界生成.md §0.19）：
##   - 1 个 L1 地块 = 1 个聚落（或空聚落）
##   - 8 聚落 = 1 中心城市 + 2 镇 + 5 部落，8 政权独立、全敌对
##   - 底图 = 卫星图风格；边界索引图每 L1 地块一色（P 社 provinces.bmp 机制）

## L1 地图 ID（= L2 的下辖地块，世界观揭晓用）
var map_id: String = ""

## L1 地图名
var name: String = ""

## 底图像素尺寸（正方形）
var size: int = 0

## 卫星图底图（地形色，不含聚落/道路）
var base_texture: Texture2D = null

## 边界索引图（每 L1 地块一个 RGB 编码，NEAREST 采样，点击查询用）
var mask_image: Image = null

## L1 地块列表（1 地块 = 1 聚落或空）
var tiles: Array[L1TileDef] = []

## 道路（聚落间 MST，像素坐标点列）
var roads: Array[PackedVector2Array] = []

## 政权（state_id -> 信息）
var states: Dictionary = {}

## 玩家出生聚落 ID
var spawn_settlement_id: String = ""

## 所属老 L1 全局 label（1..69；L2 下钻打开的 L1 用此区分）
var parent_l1_label: int = 0

## 出生 L1 地块权威轮廓（context 像素坐标，L1 边界粗线用；贴 L1 边缘的城市套用该边界）
var l1_polygon: PackedVector2Array = []

## context 尺寸（正方形，含灰色邻居 L1 块扩展区域，渲染画布）
var context_size := Vector2i.ZERO

## 相邻老 L1 块（灰色显示）：[{label, polygons, holes}]（context 坐标）
var neighbors: Array = []

## 湖泊多边形（浅蓝显示）：[[(x,y),...]]（context 坐标）
var lakes: Array = []

## 状态（tile_id -> L1TileDef 快速索引）
var _tile_by_id: Dictionary = {}


## 从 JSON/紧凑 bin + PNG 加载 L1 世界数据
## json_path: l1_world.json 的 res:// 路径（bin 优先：同名 .bin 原样序列化，见 _read_data_dict）
## base_dir: 含 l1_base.png / l1_mask.png 的目录（res:// 路径，末尾无斜杠）
static func load_from(json_path: String, base_dir: String) -> L1WorldData:
	var world := L1WorldData.new()
	var data := _read_data_dict(json_path)
	if data.is_empty():
		push_error("[L1WorldData] 无法读取/解析 %s" % json_path)
		return world

	world.map_id = data.get("map_id", "l1_main")
	world.name = data.get("name", "")
	world.size = int(data.get("size", 1024))
	world.spawn_settlement_id = data.get("spawn_settlement_id", "")
	world.parent_l1_label = int(data.get("parent_l1_label", 0))
	var l1poly: Variant = data.get("l1_polygon", [])
	if l1poly is Array:
		world.l1_polygon = _polygon_from(l1poly)
	# context（含灰色邻居 L1 块扩展区域）：context 尺寸 + 邻居/湖泊多边形
	var csz: Array = data.get("context_size", [])
	if csz.size() >= 2:
		world.context_size = Vector2i(int(csz[0]), int(csz[1]))
	world.neighbors = data.get("neighbors", [])
	world.lakes = data.get("lakes", [])

	# 底图 + 索引图
	var base_path := "%s/%s" % [base_dir, data.get("base_texture", "l1_base.png")]
	var mask_path := "%s/%s" % [base_dir, data.get("mask_texture", "l1_mask.png")]
	if ResourceLoader.exists(base_path):
		world.base_texture = load(base_path) as Texture2D
		if world.base_texture == null:
			push_warning("[L1WorldData] 底图资源类型非 Texture2D: %s" % base_path)
	else:
		push_warning("[L1WorldData] 底图不存在: %s" % base_path)
	if ResourceLoader.exists(mask_path):
		var mask_tex: Texture2D = load(mask_path) as Texture2D
		if mask_tex != null:
			world.mask_image = mask_tex.get_image()
		else:
			# 兼容直接导入为 Image 的资源
			world.mask_image = load(mask_path) as Image
			if world.mask_image == null:
				push_warning("[L1WorldData] 索引图资源类型非 Texture2D/Image: %s" % mask_path)
	else:
		push_warning("[L1WorldData] 索引图不存在: %s" % mask_path)

	# 政权
	for s in (data.get("states", []) as Array):
		var sd: Dictionary = s
		var color_arr: Array = sd.get("color", [150, 150, 150])
		world.states[sd.get("state_id", "")] = {
			"name": sd.get("name", ""),
			"capital_settlement_id": sd.get("capital_settlement_id", ""),
			"color": Color(
				float(color_arr[0]) / 255.0,
				float(color_arr[1]) / 255.0,
				float(color_arr[2]) / 255.0
			),
		}

	# 地块 + 聚落
	for td in (data.get("tiles", []) as Array):
		var tile := L1TileDef.new()
		var tile_dict: Dictionary = td
		tile.tile_id = tile_dict.get("tile_id", "")
		tile.polygon = _polygon_from(tile_dict.get("polygon", []))
		var owner: String = tile_dict.get("owner_state_id", "")
		if owner.is_empty():
			# 兜底：按聚落所属政权推导（生成器未写 owner 时用 cap 归属）
			owner = world._find_state_for_settlement(tile_dict, world.states)
		tile.owner_state_id = owner
		var sd: Variant = tile_dict.get("settlement")
		if sd != null and sd is Dictionary:
			var sref := SettlementRef.new()
			sref.settlement_id = sd.get("settlement_id", "")
			sref.name = sd.get("name", "")
			sref.level = int(sd.get("level", 1))
			var pos_arr: Array = sd.get("position_px", [0, 0])
			sref.position = Vector2(float(pos_arr[0]), float(pos_arr[1]))
			sref.map_id = sd.get("map_id", "")
			sref.population_score = SettlementRef.jitter_population_score(
				float(sd.get("population_score", 0.0)), sref.settlement_id,
				WorldState.run_seed if WorldState else 0,
				sref.settlement_id == world.spawn_settlement_id)
			tile.settlement = sref
		world.tiles.append(tile)
		world._tile_by_id[tile.tile_id] = tile

	# 道路
	for rd in (data.get("roads", []) as Array):
		var rd_dict: Dictionary = rd
		var from_tile: L1TileDef = world._tile_by_id.get(
			world._tile_id_of_settlement(rd_dict.get("from", "")), null)
		var to_tile: L1TileDef = world._tile_by_id.get(
			world._tile_id_of_settlement(rd_dict.get("to", "")), null)
		if from_tile == null or to_tile == null:
			continue
		if from_tile.settlement == null or to_tile.settlement == null:
			continue
		world.roads.append(PackedVector2Array([
			from_tile.settlement.position, to_tile.settlement.position
		]))
	return world


## 根据屏幕/地图坐标查询命中的聚落
## map_pos: 底图坐标系像素坐标
## 返回 {"tile": L1TileDef, "settlement": SettlementRef}（未命中 settlement 为 null）
func query_at_map_pos(map_pos: Vector2) -> Dictionary:
	var result := {"tile": null, "settlement": null}
	if mask_image == null or map_pos.x < 0 or map_pos.y < 0 \
			or map_pos.x >= mask_image.get_width() or map_pos.y >= mask_image.get_height():
		return result
	var px := mask_image.get_pixel(int(map_pos.x), int(map_pos.y))
	var code := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
	if code <= 0 or code > tiles.size():
		return result
	var tile: L1TileDef = tiles[code - 1]
	result["tile"] = tile
	result["settlement"] = tile.settlement
	return result


func get_settlement(settlement_id: String) -> SettlementRef:
	for tile in tiles:
		if tile.settlement != null and tile.settlement.settlement_id == settlement_id:
			return tile.settlement
	return null


func get_state_color(state_id: String) -> Color:
	var info: Dictionary = states.get(state_id, {})
	return info.get("color", Color.GRAY)


## settlement_id -> 所属 tile_id（道路连接用）
func _tile_id_of_settlement(settlement_id: String) -> String:
	for tile in tiles:
		if tile.settlement != null and tile.settlement.settlement_id == settlement_id:
			return tile.tile_id
	return ""


## 生成器数据兜底：无 owner_state_id 时按首都归属推导
func _find_state_for_settlement(tile_dict: Dictionary, state_map: Dictionary) -> String:
	var sd: Variant = tile_dict.get("settlement")
	if sd == null or not (sd is Dictionary):
		return ""
	var sid: String = sd.get("settlement_id", "")
	for state_id in state_map:
		var info: Dictionary = state_map[state_id]
		if info.get("capital_settlement_id", "") == sid:
			return state_id
	return ""


static func _polygon_from(arr: Array) -> PackedVector2Array:
	var poly := PackedVector2Array()
	for pt in arr:
		if pt is Array and pt.size() >= 2:
			poly.append(Vector2(float(pt[0]), float(pt[1])))
	return poly


## 读取 l1_world 数据：优先同名紧凑 bin（LWDB + var_to_bytes，原样序列化——L1 顶点序
## [x,y] 与 L2/L3 不同，polygon 保持 Array，构造逻辑 _polygon_from 不变）；
## bin 缺失/格式不符（Godot 升级等）自动回退 JSON。
static func _read_data_dict(json_path: String) -> Dictionary:
	var bin_path := json_path.get_basename() + ".bin"
	if FileAccess.file_exists(bin_path):
		var f := FileAccess.open(bin_path, FileAccess.READ)
		if f != null:
			var magic := f.get_buffer(4).get_string_from_ascii()
			if magic == "LWDB":
				f.get_16()  # ver
				var got: Variant = bytes_to_var(f.get_buffer(f.get_length()))
				if got is Dictionary:
					return got
	var jt := FileAccess.get_file_as_string(json_path)
	if jt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(jt)
	if parsed is Dictionary:
		return parsed
	return {}
