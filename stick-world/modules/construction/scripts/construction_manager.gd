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
##   4. 接入地图：set_map(map) 注入 VillageMap 引用
##
## P0 简化：
##   - 不实现建筑等级升级
##   - org_id（组织 ID）参数保留但忽略
##
## 子节点：
##   BuildingCatalog     —— 建筑场景注册表与建筑定义（building_catalog.gd）
##   BuildingPersistence —— SQLite 存档/读档（building_persistence.gd）

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const ScriptWorkCrewAssigner := preload("res://modules/construction/scripts/work_crew_assigner.gd")
const ScriptPlacementSystem := preload("res://modules/construction/scripts/placement/placement_system.gd")
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")
const ScriptBuildProgressIndicator := preload("res://modules/construction/scripts/build_progress_indicator.gd")

const _BuildingCatalogScript: GDScript = preload("res://modules/construction/scripts/catalog/building_catalog.gd")
const _BuildingPersistenceScript: GDScript = preload("res://modules/construction/scripts/catalog/building_persistence.gd")

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
## ResourcesApi 引用（由 GameRoot 注入，P0-9 资源检查）
var _resources_api: Node = null
## 建筑定义缓存 {def_id: Dictionary}（P0-6 数据驱动）
var _building_defs_cache: Dictionary = {}
## 建造项目 -> 进度条指示器映射（阶段 E 双进度条）
var _project_indicators: Dictionary = {}

# ─────────────────────────────── 子组件引用 ────────────────────────────────
## 建筑目录系统（场景注册/定义加载，_ready 装配）
var _catalog: Node = null
## 持久化系统（SQLite 存档/读档，_ready 装配）
var _persistence: Node = null


# ─────────────────────────────── 信号（供 api.gd 转发）────────────────────────────────

## 建筑完工。building_id 已分配。
signal building_completed(building_id: String, region_id: String)
## 建筑被拆除
signal building_removed(building_id: String, region_id: String)


func _ready() -> void:
	_mount_components()
	_assigner = ScriptWorkCrewAssigner.new()
	_catalog.register_defaults()
	_catalog.load_defs()


## 实例化并挂载子组件（BuildingCatalog / BuildingPersistence）。
func _mount_components() -> void:
	_catalog = Node.new()
	_catalog.set_script(_BuildingCatalogScript)
	_catalog.name = "BuildingCatalog"
	add_child(_catalog)
	if _catalog.has_method("setup"):
		_catalog.setup(self)

	_persistence = Node.new()
	_persistence.set_script(_BuildingPersistenceScript)
	_persistence.name = "BuildingPersistence"
	add_child(_persistence)
	if _persistence.has_method("setup"):
		_persistence.setup(self)


# ─────────────────────────────── 地图注入 ────────────────────────────────

## 由外部（GameRoot / SceneLoader）注入当前地图实例。
## 地图切换时自动清空旧地图的建筑/项目注册表，防止悬空引用。
func set_map(map: Node2D) -> void:
	if _map != null and is_instance_valid(_map) and _map != map:
		# 地图切换：旧地图节点正被 SceneLoader 卸载，清空其建筑/项目注册表，
		# 否则 _buildings 会残留已释放 Node 引用，get_nearest_warehouse 等迭代会
		# 触发 "Trying to cast a freed object" 报错（详见 P0 收口执行计划）。
		_persistence._clear_all_buildings_and_projects()
	_map = map


func get_map() -> Node2D:
	return _map


## 查找距离 pos 最近的已完工仓库建筑（def_id=="bld_warehouse"）。
## 用于搬运工取货。无仓库返回 null。
func get_nearest_warehouse(pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	var stale: Array[String] = []
	for building_id: String in _buildings.keys():
		var entry = _buildings[building_id]
		# 先校验有效性再转型：对已释放对象执行 `as Node2D` 会报 "Trying to cast a freed object"
		if not is_instance_valid(entry):
			stale.append(building_id)
			continue
		var b: Node2D = entry as Node2D
		if b == null:
			continue
		if b.get("def_id") != "bld_warehouse":
			continue
		var d: float = b.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = b
	for bid in stale:
		_buildings.erase(bid)
	return best


## 查找距离 pos 最近的活跃建造项目（UNDER_CONSTRUCTION）。无项目返回 null。
func get_nearest_project(pos: Vector2) -> RefCounted:
	var best: RefCounted = null
	var best_dist: float = INF
	for p in _projects.values():
		if p is ScriptConstructionProject:
			var proj: ScriptConstructionProject = p as ScriptConstructionProject
			if proj.state != proj.State.UNDER_CONSTRUCTION:
				continue
			var center_x: float = float(proj.cell_x) * 32.0 + float(proj.width) * 16.0
			var d: float = absf(center_x - pos.x)
			if d < best_dist:
				best_dist = d
				best = proj
	return best


# ─────────────────────────────── 建筑场景注册（转发到 BuildingCatalog）────────────────────────────────

## 注册建筑场景模板（def_id → PackedScene）
func register_building_scene(def_id: String, scene: PackedScene) -> void:
	_catalog.register_scene(def_id, scene)


## 查询建筑定义
func get_building_def(def_id: String) -> Dictionary:
	return _catalog.get_def(def_id)


## 返回所有已注册场景的建筑 def_id（即可建造的建筑类型）
func get_registered_def_ids() -> Array:
	return _catalog.get_registered_def_ids()


## 建筑类型是否已注册场景（可建造）
func is_building_registered(def_id: String) -> bool:
	return _catalog.is_registered(def_id)


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
func start_construction_at(region_id: String, building_type: String, cell_x: int, _org_id: String = "") -> Dictionary:
	if _map == null:
		return {"ok": false, "error": "未设置地图（ConstructionManager.set_map 未调用）"}
	if not _catalog.is_registered(building_type):
		return {"ok": false, "error": "未注册建筑类型: %s" % building_type}
	var scene: PackedScene = _catalog.get_scene(building_type)
	# P0-9 资源检查
	if _resources_api != null:
		var cost_result := _check_and_consume_cost(building_type, region_id)
		if not cost_result.ok:
			return {"ok": false, "error": "资源不足: %s" % cost_result.reason}
	# P0-6 从 buildings.tres 读取 width 和 build_time
	var def: Dictionary = _catalog.get_def(building_type)
	var width: int = int(def.get("width", 2))
	var total_work: float = 8.0  # 固定8次敲击完工（后续由 Excel build_time 驱动）
	# 校验选址
	var placement_grid: Node = _map.get("placement_grid") if "placement_grid" in _map else null
	if placement_grid == null:
		return {"ok": false, "error": "地图缺少 placement_grid"}
	# 阶段 F：建造前触发地图动态扩展
	if _map.has_method("expand_map"):
		_map.expand_map(cell_x, width)
	var validate_result := ScriptPlacementSystem.validate(placement_grid, cell_x, width)
	if not validate_result.ok:
		return {"ok": false, "error": "选址无效: %s" % validate_result.reason}
	# 放置校验：选址范围内有实体（玩家/NPC）则拒绝，防止放置后玩家被罩在建筑内
	if _entity_blocking(cell_x, width):
		return {"ok": false, "error": "选址范围内有单位，无法放置"}
	# 阶段 F：建造自动清场（砍树给木材）
	_clear_resource_nodes_in_area(cell_x, width, region_id)
	# 创建项目
	var project_id := "proj_%04d" % _next_project_id
	_next_project_id += 1
	var project := ScriptConstructionProject.new(project_id, building_type, cell_x, width, _map, scene, total_work, region_id)
	_projects[project_id] = project
	_assigner.add_project(project)
	# 项目创建即立工地障碍（不等派工——否则无空闲工人时工地无碰撞箱，玩家可走进工地）
	project._create_barrier()
	# 监听完工，自动注册 Building
	if not project.completed.is_connected(_on_project_completed):
		project.completed.connect(_on_project_completed)
	# 阶段 E：创建双进度条指示器 + 监听进度
	_create_progress_indicator(project)
	if not project.progress_changed.is_connected(_on_project_progress):
		project.progress_changed.connect(_on_project_progress)
	return {
		"ok": true,
		"project_id": project_id,
		"cell_x": cell_x,
		"width": width,
		"total_work": total_work,
	}


# ─────────────────────────────── 资源检查与扣减（P0-9）────────────────────────────────

## 检查并扣减建造资源。返回 {ok:true} 或 {ok:false, reason}
func _check_and_consume_cost(building_type: String, region_id: String) -> Dictionary:
	if _resources_api == null:
		return {"ok": true}  # 资源系统未接入，跳过检查
	var def: Dictionary = _catalog.get_def(building_type)
	if def.is_empty():
		return {"ok": true}  # 无定义，跳过
	var costs: Dictionary = {}
	for key in ["build_cost_wood", "build_cost_stone", "build_cost_metal"]:
		if def.has(key) and float(def[key]) > 0:
			var res_id: String = key.replace("build_cost_", "res_")
			# build_cost_wood -> res_wood, build_cost_metal -> res_metal_ore（特殊映射）
			if key == "build_cost_metal":
				res_id = "res_metal_ore"
			costs[res_id] = float(def[key])
	if costs.is_empty():
		return {"ok": true}
	# 先检查
	for res_id in costs.keys():
		var stock: float = _resources_api.get_stock(res_id, region_id)
		if stock < costs[res_id]:
			return {"ok": false, "reason": "缺少 %s (需要 %d, 现有 %d)" % [res_id, costs[res_id], stock]}
	# 再扣减
	for res_id in costs.keys():
		var result: Dictionary = _resources_api.consume(res_id, costs[res_id], region_id, "建造:%s" % building_type)
		if not result.get("ok", false):
			return {"ok": false, "reason": "扣减失败: %s" % result.get("error", "")}
	return {"ok": true}


# ─────────────────────────────── 项目完工回调 ────────────────────────────────

## 项目完工：把 Building 注册到 _buildings，分配 building_id
func _on_project_completed(project: ScriptConstructionProject, building: Node) -> void:
	# 阶段 E：移除建造进度条
	_remove_progress_indicator(project.project_id)
	if building == null:
		return
	var building_id := "bld_%04d" % _next_building_id
	_next_building_id += 1
	# 在 Building 上存 building_id（如果支持）
	if building is ScriptBuilding:
		(building as ScriptBuilding).set_meta("building_id", building_id)
		(building as ScriptBuilding).set_meta("region_id", project.region_id)
		# D2: 应用数据驱动字段（interior_mode 等）
		var def: Dictionary = _catalog.get_def(project.def_id)
		if not def.is_empty() and (building as ScriptBuilding).has_method("apply_building_def"):
			(building as ScriptBuilding).apply_building_def(def)
	_buildings[building_id] = building
	_building_to_id[building] = building_id
	print("[ConstructionManager] 建筑完工: %s (def=%s, cell_x=%d)" % [building_id, project.def_id, project.cell_x])
	# 阶段 F：城墙完工时更新地形遮罩
	if building is ScriptBuilding and (building as ScriptBuilding).is_wall():
		_update_city_terrain_mask()
	# 转发给 api.gd（building_completed 信号）
	building_completed.emit(building_id, project.region_id)


# ─────────────────────────────── 建造进度条（阶段 E）────────────────────────────────

## 为项目创建双进度条指示器，挂到 map.BuildMaskLayer
func _create_progress_indicator(project: ScriptConstructionProject) -> void:
	if _map == null:
		return
	var mask_layer: Node2D = _map.get("build_mask_layer") if "build_mask_layer" in _map else null
	if mask_layer == null:
		mask_layer = _map.get_node_or_null("BuildMaskLayer")
	if mask_layer == null:
		return
	var indicator: Node2D = ScriptBuildProgressIndicator.new()
	indicator.setup(project.cell_x, project.width, float(_map.get("ground_y") if "ground_y" in _map else 810.0))
	mask_layer.add_child(indicator)
	_project_indicators[project.project_id] = indicator
	indicator.update_progress(project.get_material_progress(), project.get_progress())


## 项目进度变化回调：更新进度条
func _on_project_progress(project: ScriptConstructionProject, _progress: float) -> void:
	var indicator: Node2D = _project_indicators.get(project.project_id)
	if indicator != null and is_instance_valid(indicator):
		indicator.update_progress(project.get_material_progress(), project.get_progress())


## 移除项目进度条（完工/取消时调用）
func _remove_progress_indicator(project_id: String) -> void:
	var indicator: Node2D = _project_indicators.get(project_id)
	if indicator != null and is_instance_valid(indicator):
		indicator.queue_free()
	_project_indicators.erase(project_id)


# ─────────────────────────────── 城墙地形遮罩更新（阶段 F）────────────────────────────────

## 收集所有已完工城墙，通知地图更新城内/城外地形遮罩
func _update_city_terrain_mask() -> void:
	if _map == null or not _map.has_method("update_terrain_mask_from_walls"):
		return
	var walls: Array = []
	for b in _buildings.values():
		if not is_instance_valid(b):
			continue
		if b is ScriptBuilding and (b as ScriptBuilding).is_wall():
			var typed: ScriptBuilding = b as ScriptBuilding
			if typed.state == ScriptBuilding.State.OPERATIONAL or typed.state == ScriptBuilding.State.DAMAGED:
				walls.append({"cell_x": typed.cell_x, "width": typed.width})
	_map.update_terrain_mask_from_walls(walls)


# ─────────────────────────────── 建造自动清场（阶段 F §5.7.4.5）──────────────────────────────────

## 清理选址范围内的 ResourceNode，回收资源。
func _clear_resource_nodes_in_area(cell_x: int, width: int, region_id: String) -> void:
	if _map == null:
		return
	var cell_start_x: float = cell_x * 32.0
	var cell_end_x: float = (cell_x + width) * 32.0
	var nodes: Array = get_tree().get_nodes_in_group("resource_node")
	for node in nodes:
		if not node is Node2D or not is_instance_valid(node):
			continue
		var nx: float = (node as Node2D).global_position.x
		if nx >= cell_start_x - 16.0 and nx <= cell_end_x + 16.0:
			var res_id: String = ""
			var qty: int = 0
			if node.has_method("get_resource_id"):
				res_id = node.get_resource_id()
			if "amount" in node:
				qty = int(node.amount)
			if not res_id.is_empty() and qty > 0 and _resources_api != null:
				_resources_api.produce(res_id, qty, region_id, "建造清场")
			node.queue_free()


# ─────────────────────────────── 查询 ────────────────────────────────

## 查询地块内的所有建筑 ID
## P0 简化：不区分 region，返回所有建筑
func get_buildings_in_region(_region_id: String) -> Array[String]:
	var result: Array[String] = []
	for b_id in _buildings.keys():
		result.append(b_id as String)
	return result


## 查询单个建筑的状态
func get_building_state(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var b: Node = _buildings[building_id]
	if not is_instance_valid(b):
		return {"ok": false, "error": "建筑已释放: %s" % building_id}
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

## 选址范围内是否有实体（玩家/NPC）阻挡放置。
## 判定：实体脚部（Collider）位于建筑体 Y 范围（约 [baseline-390, baseline]）内且 X 在选址范围，
## 防止放置后玩家被罩在建筑内；站在建筑脚下空地（Y 更大）不算妨碍。
func _entity_blocking(cell_x: int, width: int) -> bool:
	if _map == null or not _map.has_method("get_entities"):
		return false
	var left_x: float = float(cell_x) * 32.0
	var right_x: float = left_x + float(width) * 32.0
	# 建筑体 Y 范围（与 PassageBarrier 一致：约 [baseline-390, baseline]，不含脚下空地）
	var ground_y: float = float(_map.get("ground_y") if "ground_y" in _map else 810.0)
	var baseline_offset: float = float(_map.get("building_baseline_offset") if "building_baseline_offset" in _map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var body_top: float = baseline - 390.0
	var body_bottom: float = baseline
	for e in _map.get_entities():
		if e == null or not is_instance_valid(e):
			continue
		var col := e.get_node_or_null("Collider") as CollisionShape2D
		var center_y: float = col.global_position.y if col != null else e.global_position.y
		var half_h: float = (col.shape as RectangleShape2D).size.y * 0.5 if col != null and col.shape is RectangleShape2D else 6.0
		if center_y + half_h < body_top or center_y - half_h > body_bottom:
			continue  # 脚部在建筑体区域外（脚下空地）→ 不挡
		var x: float = e.global_position.x
		if x >= left_x - 20.0 and x <= right_x + 20.0:
			return true
	return false


## 直接生成已完工建筑（OPERATIONAL 状态），跳过建造过程。
## 用于：InitialBuildingsList 预置建筑、地形建筑初始化、测试快速部署。
## 返回 {ok, building_id, cell_x, width} 或 {ok:false, error}。
func spawn_operational_building(def_id: String, cell_x: int, width: int = -1) -> Dictionary:
	if _map == null:
		return {"ok": false, "error": "未设置地图（ConstructionManager.set_map 未调用）"}
	if not _catalog.is_registered(def_id):
		return {"ok": false, "error": "未注册建筑类型: %s" % def_id}
	var scene: PackedScene = _catalog.get_scene(def_id)
	# D1: width=-1 时从 buildings.tres 读取
	var def: Dictionary = _catalog.get_def(def_id)
	if width < 0:
		width = int(def.get("width", 2))

	# 校验选址
	var placement_grid: Node = _map.get("placement_grid") if "placement_grid" in _map else null
	if placement_grid == null:
		return {"ok": false, "error": "地图缺少 placement_grid"}
	# 阶段 F：建造前触发地图动态扩展
	if _map.has_method("expand_map"):
		_map.expand_map(cell_x, width)
	var validate_result := ScriptPlacementSystem.validate(placement_grid, cell_x, width)
	if not validate_result.ok:
		return {"ok": false, "error": "选址无效: %s" % validate_result.reason}
	# 放置校验：选址范围内有实体（玩家/NPC）则拒绝，防止放置后玩家被罩在建筑内
	if _entity_blocking(cell_x, width):
		return {"ok": false, "error": "选址范围内有单位，无法放置"}

	# 阶段 F：建造自动清场（砍树给木材）
	_clear_resource_nodes_in_area(cell_x, width, "")

	# 实例化建筑场景
	var building: Node = scene.instantiate()
	if building == null or not building is Node2D:
		return {"ok": false, "error": "建筑场景实例化失败"}

	# 注入元数据
	if building is ScriptBuilding:
		var typed: ScriptBuilding = building as ScriptBuilding
		typed.def_id = def_id
		typed.cell_x = cell_x
		typed.width = width
		typed.is_terrain = false
		# D2: 应用数据驱动字段（interior_mode 等）
		if not def.is_empty() and typed.has_method("apply_building_def"):
			typed.apply_building_def(def)

	# 挂到 BuildingHost
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	if host == null:
		building.queue_free()
		return {"ok": false, "error": "map.building_host 不存在"}
	host.add_child(building)

	# 摆放位置：原点在建筑左下角，X=左边缘对齐 cell_x，Y=下边缘对齐建筑基准线（地平线向下 baseline_offset）
	var world_x: float = cell_x * 32.0
	var ground_y: float = float(_map.get("ground_y") if "ground_y" in _map else 810.0)
	var baseline_offset: float = float(_map.get("building_baseline_offset") if "building_baseline_offset" in _map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var collision_bottom_local: float = 0.0
	if building is ScriptBuilding:
		collision_bottom_local = (building as ScriptBuilding).get_collision_bottom_local()
	(building as Node2D).global_position = Vector2(world_x, baseline - collision_bottom_local)

	# 立即设为 OPERATIONAL
	if building is ScriptBuilding:
		(building as ScriptBuilding).set_state(ScriptBuilding.State.OPERATIONAL)

	# 注册到 PlacementGrid
	if placement_grid != null and placement_grid.has_method("occupy"):
		placement_grid.occupy(cell_x, width, building)

	# 注册 building_id
	var building_id := "bld_%04d" % _next_building_id
	_next_building_id += 1
	if building is ScriptBuilding:
		(building as ScriptBuilding).set_meta("building_id", building_id)
	_buildings[building_id] = building
	_building_to_id[building] = building_id

	print("[ConstructionManager] 预置建筑已生成: %s (def=%s, cell_x=%d, width=%d)" % [building_id, def_id, cell_x, width])
	return {"ok": true, "building_id": building_id, "cell_x": cell_x, "width": width}


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
func upgrade_building(_building_id: String) -> Dictionary:
	return {"ok": false, "error": "升级 P0 未实现"}


## 修理建筑
## [P] building 状态=DAMAGED
func repair_building(_building_id: String, _org_id: String) -> Dictionary:
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


# ─────────────────────────────── SQLite 存档（转发到 BuildingPersistence）────────────────────────────────

## 保存建筑和建造项目到 DB
func save_to_db(db, slot_id: int, map_id: String) -> void:
	_persistence.save_to_db(db, slot_id, map_id)


## 从 DB 恢复建筑和建造项目
func load_from_db(db, slot_id: int, map_id: String) -> void:
	_persistence.load_from_db(db, slot_id, map_id)
