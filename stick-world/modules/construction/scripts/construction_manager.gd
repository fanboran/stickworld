extends Node
class_name ConstructionManager
## construction 模块内部管理器 —— 负责建筑建造、升级、拆除、修理等核心逻辑。
##
## 本文件由 api.gd 调用，外部模块不应直接引用。

## 模块初始化
func _ready() -> void:
	pass


## 开工建造
## [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
## [Q] 创建一个 Construction Project, building 状态=PLANNED, 发射 building_started
func start_construction(region_id: String, building_type: String, org_id: String) -> Dictionary:
	# TODO: 实现建造逻辑
	return {"ok": false, "error": "未实现"}


## 查询地块内的所有建筑 ID
func get_buildings_in_region(region_id: String) -> Array[String]:
	# TODO: 实现查询逻辑
	return []


## 查询单个建筑的状态
func get_building_state(building_id: String) -> Dictionary:
	# TODO: 实现查询逻辑
	return {"ok": false, "error": "未实现"}


## 升级建筑
## [P] building 状态=OPERATIONAL, 科技满足升级条件
## [Q] building 状态=UPGRADING
func upgrade_building(building_id: String) -> Dictionary:
	# TODO: 实现升级逻辑
	return {"ok": false, "error": "未实现"}


## 拆除建筑
## [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed
func demolish_building(building_id: String) -> Dictionary:
	# TODO: 实现拆除逻辑
	return {"ok": false, "error": "未实现"}


## 修理建筑
## [P] building 状态=DAMAGED
func repair_building(building_id: String, org_id: String) -> Dictionary:
	# TODO: 实现修理逻辑
	return {"ok": false, "error": "未实现"}