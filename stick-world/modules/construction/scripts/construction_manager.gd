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
##   BuildingCatalog     —— 建筑场景注册表与建筑定义（catalog/building_catalog.gd）
##   BuildingPersistence —— SQLite 存档/读档（catalog/building_persistence.gd）
##
## 持有组件（RefCounted，随 manager 生命周期）：
##   WorkCrewAssigner    —— 派工系统（work_crew_assigner.gd）
##   BuildingCosts       —— 建造成本提取与扣减（building_costs.gd，P0-9）
##   BuildProgressTracker —— 建造进度条跟踪（build_progress_tracker.gd，阶段 E）

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const ScriptWorkCrewAssigner := preload("res://modules/construction/scripts/work_crew_assigner.gd")
const ScriptPlacementSystem := preload("res://modules/construction/scripts/placement/placement_system.gd")
const ScriptBuildingCosts := preload("res://modules/construction/scripts/building_costs.gd")
const ScriptBuildProgressTracker := preload("res://modules/construction/scripts/build_progress_tracker.gd")

const _BuildingCatalogScript: GDScript = preload("res://modules/construction/scripts/catalog/building_catalog.gd")
const _BuildingPersistenceScript: GDScript = preload("res://modules/construction/scripts/catalog/building_persistence.gd")

## building_gen 公共契约（L1，跨模块 preload 仅限 api.gd 的合规出口）——
## plan 物化的管线 def → 运行时 def 映射查它（INT-4 单源）
const _BuildingGenAPI: GDScript = preload("res://modules/building_gen/api.gd")

## 占地条带宽（px）：锚定 PlacementGrid.CELL_SIZE（world 模块 L3，construction
## 不得 preload 反向依赖，换轨时两处同步——同 build_menu/behavior_work 口径）
const CELL_PX: float = 24.0

# ─────────────────────────────── 字段 ────────────────────────────────

## 派工系统
var _assigner: ScriptWorkCrewAssigner = null
## 活跃项目列表 {project_id → ConstructionProject}（_physics_process 只 tick 本表）
var _projects: Dictionary = {}
## 已完工项目 {project_id → ConstructionProject}（不再 tick，保留供 get_project_state 查询）
var _finished_projects: Dictionary = {}
## 已完工建筑注册表 {building_id → Building}
var _buildings: Dictionary = {}
## 建筑 → building_id 反查（用于 demolish）
var _building_to_id: Dictionary = {}
## 建筑场景模板注册表 {def_id → PackedScene}（数据由 building_catalog 跨脚本写入，故加忽略）
@warning_ignore("unused_private_class_variable")
var _building_scene_registry: Dictionary = {}
## 项目 ID 自增计数器
var _next_project_id: int = 1
## 建筑 ID 自增计数器
var _next_building_id: int = 1
## 当前地图引用（由 set_map 注入）
var _map: Node2D = null
## ResourcesApi 引用（由 GameRoot 注入，P0-9 资源检查）
var _resources_api: Node = null
## 建筑定义缓存 {def_id: Dictionary}（P0-6 数据驱动；同样由 building_catalog 跨脚本读写）
@warning_ignore("unused_private_class_variable")
var _building_defs_cache: Dictionary = {}
## 建造成本系统（P0-9，提取与扣减）
var _costs: ScriptBuildingCosts = ScriptBuildingCosts.new()
## 建造进度条跟踪器（阶段 E 双进度条）
var _indicators: ScriptBuildProgressTracker = ScriptBuildProgressTracker.new()

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
## 建筑升级完成（旧等级→新等级；发射点与 api.gd 转发均为 3 参，
## 声明少参会让 emit 运行时报错、api 层转发永不触发）
signal building_upgraded(building_id: String, old_level: int, new_level: int)
## 建筑修理完成
signal building_repaired(building_id: String)


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
	# 阶段 E：进度条跟踪器同步地图引用
	_indicators.set_map(map)
	# ROOT-2：CityGen plan 物化（布局图前排 → Building 实体；duck 协议，非布局图自然跳过）
	_materialize_plan_buildings(map)


# ─────────────────────────────── CityGen plan 物化（ROOT-2）────────────────────────

## plan 物化幂等标记（挂 map 上，防 set_map 重复触发）
const _PLAN_MATERIALIZED_META := "_plan_buildings_materialized"

## 城市布局 plan → Building 实体：烘卡只做视觉（3D 街景照摆），实体承载玩法
## （工位/交互区/注册表——工位·招兵·仓库·生产·住房五链的宿主）。
## SPN-3 性能口径第一档：按图物化——每图一聚落，进图物化本图前排（10~40 栋
## 无外部视觉的 Node2D 壳，轻量）；窗口级懒物化归 M4 焦点实体化。
## 幂等：map meta 标记；换图时旧实体随 BuildingHost/注册表一起清（set_map 头部）。
func _materialize_plan_buildings(map: Node2D) -> void:
	if map == null or not map.has_method("get_plan_buildings"):
		return
	if map.has_meta(_PLAN_MATERIALIZED_META):
		return
	map.set_meta(_PLAN_MATERIALIZED_META, true)
	var entries: Array = map.get_plan_buildings()
	if entries.is_empty():
		return
	var host: Node2D = map.get("building_host") if "building_host" in map else null
	var grid: Node = map.get("placement_grid") if "placement_grid" in map else null
	if host == null:
		push_warning("[ConstructionManager] plan 物化跳过：map.building_host 不存在")
		return
	var spawned: int = 0
	for entry: Variant in entries:
		if _materialize_one_plan_building(map, host, grid, entry):
			spawned += 1
	print_verbose("[ConstructionManager] plan 物化: %d/%d 栋 (%s)" % [spawned, entries.size(), map.name])


## 物化单栋：管线 def 查映射（无映射=纯视觉卡，跳过不算错）→ 实例化场景 →
## 视觉壳模式 + 按宽比缩放 → 贴卡落位 → occupy_force + 注册进 _buildings。
## 落位口径：x 贴卡精确左沿（非取整格——3D 卡是视觉真相源，实体几何随它）；
## y = 卡脚基线 − 碰撞底×缩放（缩放后碰撞底的实际伸长按比例折算）。
func _materialize_one_plan_building(map: Node2D, host: Node2D, grid: Node, entry: Variant) -> bool:
	var pipeline_def: String = str(entry.get("def", ""))
	var def_id: String = _BuildingGenAPI.runtime_def_for_pipeline(pipeline_def)
	if def_id.is_empty() or not _catalog.is_registered(def_id):
		return false
	var plan_cells: float = float(entry.get("cells", 0.0))
	var center: float = float(entry.get("x", 0.0))
	if plan_cells <= 0.0:
		return false
	var cell_x: int = floori(center - plan_cells * 0.5)
	var width: int = ceili(center + plan_cells * 0.5) - cell_x
	var scene: PackedScene = _catalog.get_scene(def_id)
	if scene == null:
		return false
	var building: Node = scene.instantiate()
	if building == null or not building is Node2D:
		push_warning("[ConstructionManager] plan 物化场景实例化失败: %s" % def_id)
		return false
	var typed: Building = building as Building
	# def 宽（32px 轨美术原生格数）→ plan 宽（实际占格）统一缩放：障碍/交互区/
	# 工位整体随缩；外部视觉已关（视觉壳），缩放只对齐玩法几何与卡脚印
	var def: Dictionary = _catalog.get_def(def_id)
	var def_width: int = int(def.get("width", width)) if not def.is_empty() else width
	var scale_factor: float = float(width) / float(def_width) if def_width > 0 else 1.0
	(building as Node2D).scale = Vector2(scale_factor, scale_factor)
	if typed != null:
		typed.def_id = def_id
		typed.cell_x = cell_x
		typed.width = width
		# 城市既有建筑：3D 卡永在，拆实体=视觉与玩法失联 → 不可拆
		typed.is_terrain = true
		if not def.is_empty() and typed.has_method("apply_building_def"):
			typed.apply_building_def(def)
		# plan 物化标记：存档侧据此跳过（plan 确定性重生成，不归 DB 管）
		typed.set_meta("plan_generated", true)
	host.add_child(building)
	if typed != null:
		typed.set_visual_shell_only(true)
		if typed.has_method("set_map_reference"):
			typed.set_map_reference(map)
	var baseline: float = float(map.call("get_plan_baseline_y", float(entry.get("z", 0.6)))) \
			if map.has_method("get_plan_baseline_y") else 0.0
	var world_x: float = (center - plan_cells * 0.5) * CELL_PX
	var cbl: float = typed.get_collision_bottom_local() if typed != null else 0.0
	(building as Node2D).global_position = Vector2(world_x, baseline - cbl * scale_factor)
	if typed != null:
		typed.set_state(Building.State.OPERATIONAL)
	# 占用（含 blocked 态格——封锁本就来自同一建筑的 3D 卡带）
	if grid != null and grid.has_method("occupy_force"):
		grid.occupy_force(cell_x, width, building)
	# 注册进管理表（get_nearest_warehouse/编号查询等玩法链消费）
	var building_id := "%04d" % _next_building_id
	_next_building_id += 1
	building.set_meta("building_id", building_id)
	_buildings[building_id] = building
	_building_to_id[building] = building_id
	_on_buildings_changed()
	return true


# ─────────────────────────────── 资源系统注入 ────────────────────────────────

## 由 SystemSetup 注入 ResourcesApi 引用。
## 2026-08 修复：此前缺失此注入点，system_setup 的 has_method 守卫恒 false，
## 导致 _resources_api 恒为 null，资源检查/扣减/清场回收永久静默失效。
func set_resources_api(resources_api: Node) -> void:
	_resources_api = resources_api
	# P0-9：成本系统同步注入（扣减/回滚经 BuildingCosts 执行）
	_costs.set_resources_api(resources_api)


func get_map() -> Node2D:
	return _map


## 仓库子集缓存（搬运工取货/交互提示每物理帧查询，免每次全建筑扫描）。
## _buildings 任何变更点（完工注册/直建/拆除/读档清空重建）置脏，下帧查询重扫一次。
## 废墟过滤按查询时 state 实时判（建筑可在注册后被炸成 DESTROYED）。
var _warehouse_cache: Array = []
var _warehouse_cache_dirty: bool = true


## _buildings 变更后调用（本模块与 building_persistence 直接写表处共用）
func _on_buildings_changed() -> void:
	_warehouse_cache_dirty = true


func _get_warehouse_list() -> Array:
	if _warehouse_cache_dirty:
		_warehouse_cache = []
		var stale_ids: Array[String] = []
		for building_id: String in _buildings.keys():
			var entry = _buildings[building_id]
			# 先校验有效性再转型：对已释放对象执行 `as Node2D` 会报 "Trying to cast a freed object"
			if not is_instance_valid(entry):
				stale_ids.append(building_id)
				continue
			var b: Node2D = entry as Node2D
			if b != null and (b.get("def_id") == "warehouse" or b.get("def_id") == "placeholder"):
				_warehouse_cache.append(b)
		for bid in stale_ids:
			_buildings.erase(bid)
		_warehouse_cache_dirty = false
	return _warehouse_cache


## 查找距离 pos 最近的已完工仓库建筑（def_id=="warehouse"）。
## 用于搬运工取货。无仓库返回 null。
func get_nearest_warehouse(pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist_sq: float = INF
	for b in _get_warehouse_list():
		if not is_instance_valid(b):
			_warehouse_cache_dirty = true
			continue
		# 废墟不当仓库（被炸毁后注册表尚未移除的窗口期，搬运工不再认废墟取货）
		if b is Building and (b as Building).state == Building.State.DESTROYED:
			continue
		var d_sq: float = b.global_position.distance_squared_to(pos)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = b
	return best


## 项目查询快照缓存（get_nearest_project 被搬运工 AI 每物理帧调用，100 项目下
## 每次全扫 values() 数组分配 + 逐项类型断言占成本大头，基准 bench_infra_construction）。
## 缓存元素 = [center_x: float, project]（项目选址字段创建后不可变，中心坐标预计算）。
## _projects 增删点（开工/完工移表/读档清空重建）置脏；state 过滤在查询时实时判——
## PLANNED→UNDER_CONSTRUCTION 转换不经 manager，但缓存持引用不过滤状态，无失效窗口。
var _project_cache: Array = []
var _project_cache_dirty: bool = true


## _projects 增删后调用（开工注册/完工移表/读档清空重建共用）
func _on_projects_changed() -> void:
	_project_cache_dirty = true


func _rebuild_project_cache() -> void:
	_project_cache = []
	for p in _projects.values():
		if p is ScriptConstructionProject:
			var proj: ScriptConstructionProject = p as ScriptConstructionProject
			_project_cache.append([float(proj.cell_x) * CELL_PX + float(proj.width) * CELL_PX * 0.5, proj])
	_project_cache_dirty = false


## 查找距离 pos 最近的活跃建造项目（UNDER_CONSTRUCTION）。无项目返回 null。
func get_nearest_project(pos: Vector2) -> RefCounted:
	if _project_cache_dirty:
		_rebuild_project_cache()
	var best: RefCounted = null
	var best_dist: float = INF
	for entry: Array in _project_cache:
		var proj: ScriptConstructionProject = entry[1]
		if proj.state != proj.State.UNDER_CONSTRUCTION:
			continue
		var d: float = absf(entry[0] - pos.x)
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


## 建筑是否已解锁（奖励闭环的数据侧门禁）：def 的 `unlocked_by_tech` = 需已获的
## 解锁/科技 id，比对 WorldState.unlocks 台账（含开局基线，见 WorldState.STARTING_UNLOCKS）；
## 未声明要求恒为已解锁。展示侧（BuildMenu 灰显）与建造入口（start_construction_at
## 拒建）共用本判定，禁止两处分叉
func is_def_unlocked(def_id: String) -> bool:
	var req := get_def_unlock_requirement(def_id)
	if req.is_empty():
		return true
	return WorldState != null and WorldState.has_unlock(req)


## 建筑所需解锁/科技 id（未声明要求返回空串；目录未装配时同样按无要求——装配时序不影响判定）
func get_def_unlock_requirement(def_id: String) -> String:
	if _catalog == null:
		return ""
	return String(_catalog.get_def(def_id).get("unlocked_by_tech", ""))


func _physics_process(delta: float) -> void:
	# 推进所有活跃项目：步长经 sim_delta 携带速度档；暂停冻结由引擎总闸负责
	# （本节点 PAUSABLE——此前无暂停门禁，暂停期建造照走，"假暂停"旧账一并了结）
	if TimeManager != null:
		delta = TimeManager.sim_delta(delta)
	# 推进所有活跃项目（完工项目移入 _finished_projects，本循环不再随历史建造数增长）；
	# 复用项目快照缓存（_projects 增删点置脏），免每帧 values() 数组分配
	if _project_cache_dirty:
		_rebuild_project_cache()
	for entry: Array in _project_cache:
		(entry[1] as ScriptConstructionProject).tick(delta)


# ─────────────────────────────── 开工建造 ────────────────────────────────

## 开工建造（默认位置）。P0 在 cell_x=10 默认放建筑。
## [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
## [Q] 创建一个 Construction Project, building 状态=PLANNED
func start_construction(region_id: String, building_type: String, org_id: String = "") -> Dictionary:
	return start_construction_at(region_id, building_type, 10, org_id)


## 开工建造（指定位置 cell_x，可选 width 覆盖 def 宽度）。返回 {ok:true, project_id, cell_x, width} 或 {ok:false, error}。
func start_construction_at(region_id: String, building_type: String, cell_x: int, _org_id: String = "", width: int = -1, baseline_y: float = -1.0) -> Dictionary:
	# 请求合法性先于环境就绪判定（未注册/未解锁与地图无关，也不因缺地图而被掩盖）
	if not _catalog.is_registered(building_type):
		return {"ok": false, "error": "未注册建筑类型: %s" % building_type}
	if not is_def_unlocked(building_type):
		return {"ok": false, "error": "未解锁建筑: %s（需先取得对应技术/战果）" % building_type}
	if _map == null:
		return {"ok": false, "error": "未设置地图（ConstructionManager.set_map 未调用）"}
	var scene: PackedScene = _catalog.get_scene(building_type)
	# P0-6 从 buildings.tres 读取 build_time；width 默认取 def，可由调用方覆盖
	var def: Dictionary = _catalog.get_def(building_type)
	if width <= 0:
		width = int(def.get("width", 2))
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
	if _entity_blocking(cell_x, width, baseline_y):
		return {"ok": false, "error": "选址范围内有单位，无法放置"}
	# P0-9 资源检查（校验与扣减放在选址/实体校验之后：此前先扣资源再校验，
	# 校验失败会白扣资源，2026-08 审计修复）
	if _resources_api != null:
		var cost_result := _costs.check_and_consume(def, region_id, "建造:%s" % building_type)
		if not cost_result.ok:
			return {"ok": false, "error": "资源不足: %s" % cost_result.reason}
	# 阶段 F：建造自动清场（砍树给木材）
	_clear_resource_nodes_in_area(cell_x, width, region_id)
	# 创建项目
	var project_id := "proj_%04d" % _next_project_id
	_next_project_id += 1
	var project := ScriptConstructionProject.new(project_id, building_type, cell_x, width, _map, scene, total_work, region_id)
	# 落位深度（建造菜单传鼠标点击深度；≤0 时由地图口径推导，见 _baseline_at）
	project.baseline_y = baseline_y
	# D2 数据驱动：def 随项目携带，完工时 apply_building_def 应用到建筑（interior_mode 等）
	project.building_def = def
	_projects[project_id] = project
	_on_projects_changed()
	_assigner.add_project(project)
	# 项目创建即立工地障碍（不等派工——否则无空闲工人时工地无碰撞箱，玩家可走进工地）
	project._create_barrier()
	# 监听完工，自动注册 Building
	if not project.completed.is_connected(_on_project_completed):
		project.completed.connect(_on_project_completed)
	# 阶段 E：创建双进度条指示器 + 监听进度
	_indicators.track(project)
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
	# 阶段 E：移除建造进度条
	_indicators.untrack(project.project_id)
	# 完工项目移出活跃表（此前只增不删，_physics_process 30Hz 遍历量随历史建造数
	# 单调增长）；转入 _finished_projects 保留查询（get_project_state 测试契约）
	_projects.erase(project.project_id)
	_on_projects_changed()
	_finished_projects[project.project_id] = project
	if building == null:
		return
	var building_id := "%04d" % _next_building_id
	_next_building_id += 1
	# 在 Building 上存 building_id（如果支持）
	if building is Building:
		(building as Building).set_meta("building_id", building_id)
		(building as Building).set_meta("region_id", project.region_id)
		# D2: 应用数据驱动字段（interior_mode 等）
		var def: Dictionary = _catalog.get_def(project.def_id)
		if not def.is_empty() and (building as Building).has_method("apply_building_def"):
			(building as Building).apply_building_def(def)
	_buildings[building_id] = building
	_building_to_id[building] = building_id
	_on_buildings_changed()
	print_verbose("[ConstructionManager] 建筑完工: %s (def=%s, cell_x=%d)" % [building_id, project.def_id, project.cell_x])
	# 阶段 F：城墙完工时更新地形遮罩
	if building is Building and (building as Building).is_wall():
		_update_city_terrain_mask()
	# 转发给 api.gd（building_completed 信号）
	building_completed.emit(building_id, project.region_id)


# ─────────────────────────────── 城墙地形遮罩更新（阶段 F）────────────────────────────────

## 收集所有已完工城墙，通知地图更新城内/城外地形遮罩
func _update_city_terrain_mask() -> void:
	if _map == null or not _map.has_method("update_terrain_mask_from_walls"):
		return
	var walls: Array = []
	for b in _buildings.values():
		if not is_instance_valid(b):
			continue
		if b is Building and (b as Building).is_wall():
			var typed: Building = b as Building
			if typed.state == Building.State.OPERATIONAL or typed.state == Building.State.DAMAGED:
				walls.append({"cell_x": typed.cell_x, "width": typed.width})
	_map.update_terrain_mask_from_walls(walls)


# ─────────────────────────────── 建造自动清场（阶段 F §5.7.4.5）──────────────────────────────────

## 清理选址范围内的 ResourceNode，回收资源。
func _clear_resource_nodes_in_area(cell_x: int, width: int, region_id: String) -> void:
	if _map == null:
		return
	var cell_start_x: float = cell_x * CELL_PX
	var cell_end_x: float = (cell_x + width) * CELL_PX
	# 经地图查询接口取资源点（替代全局 group 扫描，2026-08 收敛）
	var nodes: Array = _map.get_resource_nodes() if _map.has_method("get_resource_nodes") else []
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
## region_id 为空时返回全部；否则按建筑 meta.region_id 过滤
func get_buildings_in_region(region_id: String) -> Array[String]:
	var result: Array[String] = []
	for b_id in _buildings.keys():
		var b: Node = _buildings[b_id]
		if not is_instance_valid(b):
			continue
		if not region_id.is_empty():
			var b_region: String = str(b.get_meta("region_id", "")) if b.has_meta("region_id") else ""
			if b_region != region_id:
				continue
		result.append(b_id as String)
	return result


## 注册/更新建筑定义（运行时与测试注入用；替代白盒写 _building_defs_cache，2026-08 审计）
func set_building_def(def_id: String, def: Dictionary) -> void:
	_building_defs_cache[def_id] = def


## 移除建筑定义
func clear_building_def(def_id: String) -> void:
	_building_defs_cache.erase(def_id)


## 按 ID 取建筑节点（替代白盒读 _buildings，2026-08 审计；含失效引用防护）
func get_building_node(building_id: String) -> Node:
	var b = _buildings.get(building_id)
	return b if is_instance_valid(b) else null


## 查询单个建筑的状态
func get_building_state(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var b: Node = _buildings[building_id]
	if not is_instance_valid(b):
		return {"ok": false, "error": "建筑已释放: %s" % building_id}
	if not (b is Building):
		return {"ok": false, "error": "节点非 Building: %s" % building_id}
	var typed: Building = b as Building
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


## 查询项目状态（P0 扩展接口，供测试/调试用）。活跃与已完工项目均可查。
func get_project_state(project_id: String) -> Dictionary:
	var p: ScriptConstructionProject = null
	if _projects.has(project_id):
		p = _projects[project_id] as ScriptConstructionProject
	elif _finished_projects.has(project_id):
		p = _finished_projects[project_id] as ScriptConstructionProject
	if p == null:
		return {"ok": false, "error": "项目不存在: %s" % project_id}
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


## 获取所有项目 ID（供测试用，含已完工）
func get_all_project_ids() -> Array:
	return _projects.keys() + _finished_projects.keys()


# ─────────────────────────────── 拆除 ────────────────────────────────

## 落位基线（px，画布域）：地图支持逐格墙脚线（HD-2D，get_building_baseline_at）
## 则按格子范围取邻居楼线，否则 ground_y + building_baseline_offset（旧图回退）。
func _baseline_at(cell_x: int, width: int, baseline_y: float = -1.0) -> float:
	if baseline_y > 0.0:
		return baseline_y
	if _map != null and _map.has_method("get_building_baseline_at"):
		return float(_map.call("get_building_baseline_at", cell_x, width))
	var ground_y: float = float(_map.get("ground_y") if _map != null and "ground_y" in _map else 810.0)
	var off: float = float(_map.get("building_baseline_offset") if _map != null and "building_baseline_offset" in _map else 96.0)
	return ground_y + off


## 选址范围内是否有实体（玩家/NPC）阻挡放置。
## 判定：实体脚部（Collider）位于建筑体 Y 范围（约 [baseline-390, baseline]）内且 X 在选址范围，
## 防止放置后玩家被罩在建筑内；站在建筑脚下空地（Y 更大）不算妨碍。
func _entity_blocking(cell_x: int, width: int, baseline_y: float = -1.0) -> bool:
	if _map == null or not _map.has_method("get_entities"):
		return false
	var left_x: float = float(cell_x) * CELL_PX
	var right_x: float = left_x + float(width) * CELL_PX
	# 建筑体 Y 范围（与 PassageBarrier 一致：约 [baseline-390, baseline]，不含脚下空地）
	# 基线与实际落位同源（点击深度优先；旧图 duck 回退 ground_y+offset）
	var baseline: float = _baseline_at(cell_x, width, baseline_y)
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
func spawn_operational_building(def_id: String, cell_x: int, width: int = -1, baseline_y: float = -1.0) -> Dictionary:
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
	if _entity_blocking(cell_x, width, baseline_y):
		return {"ok": false, "error": "选址范围内有单位，无法放置"}

	# 阶段 F：建造自动清场（砍树给木材）
	_clear_resource_nodes_in_area(cell_x, width, "")

	# 实例化建筑场景
	var building: Node = scene.instantiate()
	if building == null or not building is Node2D:
		return {"ok": false, "error": "建筑场景实例化失败"}

	# 注入元数据
	if building is Building:
		var typed: Building = building as Building
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
	# 注入地图引用（建筑判定玩家实体用，2026-08 审计收敛）
	if building.has_method("set_map_reference"):
		building.set_map_reference(_map)

	# 摆放位置：原点在建筑左下角，X=左边缘对齐 cell_x，Y=下边缘对齐建筑基线
	# （基线与预览/工地同源：点击深度优先，否则地图口径）
	var world_x: float = float(cell_x) * CELL_PX
	var baseline: float = _baseline_at(cell_x, width, baseline_y)
	var collision_bottom_local: float = 0.0
	if building is Building:
		collision_bottom_local = (building as Building).get_collision_bottom_local()
	(building as Node2D).global_position = Vector2(world_x, baseline - collision_bottom_local)
	# 建筑 y-sort：根位置 = 基线 - collision_bottom_local（≈地平线+96px），
	# BuildingHost y_sort_enabled 后按此排序（差 ≤5px，可忽略）

	# 立即设为 OPERATIONAL
	if building is Building:
		(building as Building).set_state(Building.State.OPERATIONAL)

	# 注册到 PlacementGrid
	if placement_grid != null and placement_grid.has_method("occupy"):
		placement_grid.occupy(cell_x, width, building)

	# 注册 building_id
	var building_id := "%04d" % _next_building_id
	_next_building_id += 1
	if building is Building:
		(building as Building).set_meta("building_id", building_id)
	_buildings[building_id] = building
	_building_to_id[building] = building_id
	_on_buildings_changed()

	print_verbose("[ConstructionManager] 预置建筑已生成: %s (def=%s, cell_x=%d, width=%d)" % [building_id, def_id, cell_x, width])
	return {"ok": true, "building_id": building_id, "cell_x": cell_x, "width": width}


# ─────────────────────────────── 拆除 ────────────────────────────────

## 拆除建筑
## [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed
func demolish_building(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var b: Node = _buildings[building_id]
	if not (b is Building):
		return {"ok": false, "error": "节点非 Building"}
	var typed: Building = b as Building
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
	_on_buildings_changed()
	# 释放节点
	if b is Node:
		(b as Node).queue_free()
	# 转发给 api.gd（building_removed 信号）
	building_removed.emit(building_id, region_id)
	return {"ok": true, "region_id": region_id}


# ─────────────────────────────── 升级 / 修理（2026-08-22 实现）────────────────────────────────

## 升级建筑（阶段 1 简化：即时完成，不走工时项目）
## 效果：升级等级 +1，max_health +20%，回满血。外观差异化由 building_gen 阶段 B 补。
## [P] building 状态=OPERATIONAL
## [Q] 消耗 0.5×建造成本；building.upgrade_level +1；发射 building_upgraded
func upgrade_building(building_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var typed := _buildings[building_id] as Building
	if typed == null:
		return {"ok": false, "error": "节点非 Building"}
	if typed.state != Building.State.OPERATIONAL:
		return {"ok": false, "error": "仅运营中的建筑可升级"}
	var region_id: String = typed.get_meta("region_id", "") if typed.has_meta("region_id") else ""
	if _resources_api != null:
		var def: Dictionary = _catalog.get_def(typed.def_id)
		if not def.is_empty():
			var cost_result := _costs.consume(ScriptBuildingCosts.extract_def_costs(def, 0.5), region_id, "升级:%s" % typed.def_id)
			if not cost_result.get("ok", false):
				return cost_result
	typed.upgrade_level += 1
	typed.max_health *= 1.2
	typed.health = typed.max_health
	building_upgraded.emit(building_id, typed.upgrade_level - 1, typed.upgrade_level)
	return {"ok": true, "upgrade_level": typed.upgrade_level}


## 修理建筑（阶段 1 简化：即时完成，不走工时项目）
## 成本 = 缺损比例 × 0.3 × 建造成本
## [P] building 状态=DAMAGED 或 health < max_health
## [Q] 回满血并恢复 OPERATIONAL；发射 building_repaired
func repair_building(building_id: String, _org_id: String) -> Dictionary:
	if not _buildings.has(building_id):
		return {"ok": false, "error": "建筑不存在: %s" % building_id}
	var typed := _buildings[building_id] as Building
	if typed == null:
		return {"ok": false, "error": "节点非 Building"}
	if typed.health >= typed.max_health:
		return {"ok": false, "error": "建筑无需修理"}
	if typed.state == Building.State.DESTROYED:
		return {"ok": false, "error": "已销毁的建筑不可修理"}
	var missing_ratio: float = 1.0 - typed.health / maxf(typed.max_health, 0.01)
	var region_id: String = typed.get_meta("region_id", "") if typed.has_meta("region_id") else ""
	if _resources_api != null:
		var def: Dictionary = _catalog.get_def(typed.def_id)
		if not def.is_empty():
			var cost_result := _costs.consume(
					ScriptBuildingCosts.extract_def_costs(def, 0.3 * missing_ratio), region_id, "修理:%s" % typed.def_id)
			if not cost_result.get("ok", false):
				return cost_result
	typed.health = typed.max_health
	if typed.state == Building.State.DAMAGED:
		typed.set_state(Building.State.OPERATIONAL)
	building_repaired.emit(building_id)
	return {"ok": true}


# ─────────────────────────────── 派工接口（供 BehaviorWork / AIController 调用）────────────────────────────────

## 全部有效建筑节点（调试面板列表用）
func get_all_buildings() -> Array:
	var out: Array = []
	for b in _buildings.values():
		if is_instance_valid(b):
			out.append(b)
	return out


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


## 空闲工人名单（拷贝；招兵/人口统计消费）
func get_available_workers() -> Array:
	if _assigner == null:
		return []
	return _assigner.get_available_workers()


## 获取工人当前派工的项目（无返回 null）
func get_worker_project(worker: Node) -> ScriptConstructionProject:
	if _assigner == null:
		return null
	return _assigner.get_worker_project(worker)


# ─────────────────────────────── SQLite 存档（转发到 BuildingPersistence）────────────────────────────────

## 保存建筑和建造项目到 DB
func save_to_db(db: Object, slot_id: int, map_id: String) -> void:
	_persistence.save_to_db(db, slot_id, map_id)


## 从 DB 恢复建筑和建造项目
func load_from_db(db: Object, slot_id: int, map_id: String) -> void:
	_persistence.load_from_db(db, slot_id, map_id)
