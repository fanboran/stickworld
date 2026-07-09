extends Node
## construction 模块公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 construction 内部脚本的方法。
##
## 建设层 —— 负责建筑和奇观的建造、升级、拆除、修理。

# ===== 公共信号 =====

## 建筑开始建造
signal building_started(building_id: String, region_id: String)

## 建筑建造完成
signal building_completed(building_id: String, region_id: String)

## 建筑已拆除
signal building_removed(building_id: String, region_id: String)

## 建筑受损
signal building_damaged(building_id: String, damage_amount: float)

## 建筑升级完成
signal building_upgraded(building_id: String, old_tier: int, new_tier: int)


# ===== 内部引用（在 setup 中绑定） =====

var _manager: ConstructionManager
var _is_initialized: bool = false


# ===== 初始化 =====

## 注入内部管理器引用
func setup(manager: ConstructionManager) -> void:
	_manager = manager
	_is_initialized = true


# ===== 建造 =====

## 开工建造
## [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
## [Q] 创建一个 Construction Project, building 状态=PLANNED, 发射 building_started
func start_construction(region_id: String, building_type: String, org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.start_construction(region_id, building_type, org_id)
	if result.get("ok", false):
		building_started.emit(result.get("building_id", ""), region_id)
	return result


# ===== 查询 =====

## 查询地块内的所有建筑 ID
func get_buildings_in_region(region_id: String) -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_buildings_in_region(region_id)


## 查询单个建筑的状态
func get_building_state(building_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.get_building_state(building_id)


# ===== 升级 =====

## 升级建筑
## [P] building 状态=OPERATIONAL, 科技满足升级条件
## [Q] building 状态=UPGRADING
func upgrade_building(building_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.upgrade_building(building_id)


# ===== 拆除 =====

## 拆除建筑
## [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed
func demolish_building(building_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.demolish_building(building_id)
	if result.get("ok", false):
		building_removed.emit(building_id, result.get("region_id", ""))
	return result


# ===== 修理 =====

## 修理建筑
## [P] building 状态=DAMAGED
func repair_building(building_id: String, org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.repair_building(building_id, org_id)