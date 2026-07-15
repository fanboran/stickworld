class_name SettlementRef
extends Resource
## 聚落引用 —— L1 地块图上的聚落（轻量，不存场景图内部数据）
##
## 详见 docs/技术/架构/战略图架构.md §3.5
## 关键：聚落规模随玩家建设实时变化，L1 地图上聚落建筑群动态生成

## 聚落级别
enum Level {
	VILLAGE = 1,    ## T1 村落（一小团建筑）
	TOWN = 2,       ## T2 镇/大部落
	CITY = 3,       ## T3 城市（有城墙）
	CAPITAL = 4,    ## T4 中心城市
	IMPERIAL = 5,   ## T5 帝国首都（特殊建筑集）
}

## 聚落 ID（格式：settlement_<tile_id>_<idx>）
@export var settlement_id: String = ""

## 聚落名称
@export var name: String = ""

## 级别（1-5）
@export var level: int = Level.VILLAGE

## 支柱产业标签（"mining" / "trade" / "military" / "magic" / "agriculture" / "fishery"）
@export var industry: Array[String] = []

## 位置（地块多边形内归一化坐标 0-1）
@export var position: Vector2 = Vector2.ZERO

## 规模分数（0-1，运行时可被 ±15% 扰动；玩家建设改变此值 → L1 地图聚落大小实时变化）
@export var population_score: float = 0.0

## 对应场景图的 map_id（双击聚落时 SceneLoader.load_map 用）
@export var map_id: String = ""

## 锁定种子（用于确定性生成聚落建筑群布局，详见 SettlementRenderer）
@export var layout_seed: int = 0


## 获取建筑群占地半径（像素，L1 地图坐标系）
## 详见 docs/技术/架构/战略图架构.md §4.6
func get_footprint_radius() -> float:
	# TODO: SM-3 实现，按 level + population_score 计算
	# 基础值：T1=16, T2=32, T3=64, T4=96, T5=128
	# 乘以 population_score 的非线性映射（下限偏置，大部分贴近下限）
	return 16.0


## 获取建筑数量
func get_building_count() -> int:
	# TODO: SM-3 实现，按 level + population_score 计算
	# T1: 3-5, T2: 6-10, T3: 15-30, T4: 40-80, T5: 100+
	return 3
