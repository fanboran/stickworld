class_name StrategicMapData
extends Resource
## 战略图运行时数据容器 —— 三级粒度数据的统一管理入口
##
## 详见 docs/技术/架构/战略图架构.md §3.1
## 替代旧的 WorldMapData（单一粒度设计）
##
## 三级粒度：
##   L3 大世界（启动时必加载）
##   L2 地区（双击地区时懒加载）
##   L1 地块（双击地块时懒加载）

## 粒度枚举
enum Granularity {
	L3_CONTINENT = 0,   ## 大世界（整大陆）
	L2_REGION = 1,      ## 地区（单地区）
	L1_TILE = 2,        ## 地块（单地块）
}

## L3 大世界（启动时必加载）
var continent: ContinentData = null

## L2 地区（按 region_id 懒加载）
## key: region_id (String), value: RegionData
var regions: Dictionary = {}

## L1 地块（按 tile_id 懒加载）
## key: tile_id (String), value: MapTileData
var tiles: Dictionary = {}

## 政权数据（启动时必加载）
var political: PoliticalData = null

## 当前粒度
var current_granularity: Granularity = Granularity.L3_CONTINENT

## 当前聚焦的父级 ID
## L3 时为 ""，L2 时为 region_id，L1 时为 tile_id
var focused_parent_id: String = ""

## 资源清单（manifest.tres 引用）
var manifest: Resource = null


# ===== 加载 =====

## 加载 L3（启动时调用）
## [P] manifest 已设置
## [Q] continent 字段填充，current_granularity = L3
func load_continent() -> Result:
	# TODO: SM-1 实现
	# 1. 从 manifest 找到 continent.tres 路径
	# 2. load() 加载 ContinentData
	# 3. current_granularity = Granularity.L3_CONTINENT
	# 4. focused_parent_id = ""
	return Result.ok()


## 加载指定 L2 地区（玩家双击地区时调用）
## [P] continent 已加载，region_id 在 continent.regions 内
## [Q] regions[region_id] 填充，current_granularity = L2, focused_parent_id = region_id
func load_region(region_id: String) -> Result:
	# TODO: SM-2 实现
	# 1. 检查 regions 是否已加载该 region（避免重复加载）
	# 2. 从 manifest 找到 region_<id>.tres 路径
	# 3. load() 加载 RegionData
	# 4. current_granularity = Granularity.L2_REGION
	# 5. focused_parent_id = region_id
	return Result.ok()


## 加载指定 L1 地块（玩家双击地块时调用）
## [P] 该 tile 所属 region 已加载
## [Q] tiles[tile_id] 填充，current_granularity = L1, focused_parent_id = tile_id
func load_tile(tile_id: String) -> Result:
	# TODO: SM-3 实现
	# 1. 检查 tiles 是否已加载该 tile
	# 2. 从 manifest 找到 tile_<id>.tres 路径
	# 3. load() 加载 MapTileData
	# 4. current_granularity = Granularity.L1_TILE
	# 5. focused_parent_id = tile_id
	return Result.ok()


## 卸载非相邻粒度的数据（内存控制）
## 拼接预览模式时保留相邻包，普通模式只保留当前粒度
func unload_distant(target_granularity: Granularity, keep_ids: Array[String]) -> void:
	# TODO: SM-2 实现
	# 普通模式：卸载非当前粒度的所有包
	# 拼接预览模式：保留 keep_ids 列表中的包
	pass


## 卸载所有 L2/L1 数据（返回 L3 时调用）
func unload_all_regions_and_tiles() -> void:
	regions.clear()
	tiles.clear()
	current_granularity = Granularity.L3_CONTINENT
	focused_parent_id = ""


# ===== 查询 =====

## 根据当前粒度和屏幕坐标查询最细粒度的 ID
## 返回 {"granularity": int, "region_id": String, "tile_id": String, "settlement_id": String}
## 未命中字段为 ""
func query_id_at_screen(screen_pos: Vector2) -> Dictionary:
	# TODO: SM-1 实现
	# 1. 用当前粒度的 boundary_mask_texture 采样 screen_pos
	# 2. 解码 RGB 得到当前粒度的 ID
	# 3. 补全上下层级 ID（L2 时查 continent 找 region_id，L1 时查 region 找 tile_id）
	return {
		"granularity": current_granularity,
		"region_id": "",
		"tile_id": "",
		"settlement_id": "",
	}


## 获取当前粒度下所有可见多边形
## 返回 [{"id": String, "polygon": PackedVector2Array, "owner_id": String, "biome": int}, ...]
func get_visible_polygons() -> Array[Dictionary]:
	# TODO: SM-1 实现
	# L3: 返回 continent 所有地区多边形
	# L2: 返回当前 region 所有地块多边形
	# L1: 返回当前 tile 所有聚落领地多边形
	return []


## 获取聚落引用（L1 粒度下）
func get_settlement(settlement_id: String) -> SettlementRef:
	if current_granularity != Granularity.L1_TILE:
		return null
	var tile: MapTileData = tiles.get(focused_parent_id, null)
	if tile == null:
		return null
	return tile.get_settlement(settlement_id)


## 获取当前地区数据（L2/L1 粒度下）
func get_current_region() -> RegionData:
	if current_granularity == Granularity.L2_REGION:
		return regions.get(focused_parent_id, null)
	if current_granularity == Granularity.L1_TILE:
		var tile: MapTileData = tiles.get(focused_parent_id, null)
		if tile != null:
			return regions.get(tile.parent_region_id, null)
	return null


## 获取当前地块数据（L1 粒度下）
func get_current_tile() -> MapTileData:
	if current_granularity != Granularity.L1_TILE:
		return null
	return tiles.get(focused_parent_id, null)


# ===== 政治属性（委托给 PoliticalData） =====

func get_region_owner(region_id: String) -> String:
	if political == null:
		return ""
	return political.get_region_owner(region_id)


func set_region_owner(region_id: String, state_id: String) -> void:
	if political == null:
		return
	political.set_region_owner(region_id, state_id)


func get_state_color(state_id: String) -> Color:
	if political == null:
		return Color.GRAY
	return political.get_state_color(state_id)


# ===== 内部辅助 =====

## Result 简易封装（对齐 docs/技术/架构/模块API.md 的 Result 模式）
class Result:
	static func ok() -> Result:
		var r = Result.new()
		r.set_meta("ok", true)
		return r

	static func err(msg: String) -> Result:
		var r = Result.new()
		r.set_meta("ok", false)
		r.set_meta("error", msg)
		return r

	func is_ok() -> bool:
		return get_meta("ok", false)

	func get_error() -> String:
		return get_meta("error", "")
