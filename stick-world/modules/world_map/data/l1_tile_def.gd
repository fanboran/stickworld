class_name L1TileDef
extends RefCounted
## L1 地块定义 —— 1 个 L1 地块 = 1 个聚落（或空聚落）
##
## 详见 docs/设计/系统/08-程序化世界生成.md §0.19
## 数据来源：tools/worldgen/l1/l1_worldgen.py 产出的 l1_world.json

## 地块 ID（"l1_tile_00"）
var tile_id: String = ""

## 地块多边形（像素坐标，底图坐标系）
var polygon: PackedVector2Array = PackedVector2Array()

## 聚落引用（null = 空聚落/贫瘠地块：无人无建筑、不可进入）
var settlement: SettlementRef = null

## 归属政权 ID（"state_00"）
var owner_state_id: String = ""


## 是否为空聚落（贫瘠地块）
func is_empty() -> bool:
	return settlement == null


## 地块质心（用于相机聚焦）
func get_centroid() -> Vector2:
	if polygon.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in polygon:
		sum += p
	return sum / polygon.size()
