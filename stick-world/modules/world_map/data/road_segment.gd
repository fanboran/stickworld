class_name RoadSegment
extends Resource
## 道路段 —— L1 地块图上的聚落间道路
##
## 详见 docs/技术/架构/战略图架构.md §3.4 MapTileData.roads

enum RoadClass {
	DIRT,       ## 土路（默认）
	PAVED,      ## 铺装路（后处理升级）
	HIGHWAY,    ## 官道（重要度高的主路）
}

## 道路折线点（地块多边形内归一化坐标 0-1）
@export var points: PackedVector2Array = PackedVector2Array()

## 道路等级
@export var road_class: RoadClass = RoadClass.DIRT

## 起点聚落 ID
@export var from_settlement_id: String = ""

## 终点聚落 ID
@export var to_settlement_id: String = ""

## 是否跨地块（跨地块道路在拼接预览模式才完整显示）
@export var cross_tile: bool = false
