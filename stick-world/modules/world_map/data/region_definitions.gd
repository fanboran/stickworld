extends Resource
class_name RegionDefinition
## [已废弃 2026-07-16] 旧的单粒度地块定义。
## 新架构按 L3/L2/L1 三级粒度拆分为 ContinentData/RegionData/TileData/SettlementRef。
## 详见 docs/技术/架构/战略图架构.md §三 数据模型 和 §9.3 迁移表。
## 本文件保留作为参考，不要在新代码中使用。
##
## 地块定义资源 —— 对应 P社 definition.csv 中一行数据

## 地块唯一ID（由 region_mask.png 中的 RGB 值换算而来）
@export var id: int = 0

## 地块名称
@export var name: String = ""

## 地块类型：0=陆地, 1=海洋, 2=湖泊, 3=荒原（不可通行）
@export var type: int = 0

## 是否沿海（陆地地块才有效）
@export var is_coastal: bool = false

## 该地块拥有的资源类型列表（如["iron", "wood", "gold"]）
@export var resource_types: Array[String] = []

## 该地块的火柴人种类列表（如["warrior", "archer", "mage"]）
@export var stickman_types: Array[String] = []

## 征服该地块后可解锁的科技ID列表
@export var tech_unlocks: Array[String] = []

## 初始归属势力ID（-1 表示无主/中立部落）
@export var initial_owner: int = -1

## 邻接地块ID列表（用于邻接判断和边境渲染）
@export var adjacent_region_ids: Array[int] = []

## 地块在地图上的中心坐标（用于UI标记放置）
@export var center_position: Vector2 = Vector2.ZERO

## 地块的轮廓多边形顶点（用于边框高亮，相对于地图坐标）
@export var outline_points: Array[Vector2] = []


## 是否是陆地
func is_land() -> bool:
	return type == 0

## 是否是可通行区域（非荒原）
func is_passable() -> bool:
	return type != 3

## 是否有指定资源
func has_resource(resource_name: String) -> bool:
	return resource_name in resource_types

## 是否有指定火柴人种类
func has_stickman_type(stickman_type: String) -> bool:
	return stickman_type in stickman_types

## 与另一个地块是否邻接
func is_adjacent_to(other_id: int) -> bool:
	return other_id in adjacent_region_ids
