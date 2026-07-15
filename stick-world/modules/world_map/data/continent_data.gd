class_name ContinentData
extends Resource
## L3 大世界数据 —— 整个大陆的鸟瞰图数据包
##
## 详见 docs/技术/架构/战略图架构.md §3.2
## 启动时必加载（1 份，整大陆）

## 大陆 ID（固定）
@export var continent_id: String = "continent_main"

## 锁定种子（用于按需生成派生数据）
@export var seed: int = 0

## 原始数据尺寸（8192×8192）
@export var size: Vector2i = Vector2i(8192, 8192)

## 该大陆所有地区 ID（L2 索引）
@export var regions: Array[String] = []

## 海洋掩码（用于河流裁剪、海岸线绘制；从 locked_continent_8192.png 加载）
@export var ocean_mask: Image = null

## 风格化底图（Python 工具预渲染，含草坪/火山/山脉/河流）
## 分辨率 4096×4096 或 8192×8192
@export var style_base_texture: Texture2D = null

## 边界索引图（每地区一色，NEAREST 采样保持边界锐利）
@export var boundary_mask_texture: Texture2D = null

## 该包在世界坐标系（0-8192）中的地理范围（拼接预览用）
@export var world_bounds: Rect2 = Rect2(0, 0, 8192, 8192)

## 河流矢量（每条河一个折线点列表，世界坐标 0-8192）
@export var rivers: Array[PackedVector2Array] = []
