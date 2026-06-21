extends Resource
class_name WorldMapData
## 世界地图全局数据 —— 管理所有地块的定义和归属

## 所有地块定义（key=region_id）
@export var regions: Dictionary = {}

## 势力颜色表（key=owner_id, value=Color）
@export var owner_colors: Dictionary = {}

## 地块归属表（key=region_id, value=owner_id）
@export var region_owners: Dictionary = {}

## 默认无主地块颜色
@export var neutral_color: Color = Color(0.5, 0.5, 0.5, 1.0)

## 默认未探索地块颜色
@export var unexplored_color: Color = Color(0.1, 0.1, 0.1, 1.0)

## 地图尺寸（像素）
@export var map_size: Vector2 = Vector2(1024, 512)


## 获取地块数据
func get_region(region_id: int) -> RegionDefinition:
	return regions.get(region_id, null)

## 获取地块归属
func get_owner(region_id: int) -> int:
	return region_owners.get(region_id, -1)

## 设置地块归属
func set_owner(region_id: int, owner_id: int):
	region_owners[region_id] = owner_id

## 获取地块显示颜色（根据地图模式）
func get_region_color(region_id: int, mode: int) -> Color:
	var region: RegionDefinition = get_region(region_id)
	if region == null:
		return neutral_color

	match mode:
		0:  # POLITICAL 政治模式 —— 按归属势力着色
			var owner: int = get_owner(region_id)
			if owner == -1:
				return neutral_color
			return owner_colors.get(owner, neutral_color)

		1:  # TERRAIN 地形模式 —— 按地形类型着色
			match region.type:
				0:
					return Color(0.4, 0.7, 0.3)  # 陆地绿色
				1:
					return Color(0.2, 0.3, 0.8)  # 海洋蓝色
				2:
					return Color(0.2, 0.4, 0.9)  # 湖泊深蓝
				3:
					return Color(0.6, 0.3, 0.1)  # 荒原棕色
			return neutral_color

		2:  # RESOURCE 资源模式 —— 按资源类型着色
			if region.resource_types.is_empty():
				return neutral_color
			# 用资源名的hash来生成颜色
			var res_name: String = region.resource_types[0]
			var h: float = float(res_name.hash()) / 0x7fffffff
			return Color.from_hsv(h, 0.6, 0.8)

	return neutral_color

## 获取所有可通行陆地地块
func get_passable_land_regions() -> Array[int]:
	var result: Array[int] = []
	for id in regions:
		var region: RegionDefinition = regions[id]
		if region.is_land() and region.is_passable():
			result.append(id)
	return result
