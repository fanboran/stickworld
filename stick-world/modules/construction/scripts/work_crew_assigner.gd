class_name WorkCrewAssigner
extends RefCounted
## 派工系统 —— §15 阶段 0.4。
##
## 负责把"空闲工人"分配到"接受工人的项目"。
##
## 职责：
##   1. 维护可派工工人池（register_worker / unregister_worker）
##   2. 维护活跃项目列表（add_project / remove_project）
##   3. 自动派工：try_assign(worker) 找一个匹配项目
##   4. 主动派工：assign_to(worker, project)
##   5. 解除派工：unassign(worker)
##   6. 监听项目完工信号，自动释放工人回空闲池
##
## 不直接驱动工人移动；BehaviorWork 通过 get_worker_project(worker) 查询派工目标。
##
## 由 ConstructionManager 持有（一个 Manager 对应一个 Assigner）。

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

# ─────────────────────────────── 字段 ────────────────────────────────

## 可派工工人池（StickmanEntity[]，未派工或刚释放）
var _available_workers: Array = []
## 工人 → 当前派工的项目映射
var _worker_to_project: Dictionary = {}
## 活跃项目列表（PLANNED 或 UNDER_CONSTRUCTION）
var _projects: Array = []

# ─────────────────────────────── 信号 ────────────────────────────────

## 工人被派工到项目
signal worker_assigned(worker: Node, project: ScriptConstructionProject)
## 工人被解除派工
signal worker_unassigned(worker: Node, project: ScriptConstructionProject)


# ─────────────────────────────── 工人管理 ────────────────────────────────

## 注册一名可派工工人（加入空闲池）
func register_worker(worker: Node) -> void:
	if worker == null:
		return
	if _worker_to_project.has(worker):
		return  # 已在派工中
	if _available_workers.has(worker):
		return
	_available_workers.append(worker)


## 取消注册（工人退出/死亡/离开场景）。同时解除其派工。
func unregister_worker(worker: Node) -> void:
	_available_workers.erase(worker)
	if _worker_to_project.has(worker):
		var p: ScriptConstructionProject = _worker_to_project[worker]
		p.unassign_worker(worker)
		_worker_to_project.erase(worker)
		worker_unassigned.emit(worker, p)


## 当前空闲工人数
func get_available_count() -> int:
	return _available_workers.size()


## 工人是否在派工中
func is_assigned(worker: Node) -> bool:
	return _worker_to_project.has(worker)


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


# ─────────────────────────────── 派工 ────────────────────────────────

## 自动派工：为指定工人找一个匹配项目（按列表顺序，先到先服务）。
## 成功返回 true。
func try_assign(worker: Node) -> bool:
	if worker == null:
		return false
	if _worker_to_project.has(worker):
		return true  # 已派工
	for p in _projects:
		var project: ScriptConstructionProject = p as ScriptConstructionProject
		if project == null:
			continue
		if not project.is_accepting_workers():
			continue
		_assign(worker, project)
		return true
	return false


## 主动派工：把工人派到指定项目。
func assign_to(worker: Node, project: ScriptConstructionProject) -> bool:
	if worker == null or project == null:
		return false
	if not project.is_accepting_workers():
		return false
	# 如果工人已有派工，先解除
	if _worker_to_project.has(worker):
		unassign(worker)
	_assign(worker, project)
	return true


## 解除工人派工（工人回到空闲池）
func unassign(worker: Node) -> void:
	if worker == null:
		return
	if not _worker_to_project.has(worker):
		return
	var p: ScriptConstructionProject = _worker_to_project[worker] as ScriptConstructionProject
	p.unassign_worker(worker)
	_worker_to_project.erase(worker)
	# 回到空闲池
	if not _available_workers.has(worker):
		_available_workers.append(worker)
	worker_unassigned.emit(worker, p)


# ─────────────────────────────── 查询 ────────────────────────────────

## 获取工人当前派工的项目（无返回 null）
func get_worker_project(worker: Node) -> ScriptConstructionProject:
	if not _worker_to_project.has(worker):
		return null
	return _worker_to_project[worker] as ScriptConstructionProject


## 获取项目的派工工人列表（拷贝）
func get_project_workers(project: ScriptConstructionProject) -> Array:
	return project.get_assigned_workers() if project != null else []


# ─────────────────────────────── 内部 ────────────────────────────────

func _assign(worker: Node, project: ScriptConstructionProject) -> void:
	if not project.assign_worker(worker):
		return
	_worker_to_project[worker] = project
	_available_workers.erase(worker)
	worker_assigned.emit(worker, project)


func _on_project_completed(project: ScriptConstructionProject, _building: Node) -> void:
	# 解除所有派工到这个项目的工人
	var snapshot: Array = []
	for w in _worker_to_project.keys():
		if _worker_to_project[w] == project:
			snapshot.append(w)
	for w in snapshot:
		var worker: Node = w as Node
		project.unassign_worker(worker)
		_worker_to_project.erase(worker)
		if not _available_workers.has(worker):
			_available_workers.append(worker)
		worker_unassigned.emit(worker, project)
	remove_project(project)


func _on_project_cancelled(project: ScriptConstructionProject) -> void:
	# 取消与完工处理类似：解除派工，释放工人
	var snapshot: Array = []
	for w in _worker_to_project.keys():
		if _worker_to_project[w] == project:
			snapshot.append(w)
	for w in snapshot:
		var worker: Node = w as Node
		_worker_to_project.erase(worker)
		if not _available_workers.has(worker):
			_available_workers.append(worker)
		worker_unassigned.emit(worker, project)
	remove_project(project)
