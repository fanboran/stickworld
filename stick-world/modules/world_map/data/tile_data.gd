class_name TileData
extends Resource
## L1 地块数据 —— 单个地块的鸟瞰图数据包
##
## 详见 docs/技术/架构/战略图架构.md §3.4
## 双击地块时懒加载（每地块一份）
## 关键：L1 是"活的地图"，聚落规模随玩家建设实时变化

## 地块 ID（"tile_042"）
@export var tile_id: String = ""

## 所属地区 ID
@export var parent_region_id: String = ""

## 地块多边形（像素坐标，0-8192 范围）
@export var polygon: PackedVector2Array = PackedVector2Array()

## 生物群落
@export var biome: int = 0

## 恶劣度（影响聚落密度，§3.2 harshness）
@export var harshness: float = 0.0

## 聚落引用列表
@export var settlements: Array[SettlementRef] = []

## 资源禀赋
@export var resources: Array[ResourceDeposit] = []

## 河流（裁剪自 L3，每条河一个折线点列表）
@export var rivers: Array[PackedVector2Array] = []

## 道路（聚落间道路矢量，运行时绘制）
@export var roads: Array[RoadSegment] = []

## 中心城市 ID（可空，贫瘠地块无中心城市）
@export var central_city_id: String = ""

## 风格化底图（Python 工具预渲染，仅地形纹理，不含聚落/道路/资源）
## 分辨率 512×512 ~ 1024×1024（按地块大小）
@export var style_base_texture: Texture2D = null

## 边界索引图（聚落领地，NEAREST 采样）
@export var boundary_mask_texture: Texture2D = null

## 该包在世界坐标系（0-8192）中的地理范围（拼接预览用）
@export var world_bounds: Rect2 = Rect2.ZERO

## 邻接地块 ID（拼接预览用，同粒度）
@export var neighbors: Array[String] = []

## 边缘重叠像素数（避免拼接缝隙）
@export var edge_overlap: int = 2


## 获取中心城市聚落引用（无中心城市返回 null）
func get_central_city() -> SettlementRef:
	if central_city_id.is_empty():
		return null
	for s in settlements:
		if s != null and s.settlement_id == central_city_id:
			return s
	return null


## 获取指定聚落引用
func get_settlement(settlement_id: String) -> SettlementRef:
	for s in settlements:
		if s != null and s.settlement_id == settlement_id:
			return s
	return null
