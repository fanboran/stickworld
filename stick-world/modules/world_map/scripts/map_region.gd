extends Node2D
class_name MapRegion
## 地图上单个地块的可视化节点

## 地块ID
var region_id: int = -1

## 关联的地块数据引用
var region_data: RegionDefinition = null


## 初始化地块
func setup(p_region_id: int, p_region_data: RegionDefinition) -> void:
	region_id = p_region_id
	region_data = p_region_data
	_update_display()

func _update_display() -> void:
	if region_data == null:
		return
	queue_redraw()

func _draw() -> void:
	if region_data == null:
		return
	# 子类可重写此方法实现具体绘制逻辑
	pass
