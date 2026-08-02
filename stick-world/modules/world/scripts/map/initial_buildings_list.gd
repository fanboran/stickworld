class_name InitialBuildingsList
extends Node
## 初始建筑数据列表（§4.5 建筑三层架构）。
##
## 存储地图设计时预设的初始建筑定义（def_id + cell_x + width）。
## 地图首次加载时，VillageMap 读取此列表并将建筑写入存档 JSON。
## 非首次进入时跳过（存档已有）。
##
## 在 Godot 编辑器中可通过 Inspector 添加初始建筑条目。

## 单条初始建筑定义
class InitialBuildingDef:
	extends RefCounted
	## 建筑定义 ID（对应 buildings/ 下的 .tres 配置）
	var def_id: String = ""
	## 条带坐标 X（32px 网格）
	var cell_x: int = 0
	## 建筑宽度（条带数）
	var width: int = 1

## 初始建筑定义列表（Inspector 可编辑）
@export var building_defs: Array[Dictionary] = []


## 获取所有初始建筑定义
func get_defs() -> Array[InitialBuildingDef]:
	var result: Array[InitialBuildingDef] = []
	for d in building_defs:
		var def := InitialBuildingDef.new()
		def.def_id = d.get("def_id", "")
		def.cell_x = int(d.get("cell_x", 0))
		def.width = int(d.get("width", 1))
		result.append(def)
	return result


## 获取初始建筑数量
func get_count() -> int:
	return building_defs.size()
