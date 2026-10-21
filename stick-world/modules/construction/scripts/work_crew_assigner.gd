class_name WorkCrewAssigner
extends RefCounted
## 派工 Job 板 —— §15 阶段 0.4 起役，Job 板化（搬运/建造两族统一分发）。
##
## 任务板模式（参考监狱建造师/环世界 Job 系统，取其"任务分发与执行解耦、
## 工人按池认领"的形态，不照抄实现）：板上不维护独立的任务对象列表，
## 任务是**项目状态的派生视图**——每个活跃项目在板上同时提供两类任务：
##   - build（建造）：项目接受工人期间常驻可领；
##   - haul（搬运）：项目 needs_material() 期间随需可领。
## 工人认领时按（距离 → 挂板序）挑项目，再按项目状态与认领提示词定族；
## 认领结果 = 挂在工人名下的一条 Job 记录（{kind, project}），行为层
## （BehaviorWork / BehaviorHaul）只消费记录里的 project 执行，不再自决族别。
##
## 决策/执行解耦边界：
##   - 本板负责"谁去哪个项目做什么族"（决策）；
##   - AIController 只持提示词来认领 + 按 kind 转发对应行为（调度）；
##   - 行为层只执行（建造敲击 / 仓库往返），族别换向经 refresh_job 回板重派。
##
## 职责：
##   1. 维护可派工工人池（register_worker / unregister_worker）
##   2. 维护活跃项目列表（add_project / remove_project）
##   3. 自动认领：try_assign(worker, hint) 挑最近项目并定族
##   4. 持有中任务的族别刷新：refresh_job(worker, hint)（材料到货/耗尽换向）
##   5. 主动派工：assign_to(worker, project)（固定 build 族）
##   6. 解除派工：unassign(worker)
##   7. 监听项目完工/取消信号，自动释放工人回空闲池
##
## 认领提示词 hint（工人能力的板外事实，调用方告知；缺省 = 两族皆可）：
##   { "can_build": bool, "can_haul": bool, "has_warehouse": bool }
## 板不查编队职责/仓库存在性（那是 units 侧的事实）——定族规则：
##   haul 可领 = project.needs_material() 且 can_haul 且 has_warehouse；
##   build 可领 = can_build（与项目是否缺料无关，缺料时建到材料上限即站桩，
##   与既有行为一致）。
##
## 不直接驱动工人移动；BehaviorWork/BehaviorHaul 经 get_worker_job(worker)
## 的下游转发查询任务目标。
##
## 由 ConstructionManager 持有（一个 Manager 对应一个 Assigner）。

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

## 放置度量常量库（模块内单一真相源：派工距离的项目中心 x 与 manager 的
## get_nearest_project 快照缓存同公式，换轨只动 placement_metrics）
const ScriptPlacementMetrics := preload("res://modules/construction/scripts/placement/placement_metrics.gd")

## 占地条带宽（px）：自 placement_metrics（锚定 PlacementGrid.CELL_SIZE）
const CELL_PX: float = ScriptPlacementMetrics.CELL_PX

# ─────────────────────────────── 任务族 ────────────────────────────────

## 建造族（行为层映射为 behavior "work"）
const JOB_BUILD: String = "build"
## 搬运族（行为层映射为 behavior "haul"）
const JOB_HAUL: String = "haul"

# ─────────────────────────────── 字段 ────────────────────────────────

## 可派工工人池（StickmanEntity[]，未派工或刚释放）
var _available_workers: Array = []
## 工人 → 当前持有的 Job 记录 {kind: String, project: ScriptConstructionProject}
##（两类族都绑定到项目：搬运工也是项目成员，完工/取消释放路径与建造工同源）
var _worker_to_job: Dictionary = {}
## 活跃项目列表（PLANNED 或 UNDER_CONSTRUCTION；挂板序 = 本列表序）
var _projects: Array = []

# ─────────────────────────────── 信号 ────────────────────────────────

## 工人被派工到项目（认领 build/haul 任一族都发射；族内换向不发射）
signal worker_assigned(worker: Node, project: ScriptConstructionProject)
## 工人被解除派工
signal worker_unassigned(worker: Node, project: ScriptConstructionProject)


# ─────────────────────────────── 工人管理 ────────────────────────────────

## 注册一名可派工工人（加入空闲池）
func register_worker(worker: Node) -> void:
	if worker == null:
		return
	if _worker_to_job.has(worker):
		return  # 已在派工中
	if _available_workers.has(worker):
		return
	_available_workers.append(worker)


## 取消注册（工人退出/死亡/离开场景）。同时解除其派工。
func unregister_worker(worker: Node) -> void:
	_available_workers.erase(worker)
	if _worker_to_job.has(worker):
		var p: ScriptConstructionProject = _worker_to_job[worker].get("project")
		p.unassign_worker(worker)
		_worker_to_job.erase(worker)
		worker_unassigned.emit(worker, p)


## 当前空闲工人数
func get_available_count() -> int:
	return _available_workers.size()


## 空闲工人名单（拷贝；招兵/人口统计消费——过滤已变身单位由调用方按 meta 做）
func get_available_workers() -> Array:
	return _available_workers.duplicate()


## 工人是否在派工中
func is_assigned(worker: Node) -> bool:
	return _worker_to_job.has(worker)


# ─────────────────────────────── 项目管理 ────────────────────────────────

## 添加一个活跃项目（自动监听其完工/取消信号）
func add_project(project: ScriptConstructionProject) -> void:
	if project == null:
		return
	if _projects.has(project):
		return
	_projects.append(project)
	if not project.completed.is_connected(_on_project_completed):
		project.completed.connect(_on_project_completed)
	if not project.cancelled.is_connected(_on_project_cancelled):
		project.cancelled.connect(_on_project_cancelled)


## 移除项目（不触发完工/取消信号）
func remove_project(project: ScriptConstructionProject) -> void:
	_projects.erase(project)
	if project.completed.is_connected(_on_project_completed):
		project.completed.disconnect(_on_project_completed)
	if project.cancelled.is_connected(_on_project_cancelled):
		project.cancelled.disconnect(_on_project_cancelled)


## 当前活跃项目数
func get_project_count() -> int:
	return _projects.size()


# ─────────────────────────────── 认领与派工 ────────────────────────────────

## 自动认领：为空闲工人挑最近的可领项目并定族（ROOT-9 距离优先，
## 平距回退挂板序 = 既有插入序语义）。成功返回 true。
## hint 见类头注释，缺省 = 两族皆可。
func try_assign(worker: Node, hint: Dictionary = {}) -> bool:
	if worker == null:
		return false
	if _worker_to_job.has(worker):
		return true  # 已持任务，幂等成功
	var candidate: ScriptConstructionProject = _pick_project(worker, hint)
	if candidate == null:
		return false
	_claim(worker, candidate, hint)
	return true


## 主动派工：把工人派到指定项目（族别按缺省提示词随项目状态派生，
## 与自动认领同源；缺料即 haul、否则 build，后续可经 refresh_job 换向）。
func assign_to(worker: Node, project: ScriptConstructionProject) -> bool:
	if worker == null or project == null:
		return false
	if not project.is_accepting_workers():
		return false
	# 如果工人已有派工，先解除
	if _worker_to_job.has(worker):
		unassign(worker)
	_claim(worker, project, {})
	return true


## 解除工人派工（工人回到空闲池）
func unassign(worker: Node) -> void:
	if worker == null:
		return
	if not _worker_to_job.has(worker):
		return
	var p: ScriptConstructionProject = _worker_to_job[worker].get("project")
	p.unassign_worker(worker)
	_worker_to_job.erase(worker)
	# 回到空闲池
	if not _available_workers.has(worker):
		_available_workers.append(worker)
	worker_unassigned.emit(worker, p)


## 持有任务的族别刷新（材料到货/耗尽在 build ↔ haul 间换向）。
## 换向在原项目内原地换 kind，不发射信号、不动池（工人仍是该项目成员）；
## 返回刷新后的任务视图（{kind, project}；无可领族/未持任务返回 {}）。
## 内部持有关系只在完工/取消/unassign 时释放——本方法不释放。
func refresh_job(worker: Node, hint: Dictionary = {}) -> Dictionary:
	if not _worker_to_job.has(worker):
		return {}
	var job: Dictionary = _worker_to_job[worker]
	var project: ScriptConstructionProject = job.get("project")
	if project == null or not is_instance_valid(project):
		return {}
	var family: String = _family_for(project, hint)
	if family.is_empty():
		return {}
	job["kind"] = family
	return _job_view(job)


# ─────────────────────────────── 查询 ────────────────────────────────

## 工人当前持有的任务（拷贝视图 {kind, project}；未派工返回 {}）
func get_worker_job(worker: Node) -> Dictionary:
	if not _worker_to_job.has(worker):
		return {}
	return _job_view(_worker_to_job[worker])


## 获取工人当前派工的项目（无返回 null；两族都绑定项目，消费面不变）
func get_worker_project(worker: Node) -> ScriptConstructionProject:
	if not _worker_to_job.has(worker):
		return null
	return _worker_to_job[worker].get("project") as ScriptConstructionProject


## 获取项目的派工工人列表（拷贝）
func get_project_workers(project: ScriptConstructionProject) -> Array:
	return project.get_assigned_workers() if project != null else []


# ─────────────────────────────── 内部 ────────────────────────────────

## 认领动作：登记 Job 记录 + 项目成员化（首名工人自动开工）+ 出池 + 发射信号。
## build/haul 两族都走 project.assign_worker——搬运工也是项目成员，
## 完工/取消释放、工位分配与建造工同源（与 Job 板化前的成员语义一致）。
func _claim(worker: Node, project: ScriptConstructionProject, hint: Dictionary) -> void:
	if not project.assign_worker(worker):
		return
	var family: String = _family_for(project, hint)
	if family.is_empty():
		family = JOB_BUILD  # assign_worker 已成功但提示词两族皆否（直调面）：记 build 保底
	_worker_to_job[worker] = {"kind": family, "project": project}
	_available_workers.erase(worker)
	worker_assigned.emit(worker, project)


## 挑可领项目：候选 = 接受工人的项目中有可领族者，按（距离、挂板序）取最优。
## 工人无位置信息（测试裸 Node 桩）时距离恒 INF，等效挂板序（旧插入序语义）。
func _pick_project(worker: Node, hint: Dictionary) -> ScriptConstructionProject:
	var best: ScriptConstructionProject = null
	var best_dist: float = INF
	var worker_x: float = _worker_x(worker)
	for seq in _projects.size():
		var project: ScriptConstructionProject = _projects[seq] as ScriptConstructionProject
		if project == null:
			continue
		if not project.is_accepting_workers():
			continue
		if _family_for(project, hint).is_empty():
			continue  # 该项目对本次提示词无可领族
		# 距离 = 工人 x 到项目中心 x 的条带距离（与 manager.get_nearest_project
		# 的快照缓存同公式：卷轴地图纵深不参与派工度量）；无位置 → INF
		var dist: float = INF
		if not is_nan(worker_x):
			dist = absf((float(project.cell_x) + float(project.width) * 0.5) * CELL_PX - worker_x)
		# 严格小于才换人：平距保留先挂板者（挂板序 = 既有插入序 tie-break）
		if best == null or dist < best_dist:
			best = project
			best_dist = dist
	return best


## 项目当前对提示词的可领族：缺料且搬运链可用 → haul；否则可建造 → build。
## 都不可领返回 ""。
func _family_for(project: ScriptConstructionProject, hint: Dictionary) -> String:
	var can_build: bool = bool(hint.get("can_build", true))
	var can_haul: bool = bool(hint.get("can_haul", true))
	var has_warehouse: bool = bool(hint.get("has_warehouse", true))
	if project.needs_material() and can_haul and has_warehouse:
		return JOB_HAUL
	if can_build:
		return JOB_BUILD
	return ""


## 工人 x 坐标（Node2D 系；无该属性返回 NAN → 距离排序退化为挂板序）
func _worker_x(worker: Node) -> float:
	if worker is Node2D:
		return (worker as Node2D).global_position.x
	return NAN


## Job 记录的对外视图（浅拷贝，防外部改内部 kind）
func _job_view(job: Dictionary) -> Dictionary:
	return {"kind": String(job.get("kind", JOB_BUILD)), "project": job.get("project")}


func _on_project_completed(project: ScriptConstructionProject, _building: Node) -> void:
	# 完工：解除派工（调用 unassign_worker 同步工人状态）+ 释放工人
	_release_project_workers(project, true)


func _on_project_cancelled(project: ScriptConstructionProject) -> void:
	# 取消：与完工类似，仅释放工人（项目已取消，无需 unassign 同步）
	_release_project_workers(project, false)


## 解除项目全部派工：释放工人回池 + 发射 worker_unassigned + 移除项目。
## unassign: 是否调用 project.unassign_worker（完工时 true，取消时 false）
func _release_project_workers(project: ScriptConstructionProject, do_unassign: bool) -> void:
	var snapshot: Array = []
	for w in _worker_to_job.keys():
		if _worker_to_job[w].get("project") == project:
			snapshot.append(w)
	for w in snapshot:
		var worker: Node = w as Node
		if do_unassign:
			project.unassign_worker(worker)
		_worker_to_job.erase(worker)
		if not _available_workers.has(worker):
			_available_workers.append(worker)
		worker_unassigned.emit(worker, project)
	remove_project(project)
