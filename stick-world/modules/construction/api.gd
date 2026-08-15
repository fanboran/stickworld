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
@warning_ignore("unused_signal")
signal building_damaged(building_id: String, damage_amount: float)

## 建筑升级完成
@warning_ignore("unused_signal")
signal building_upgraded(building_id: String, old_tier: int, new_tier: int)


# ===== 内部引用（在 setup 中绑定） =====

var _manager: ConstructionManager
var _is_initialized: bool = false


# ===== 初始化 =====

## 注入内部管理器引用（参数用 Node 避免 api 表面暴露内部类型，2026-08 审计收敛）
func setup(manager: Object) -> void:
	_manager = manager as ConstructionManager
	_is_initialized = true
	# 转发 manager 的完工/拆除信号为 api.gd 的公共信号
	if not manager.building_completed.is_connected(_on_building_completed):
		manager.building_completed.connect(_on_building_completed)
	if not manager.building_removed.is_connected(_on_building_removed):
		manager.building_removed.connect(_on_building_removed)


# ─────────────────────────────── manager 信号转发 ────────────────────────────────

func _on_building_completed(building_id: String, region_id: String) -> void:
	building_completed.emit(building_id, region_id)


func _on_building_removed(building_id: String, region_id: String) -> void:
	building_removed.emit(building_id, region_id)


# ===== 建造 =====

## 开工建造
## [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
## [Q] 创建一个 Construction Project, building 状态=PLANNED, 发射 building_started
## P0 简化：building_started 信号第一参数为 project_id（建筑实例化前尚无 building_id）
func start_construction(region_id: String, building_type: String, org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.start_construction(region_id, building_type, org_id)
	if result.get("ok", false):
		building_started.emit(result.get("project_id", ""), region_id)
	return result


## 开工建造（指定位置 cell_x，可选 width 覆盖 def 宽度）
func start_construction_at(region_id: String, building_type: String, cell_x: int, org_id: String = "", width: int = -1) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.start_construction_at(region_id, building_type, cell_x, org_id, width)
	if result.get("ok", false):
		building_started.emit(result.get("project_id", ""), region_id)
	return result


## 直接生成 OPERATIONAL 状态建筑（绕过建造过程，用于初始建筑/仓库预置）。
## [P] def_id 已注册（get_registered_def_ids 包含它）
func spawn_operational_building(def_id: String, cell_x: int, width: int = 1) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.spawn_operational_building(def_id, cell_x, width)


## 注入当前地图（供项目实例化建筑使用；地图切换时调用）
func set_map(map: Node2D) -> void:
	if _is_initialized:
		_manager.set_map(map)


# ===== 工作委派 / 仓库查询（2026-08 收敛：AI 侧此前直调 manager 内部方法） =====

## 查询某工人当前派工的项目（无派工返回 null）
func get_worker_project(worker: Node) -> RefCounted:
	if not _is_initialized:
		return null
	return _manager.get_worker_project(worker)


## 尝试自动派工（附近有空闲项目则指派，返回是否派工成功）
func try_assign_worker(worker: Node) -> bool:
	if not _is_initialized:
		return false
	return _manager.try_assign_worker(worker)


## 查询距 pos 最近的仓库建筑（无则返回 null）
func get_nearest_warehouse(pos: Vector2) -> Node2D:
	if not _is_initialized:
		return null
	return _manager.get_nearest_warehouse(pos)


## 查询距 pos 最近的建造项目（无则返回 null）
func get_nearest_project(pos: Vector2) -> RefCounted:
	if not _is_initialized:
		return null
	return _manager.get_nearest_project(pos)


## 注册可派工工人（工人实体注入 construction 引用时调用；重复注册自动去重）
func register_worker(worker: Node) -> void:
	if not _is_initialized:
		return
	_manager.register_worker(worker)


## 取消注册工人（实体销毁时应调用，防止派工池悬垂引用）
func unregister_worker(worker: Node) -> void:
	if not _is_initialized:
		return
	_manager.unregister_worker(worker)


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
## [Q] 资源部分回收, building 状态=DESTROYED
## 注意：building_removed 信号由 manager.demolish_building 内部 emit，
##       通过 setup() 注册的转发回调自动 emit api.gd.building_removed，这里不重复 emit。
func demolish_building(building_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.demolish_building(building_id)


# ===== 修理 =====

## 修理建筑
## [P] building 状态=DAMAGED
func repair_building(building_id: String, org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.repair_building(building_id, org_id)


# ===== 存档对接（SaveHandler 经本契约调用，禁止直调内部 manager，2026-08-15 审计收敛）=====

## 保存建筑与建造项目到 DB（由 SaveHandler 在 EventBus.game_saving 回调中调用）
func save_to_db(db: Object, slot_id: int, map_id: String) -> void:
	if not _is_initialized:
		return
	_manager.save_to_db(db, slot_id, map_id)


## 从 DB 恢复建筑与建造项目（由 SaveHandler 在读档恢复流程中调用）
func load_from_db(db: Object, slot_id: int, map_id: String) -> void:
	if not _is_initialized:
		return
	_manager.load_from_db(db, slot_id, map_id)


## 读档后刷新城墙地形遮罩（manager 内部实现，经契约暴露给存档恢复流程）
func refresh_city_terrain_mask() -> void:
	if not _is_initialized:
		return
	_manager._update_city_terrain_mask()