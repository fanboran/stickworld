class_name GridCell
extends RefCounted
## 占地网格竖向条带（1D）。
##
## 横向卷轴游戏中，世界按 32px 宽切分为竖向条带，
## 每个条带无限向上下延伸。建筑只占宽度（N 个条带），不关心垂直方向。
##
## 每个 cell 记录是否被占用 + 占用者引用。
## 占用者通常是 Building 节点或唯一标识符（String/Object）。

## 条带坐标（格子单位，非像素）
var cell_x: int = 0
## 是否被占用
var occupied: bool = false
## 占用者引用（Object 或 String id）；空闲时为 null
var occupant: Variant = null


func _init(p_x: int = 0) -> void:
	cell_x = p_x


## 设置占用
func set_occupied(p_occupant: Variant) -> void:
	occupied = true
	occupant = p_occupant


## 释放占用
func release() -> void:
	occupied = false
	occupant = null


func _to_string() -> String:
	return "GridCell(%d)%s" % [cell_x, "[O]" if occupied else "[]"]
