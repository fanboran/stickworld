class_name RegionData
extends Resource
## L2 地区数据 —— 单个地区的鸟瞰图数据包
##
## 详见 docs/技术/架构/战略图架构.md §3.3
## 双击地区时懒加载（每地区一份）

## 地区 ID（"region_001"）
@export var region_id: String = ""

## 地区名称
@export var name: String = ""

## 地区多边形（像素坐标，0-8192 范围）
@export var polygon: PackedVector2Array = PackedVector2Array()

## 邻接地区 ID
@export var adjacent_regions: Array[String] = []

## 主导生物群落（§0.4 "基本一个气候"）
@export var dominant_biome: int = 0

## 该地区所有地块 ID（L1 索引）
@export var tiles: Array[String] = []

## 政治属性（运行时可改，通过 EventBus 同步）
@export var political_owner: String = ""

## 所属联盟 ID（可空）
@export var alliance: String = ""

## 风格化底图（Python 工具预渲染，该地区裁剪）
## 分辨率 1024×1024 ~ 2048×2048（按地区大小）
@export var style_base_texture: Texture2D = null

## 边界索引图（每地块一色，NEAREST 采样）
@export var boundary_mask_texture: Texture2D = null

## 该包在世界坐标系（0-8192）中的地理范围（拼接预览用）
@export var world_bounds: Rect2 = Rect2()

## 邻接地区 ID（拼接预览用，同粒度）
@export var neighbors: Array[String] = []

## 地标列表（矿坑/魔力泉/港口/要塞，运行时动态放置）
@export var landmarks: Array[LandmarkRef] = []
