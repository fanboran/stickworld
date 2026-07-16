class_name ConstructionManager
extends Node
## construction 模块内部管理器 —— §4 / §15 阶段 0.4。
##
## 由 api.gd 调用，外部模块不应直接引用。
##
## 职责：
##   1. 持有当前活跃的 ConstructionProject 列表，每帧 tick 推进进度
##   2. 持有 WorkCrewAssigner，负责派工
##   3. 维护已完工建筑注册表（building_id → Building）
##   4. 维护建筑场景模板注册表（def_id → PackedScene）
##   5. 接入地图：set_map(map) 注入 VillageMap 引用
##
## P0 简化：
##   - 不实现资源消耗（建造成本留到资源系统接入）
##   - 不实现存档 JSON 读写
##   - 不实现建筑等级升级
##   - org_id（组织 ID）参数保留但忽略

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const ScriptWorkCrewAssigner := preload("res://modules/construction/scripts/work_crew_assigner.gd")
const ScriptPlacementSystem := preload("res://modules/construction/placement/placement_system.gd")
const ScriptBuilding := preload("res://modules/buildings/scripts/building.gd")

# ─────────────────────────────── 字段 ────────────────────────────────

## 派工系统
var _assigner: ScriptWorkCrewAssigner = null
## 活跃项目列表 {project_id → ConstructionProject}
var _projects: Dictionary = {}
## 已完工建筑注册表 {building_id → Building}
var _buildings: Dictionary = {}
## 建筑 → building_id 反查（用于 demolish）
var _building_to_id: Dictionary = {}
## 建筑场景模板注册表 {def_id → PackedScene}
var _building_scene_registry: Dictionary = {}
## 项目 ID 自增计数器
var _next_project_id: int = 1
## 建筑 ID 自增计数器
var _next_building_id: int = 1
## 当前地图引用（由 set_map 注入）
var _map: Node2D = null


# ─────────────────────────────── 信号（供 api.gd 转发）────────────────────────────────

## 建筑完工。building_id 已分配。
signal building_completed(building_id: String, region_id: String)
## 建筑被拆除
signal building_removed(building_id: String, region_id: String)


func _ready() -> void:
	_assigner = ScriptWorkCrewAssigner.new()
	_register_default_building_scenes()


# ─────────────────────────────── 地图注入 ────────────────────────────────

## 由外部（GameRoot / SceneLoader）注入当前地图实例
func set_map(map: Node2D) -> void:
	_map = map


func get_map() -> Node2D:
	return _map


# ─────────────────────────────── 建筑场景注册 ────────────────────────────────

## 注册建筑场景模板（def_id → PackedScene）
func register_building_scene(def_id: String, scene: PackedScene) -> void:
	if def_id.is_empty() or scene == null:
		return
	_building_scene_registry[def_id] = scene


## P0 默认注册：bld_workshop
func _register_default_building_scenes() -> void:
	var workshop_scene := load("res://modules/buildings/scenes/bld_workshop.tscn") as PackedScene
	if workshop_scene != null:
		register_building_scene("bld_workshop", workshop_scene)
	else:
		push_warning("[ConstructionManager] 无法加载 bld_workshop.tscn")


# ─────────────────────────────── 每帧推进 ────────────────────────────────

func _physics_process(delta: float) -> void:
	# 推进所有活跃项目
	for p in _projects.values():
		if p is ScriptConstructionProject:
			(p as ScriptConstructionProject).tick(delta)


# ─────────────────────────────── 开工建造 ────────────────────────────────

## 开工建造（默认位置）。P0 在 cell_x=10 默认放建筑。
## [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
## [Q] 创建一个 Construction Project, building 状态=PLANNED
func start_construction(region_id: String, building_type: String, org_id: String = "") -> Dictionary:
	return start_construction_at(region_id, building_type, 10, org_id)


## 开工建造（指定位置 cell_x）。返回 {ok:true, project_id, cell_x, width} 或 {ok:false, error}。
func start_construction_at(region_id: String, building_type: String, cell_x: int, org_id: String = "") -> Dictionary:
	if _map == null:
		return {"ok": false, "error": "未设置地图（ConstructionManager.set_map 未调用）"}
	if not _building_scene_registry.has(building_type):
		return {"ok": false, "error": "未注册建筑类型: %s" % building_type}
	var scene: PackedScene = _building_scene_registry[building_type]
	# P0 硬编码默认 width=2, total_work=10.0；将来从建筑配置表读取
	var width: int = 2
	var total_work: float = 10.0
	# 校验选址
	var placement_grid: Node = _map.get("placement_grid") if "placement_grid" in _map else null
	if placement_grid == null:
		return {"ok": false, "error": "地图缺少 placement_grid"}
	var ps := ScriptPlacementSystem.new()
	var validate_result := ps.validate(placement_grid, cell_x, width)
	if not validate_result.ok:
		return {"ok": false, "error": "选址无效: %s" % validate_result.reason}
	# 创建项目
	var project_id := "proj_%04d" % _next_project_id
	_next_project_id += 1
	var project := ScriptConstructionProject.new(project_id, building_type, cell_x, width, _map, scene, total_work, region_id)
	_projects[project_id] = project
	_assigner.add_project(project)
	# 监听完工，自动注册 Building
	if not project.completed.is_connected(_on_project_completed):
		project.completed.connect(_on_project_completed)
	return {
		"ok": true,
		"project_id": project_id,
		"cell_x": cell_x,
		"width": width,
		"total_work": total_work,
	}


# ─────────────────────────────── 项目完工回调 ────────────────────────────────

## 项目完工：把 Building 注册到 _buildings，分配 building_id
func _on_project_completed(project: ScriptConstructionProject, building: Node) -> void:
	if building == null:
		return
	var building_id := "bld_%04d" % _next_building_id
	_next_building_id += 1
	# 在 Building 上存 building_id（如果支持）
	if building is ScriptBuilding:
		(building as ScriptBuilding).set_meta("building_id", building_id)
		(building as ScriptBuilding).set_meta("region_id", project.region_id)
	_buildings[building_id] = building
	_building_to_id[building] = building_id
	print("[ConstructionManager] 建筑完工: %s (def=%s, cell_x=%d)" % [building_id, project.def_id, project.cell_x])
	# 转发给 api.gd（building_completed 信号）
	building_completed.emit(building_id, project.region_id)


# ─────────────────────────────── 查询 ────────────────────────────────

## 查询地块内的所有建筑 ID
## P0 简化：不区分 region，返回所有建筑
func get_buildings_in_region(region_id: String) -> Array[String]:
	var result: Array[String] = []
	for b_id in _buildings.keys():
		result.append(b_id as String)
	return result


## 查询单个建筑的状态
func get_building_state(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var b: Node = _buildings[building_id]
	if not (b is ScriptBuilding):
		return {"ok": false, "error": "节点非 Building: %s" % building_id}
	var typed: ScriptBuilding = b as ScriptBuilding
	return {
		"ok": true,
		"building_id": building_id,
		"def_id": typed.def_id,
		"cell_x": typed.cell_x,
		"width": typed.width,
		"state": typed.state,
		"health": typed.health,
		"max_health": typed.max_health,
		"is_terrain": typed.is_terrain,
	}


## 查询项目状态（P0 扩展接口，供测试/调试用）
func get_project_state(project_id: String) -> Dictionary:
	if not _projects.has(project_id):
		return {"ok": false, "error": "项目不存在: %s" % project_id}
	var p: ScriptConstructionProject = _projects[project_id] as ScriptConstructionProject
	return {
		"ok": true,
		"project_id": project_id,
		"def_id": p.def_id,
		"cell_x": p.cell_x,
		"width": p.width,
		"state": p.state,
		"progress": p.get_progress(),
		"worker_count": p.get_worker_count(),
	}


## 获取所有项目 ID（供测试用）
func get_all_project_ids() -> Array:
	return _projects.keys()


# ─────────────────────────────── 拆除 ────────────────────────────────

## 拆除建筑
## [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed
func demolish_building(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var b: Node = _buildings[building_id]
	if not (b is ScriptBuilding):
		return {"ok": false, "error": "节点非 Building"}
	var typed: ScriptBuilding = b as ScriptBuilding
	if typed.is_terrain:
		return {"ok": false, "error": "地形建筑不可拆除"}
	# 释放 PlacementGrid 占用
	if _map != null and "placement_grid" in _map:
		var grid: Node = _map.placement_grid
		if grid != null and grid.has_method("release"):
			grid.release(typed)
	# 标记销毁
	typed.demolish()
	var region_id: String = typed.get_meta("region_id", "") if typed.has_meta("region_id") else ""
	# 从注册表移除
	_buildings.erase(building_id)
	_building_to_id.erase(b)
	# 释放节点
	if b is Node:
		(b as Node).queue_free()
	# 转发给 api.gd（building_removed 信号）
	building_removed.emit(building_id, region_id)
	return {"ok": true, "region_id": region_id}


# ─────────────────────────────── 升级 / 修理（P0 未实现）────────────────────────────────

## 升级建筑
## [P] building 状态=OPERATIONAL, 科技满足升级条件
## [Q] building 状态=UPGRADING
func upgrade_building(building_id: String) -> Dictionary:
	return {"ok": false, "error": "升级 P0 未实现"}


## 修理建筑
## [P] building 状态=DAMAGED
func repair_building(building_id: String, org_id: String) -> Dictionary:
	return {"ok": false, "error": "修理 P0 未实现"}


# ─────────────────────────────── 派工接口（供 BehaviorWork / AIController 调用）────────────────────────────────

## 获取派工系统
func get_assigner() -> ScriptWorkCrewAssigner:
	return _assigner


## 注册可派工工人
func register_worker(worker: Node) -> void:
	if _assigner == null:
		return
	_assigner.register_worker(worker)


## 取消注册工人
func unregister_worker(worker: Node) -> void:
	if _assigner == null:
		return
	_assigner.unregister_worker(worker)


## 自动派工：为工人找一个匹配项目
func try_assign_worker(worker: Node) -> bool:
	if _assigner == null:
		return false
	return _assigner.try_assign(worker)


## 获取工人当前派工的项目（无返回 null）
func get_worker_project(worker: Node) -> ScriptConstructionProject:
	if _assigner == null:
		return null
	return _assigner.get_worker_project(worker)
