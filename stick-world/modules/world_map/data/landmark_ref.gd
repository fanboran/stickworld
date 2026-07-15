class_name LandmarkRef
extends Resource
## 地标引用 —— L2 地区图上的 Q 版地标图标
##
## 详见 docs/技术/架构/战略图架构.md §3.3 RegionData.landmarks

enum LandmarkType {
	MINE,           ## 矿坑
	MAGIC_SOURCE,   ## 魔力源泉
	PORT,           ## 港口
	FORTRESS,       ## 要塞
	RUINS,          ## 废墟/遗迹
	VOLCANO,        ## 火山
}

## 地标类型
@export var type: LandmarkType = LandmarkType.MINE

## 地标名称
@export var name: String = ""

## 位置（地区多边形内归一化坐标 0-1）
@export var position: Vector2 = Vector2.ZERO

## 关联的地块 ID（地标跨越地块时记录）
@export var tile_id: String = ""

## 图标资源路径（运行时加载，未指定时按 type 用默认图标）
@export var icon_path: String = ""
