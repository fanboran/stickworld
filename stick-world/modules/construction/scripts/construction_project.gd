class_name ConstructionProject
extends RefCounted
## 建造项目状态机 —— §4.5 建筑三层架构 / §15 阶段 0.4。
##
## 一个项目对应一栋待建建筑。状态流转：
##   PLANNED → UNDER_CONSTRUCTION → OPERATIONAL
##                                  ↘ CANCELLED
##
## 职责：
##   - 持有选址（cell_x + width）和建筑定义（def_id + 场景模板）
##   - 接收派工（assign_worker），第一个工人到位自动开工
##   - 每帧 tick 推进进度，工人越多建造越快
##   - 进度满时实例化 Building 场景，挂到 BuildingHost，注册到 PlacementGrid
##
## 由 ConstructionManager 创建和管理；BehaviorWork 通过 ConstructionManager 派工。

const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")
const ScriptPlacementSystem := preload("res://modules/construction/scripts/placement/placement_system.gd")

# ─────────────────────────────── 状态 ────────────────────────────────

enum State {
	PLANNED,              ## 已立项但未开工（无工人）
	UNDER_CONSTRUCTION,   ## 建造中（有工人正在工作）
	OPERATIONAL,          ## 完工，建筑已实例化
	CANCELLED,            ## 被取消（资源不足/超时等）
}

# ─────────────────────────────── 字段 ────────────────────────────────

## 项目唯一 ID（由 ConstructionManager 分配，格式如 "proj_0001"）
var project_id: String = ""
## 建筑定义 ID（对应 config/buildings/ 下的 .tres，预留）
var def_id: String = ""
## 条带坐标 X（地图网格坐标）
var cell_x: int = 0
## 占地宽度（条带数）
var width: int = 1
## 所属区域 ID（用于 start_construction(region_id, ...)，P0 留空）
var region_id: String = ""
## 地图引用（用于实例化 Building 到 BuildingHost、查询 ground_y 等）
var map: Node2D = null
## 建筑场景模板（P0 由 ConstructionManager 根据 def_id 查表注入）
var building_scene: PackedScene = null
## 完工所需总工作量（人·秒）。P0 默认 10.0（单人 10 秒建完，双人 5 秒）
var total_work: float = 10.0
## 已累计工作量（建造进度 = current_work / total_work）
var current_work: float = 0.0
## 材料进度 [0,1]（搬运工推进，阶段 E 双进度条）
var material_progress: float = 0.0

# ─────────────────────────────── 运行时 ────────────────────────────────

## 当前状态
var state: State = State.PLANNED
## 已派工的工人列表（StickmanEntity[]）
var _assigned_workers: Array = []
## 工人 -> 工作位索引映射（避免多名工人挤同一 slot）
var _worker_slot_map: Dictionary = {}
## 当前认领搬运工的工人（null=无搬运工）。同一项目最多一个搬运工。
var _hauler: Node = null
## 每次搬运交付的材料进度增量（25%，4 次往返填满）
const HAUL_PAYLOAD_FRACTION: float = 0.25
## 工地临时障碍（建造中阻挡通行，完工移除）
var _barrier: StaticBody2D = null
## 完工后实例化的 Building 引用（state != OPERATIONAL 时为 null）
var building: Node = null

# ─────────────────────────────── 信号 ────────────────────────────────

## 项目开工
signal started(project: ConstructionProject)
## 进度变化（每 tick 触发）
signal progress_changed(project: ConstructionProject, progress: float)
## 项目完工，building 已实例化到 BuildingHost
signal completed(project: ConstructionProject, building: Node)
## 工人被派工到此项目
signal worker_assigned(project: ConstructionProject, worker: Node)
## 工人离开项目
signal worker_unassigned(project: ConstructionProject, worker: Node)
## 项目被取消
signal cancelled(project: ConstructionProject)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _init(
		p_project_id: String,
		p_def_id: String,
		p_cell_x: int,
		p_width: int,
		p_map: Node2D,
		p_building_scene: PackedScene,
		p_total_work: float = 10.0,
		p_region_id: String = ""
		) -> void:
	project_id = p_project_id
	def_id = p_def_id
	cell_x = p_cell_x
	width = p_width
	map = p_map
	building_scene = p_building_scene
	total_work = p_total_work
	region_id = p_region_id


# ─────────────────────────────── 派工 ────────────────────────────────

## 派工一名工人到此项目。返回是否成功。
## 第一个工人到位时自动将状态从 PLANNED 切到 UNDER_CONSTRUCTION。
func assign_worker(worker: Node) -> bool:
	if worker == null:
		return false
	if state == State.OPERATIONAL or state == State.CANCELLED:
		return false
	if worker in _assigned_workers:
		return true  # 已派工，幂等返回成功
	_assigned_workers.append(worker)
	# 分配工作位索引（循环复用）
	var slot_index: int = (_assigned_workers.size() - 1) % _get_max_work_slots_hint()
	_worker_slot_map[worker] = slot_index
	worker_assigned.emit(self, worker)
	# 第一个工人自动开工
	if state == State.PLANNED:
		_start()
	return true


## 解除工人派工。
func unassign_worker(worker: Node) -> void:
	if worker == null:
		return
	if not _assigned_workers.has(worker):
		return
	_assigned_workers.erase(worker)
	_worker_slot_map.erase(worker)
	worker_unassigned.emit(self, worker)
	# 工人全部离开：项目保留状态，可继续派工；P0 不自动取消


## 获取已派工的工人列表（拷贝）
func get_assigned_workers() -> Array:
	return _assigned_workers.duplicate()


## 已派工人数
func get_worker_count() -> int:
	return _assigned_workers.size()


## 此工人是否已派工到此项目
func has_worker(worker: Node) -> bool:
	return _assigned_workers.has(worker)


## 获取工人分配的工作位索引（无返回 -1）
func get_worker_slot_index(worker: Node) -> int:
	if not _worker_slot_map.has(worker):
		return -1
	return int(_worker_slot_map[worker])


# ─────────────────────────────── 推进 ────────────────────────────────

## 每帧调用，推进项目进度。
## 阶段 E 双进度：材料进度（搬运工）+ 建造进度（建造工，受材料限制：建造 ≤ 材料）。
## P0 简化：所有工人同时推进材料与建造，材料速率 1.5x 建造（材料条先满）。
func tick(delta: float) -> void:
	if state != State.UNDER_CONSTRUCTION:
		return
	# total_work<=0（如 bld_placeholder）直接完工
	if total_work <= 0.0:
		material_progress = 1.0
		current_work = total_work
		progress_changed.emit(self, get_progress())
		_complete()
		return
	# 进度由 add_build_progress（建造工敲击）和 deliver_material（搬运工）行为驱动


## 获取当前建造进度 [0, 1]
func get_progress() -> float:
	if total_work <= 0.0:
		return 1.0
	return clampf(current_work / total_work, 0.0, 1.0)


## 获取当前材料进度 [0, 1]（阶段 E 双进度条）
func get_material_progress() -> float:
	return material_progress


## 是否需要搬运建材：材料未满且建造进度已追上材料进度。
func needs_material() -> bool:
	if total_work <= 0.0:
		return false
	if material_progress >= 1.0:
		return false
	return (current_work / total_work) >= material_progress - 0.001


## 认领搬运工。同一项目最多一个搬运工，返回 true 表示认领成功。
## 若该 worker 已认领则返回 true（幂等）。
func try_claim_hauler(worker: Node) -> bool:
	if _hauler == worker:
		return true  # 已认领
	if _hauler != null and is_instance_valid(_hauler):
		return false
	_hauler = worker
	return true


## 释放搬运工认领。
func release_hauler(worker: Node) -> void:
	if _hauler == worker:
		_hauler = null


## 搬运工交付建材，推进材料进度。
func deliver_material(fraction: float = HAUL_PAYLOAD_FRACTION) -> void:
	material_progress = minf(material_progress + fraction, 1.0)
	progress_changed.emit(self, get_progress())


## 建造工敲击一次推进建造进度。受材料进度限制（建造 ≤ 材料）。
## 由 BehaviorWork / 玩家在播放 build 动画后调用。
func add_build_progress(amount: float) -> void:
	if state != State.UNDER_CONSTRUCTION:
		return
	if total_work <= 0.0:
		_complete()
		return
	var build_cap: float = material_progress * total_work
	current_work = minf(current_work + amount, build_cap)
	progress_changed.emit(self, get_progress())
	if current_work >= total_work:
		_complete()


# ─────────────────────────────── 内部状态转换 ────────────────────────────────

## 开工：PLANNED → UNDER_CONSTRUCTION
func _start() -> void:
	if state != State.PLANNED:
		return
	state = State.UNDER_CONSTRUCTION
	started.emit(self)
	_create_barrier()


## 创建工地临时障碍（建造中阻挡通行，完工移除）。
## 从建筑场景模板读取 PassageBarrier 碰撞箱参数，确保与完工后建筑完全一致。
func _create_barrier() -> void:
	if _barrier != null and is_instance_valid(_barrier):
		return  # 已创建（项目创建时与第一个工人派工时都可能调用）
	if map == null:
		return
	var host: Node2D = map.get("walk_barrier") if "walk_barrier" in map else null
	if host == null:
		return
	# 从建筑场景模板读取 PassageBarrier 碰撞箱参数
	var barrier_size: Vector2 = Vector2(float(width) * 32.0, 390.0)
	var barrier_offset_x: float = float(width) * 16.0
	var barrier_offset_y: float = -190.0
	if building_scene != null:
		var temp := building_scene.instantiate()
		if temp != null:
			var pb := temp.get_node_or_null("PassageBarrier") if temp is Node else null
			if pb != null:
				for child in pb.get_children():
					if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
						var cs := child as CollisionShape2D
						barrier_size = ((cs.shape as RectangleShape2D).size)
						barrier_offset_x = cs.position.x
						barrier_offset_y = cs.position.y
						break
			temp.queue_free()
	_barrier = StaticBody2D.new()
	_barrier.visible = false
	# 与实体同层（layer 2）：实体 collision_mask=3 包含 layer 2，move_and_slide 自然阻挡
	_barrier.collision_layer = 2
	_barrier.collision_mask = 0
	var shape := RectangleShape2D.new()
	shape.size = barrier_size
	var col := CollisionShape2D.new()
	col.shape = shape
	_barrier.add_child(col)
	# 建筑原点 Y = baseline - collision_bottom_local
	# collision_bottom_local = barrier_offset_y + barrier_size.y / 2
	# 障碍 CollisionShape2D 世界坐标 = 建筑原点 + (barrier_offset_x, barrier_offset_y)
	var ground_y: float = float(map.get("ground_y") if "ground_y" in map else 810.0)
	var baseline_offset: float = float(map.get("building_baseline_offset") if "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var collision_bottom_local: float = barrier_offset_y + barrier_size.y * 0.5
	var building_origin_y: float = baseline - collision_bottom_local
	_barrier.position = Vector2(float(cell_x) * 32.0 + barrier_offset_x, building_origin_y + barrier_offset_y)
	host.add_child(_barrier)


## 完工：UNDER_CONSTRUCTION → OPERATIONAL
## 实例化 Building 场景到 BuildingHost，注册 PlacementGrid。
func _complete() -> void:
	if state != State.UNDER_CONSTRUCTION:
		return
	# 移除工地临时障碍（Building 的 PassageBarrier 接管）
	if _barrier != null and is_instance_valid(_barrier):
		_barrier.queue_free()
		_barrier = null
	if map == null:
		push_error("[ConstructionProject] map 为 null，无法实例化建筑: %s" % project_id)
		return
	if building_scene == null:
		push_error("[ConstructionProject] building_scene 为 null: %s" % project_id)
		return
	# 实例化建筑
	var b: Node = building_scene.instantiate()
	if b == null:
		push_error("[ConstructionProject] 建筑场景实例化失败: %s" % project_id)
		return
	var new_building := b as Node2D
	if new_building == null:
		push_error("[ConstructionProject] 建筑根节点非 Node2D: %s" % project_id)
		return
	# 注入元数据
	if new_building is ScriptBuilding:
		var typed: ScriptBuilding = new_building as ScriptBuilding
		typed.def_id = def_id
		typed.cell_x = cell_x
		typed.width = width
		typed.is_terrain = false
	# 挂到 BuildingHost
	var host: Node2D = map.get("building_host") if "building_host" in map else null
	if host == null:
		push_error("[ConstructionProject] map.building_host 不存在: %s" % project_id)
		new_building.queue_free()
		return
	host.add_child(new_building)
	# 计算世界坐标：原点在建筑左下角，X=左边缘对齐 cell_x，Y=下边缘对齐建筑基准线（地平线向下 baseline_offset）
	var cell_size: int = 32
	var placement_grid: Node = map.get("placement_grid") if "placement_grid" in map else null
	if placement_grid != null and "CELL_SIZE" in placement_grid:
		cell_size = int(placement_grid.CELL_SIZE)
	var world_x: float = float(cell_x) * float(cell_size)
	var ground_y: float = float(map.get("ground_y") if "ground_y" in map else 810.0)
	var baseline_offset: float = float(map.get("building_baseline_offset") if "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var collision_bottom_local: float = 0.0
	if new_building is ScriptBuilding:
		collision_bottom_local = (new_building as ScriptBuilding).get_collision_bottom_local()
	new_building.global_position = Vector2(world_x, baseline - collision_bottom_local)
	# 标记建筑为 OPERATIONAL（触发视觉/碰撞更新）
	if new_building is ScriptBuilding:
		(new_building as ScriptBuilding).set_state(ScriptBuilding.State.OPERATIONAL)
	# 注册到 PlacementGrid（占用格子）
	if placement_grid != null and placement_grid.has_method("occupy"):
		placement_grid.occupy(cell_x, width, new_building)
	# 切换状态
	state = State.OPERATIONAL
	self.building = new_building
	completed.emit(self, new_building)


## 取消项目（P0 简化：仅状态转换 + 通知工人离开）
func cancel() -> void:
	if state == State.OPERATIONAL or state == State.CANCELLED:
		return
	state = State.CANCELLED
	# 通知所有工人离开
	var snapshot := _assigned_workers.duplicate()
	for w in snapshot:
		worker_unassigned.emit(self, w)
	_assigned_workers.clear()
	_worker_slot_map.clear()
	cancelled.emit(self)


# ─────────────────────────────── 查询 ────────────────────────────────

## 工作位 hint：P0 简化为 4，实际应读 Building.def_id 查配置表
func _get_max_work_slots_hint() -> int:
	return 4


## 是否可派工（PLANNED 或 UNDER_CONSTRUCTION 状态）
func is_accepting_workers() -> bool:
	return state == State.PLANNED or state == State.UNDER_CONSTRUCTION


## 是否已完工
func is_operational() -> bool:
	return state == State.OPERATIONAL
