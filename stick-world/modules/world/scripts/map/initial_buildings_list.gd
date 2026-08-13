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

## 初始建筑定义 JSON 路径（res://，0.9b 程序化聚落地图用）
## 若非空且 building_defs 为空，_ready 时从 JSON 加载
@export var defs_json_path: String = ""


func _ready() -> void:
	if building_defs.is_empty() and not defs_json_path.is_empty():
		_load_defs_from_json(defs_json_path)


## 从 JSON 加载初始建筑定义（程序化生成的地图用）
## JSON 格式：{"buildings": [{"def_id": str, "cell_x": int, "width": int}, ...]}
func load_defs_from_json(json_path: String) -> void:
	_load_defs_from_json(json_path)


func _load_defs_from_json(json_path: String) -> void:
	var text := FileAccess.get_file_as_string(json_path)
	if text.is_empty():
		push_warning("[InitialBuildingsList] 无法读取 %s" % json_path)
		return
	var data: Variant = JSON.parse_string(text)
	if data == null or not (data is Dictionary):
		push_warning("[InitialBuildingsList] JSON 解析失败: %s" % json_path)
		return
	var defs: Array = data.get("buildings", [])
	building_defs.clear()
	for d in defs:
		if d is Dictionary:
			building_defs.append(d)
	print_verbose("[InitialBuildingsList] 从 %s 加载 %d 条初始建筑" % [json_path, building_defs.size()])


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
