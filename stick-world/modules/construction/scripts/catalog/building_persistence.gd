extends Node
## 建造系统持久化 —— 建筑与建造项目的 SQLite 存档/读档。
##
## 职责：
## - 保存建筑（buildings 表）与未完工建造项目（construction_projects 表）
## - 从 DB 恢复建筑与项目（含 ID 计数器续算）
##
## 由 ConstructionManager._ready 挂载为 BuildingPersistence 子节点并调用 setup(root)，
## 建筑/项目注册表（_buildings / _projects）由 ConstructionManager 持有。

const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")

var _root: Node = null


func setup(root: Node) -> void:
	_root = root


# ─────────────────────────────── SQLite 存档 ────────────────────────────────
# 详见 docs/技术/架构/SQLite存档迁移方案.md §5.2

## 保存建筑和建造项目到 DB
func save_to_db(db, slot_id: int, map_id: String) -> void:
	# 建筑
	db.delete_rows("buildings", "slot_id = %d AND map_id = '%s'" % [slot_id, map_id])
	for b_id in _root._buildings.keys():
		var b: Node = _root._buildings[b_id]
		if not is_instance_valid(b) or not (b is ScriptBuilding):
			continue
		var typed: ScriptBuilding = b as ScriptBuilding
		db.insert_row("buildings", {
			"slot_id": slot_id, "building_id": b_id, "map_id": map_id,
			"def_id": typed.def_id, "cell_x": typed.cell_x,
			"width": typed.width, "state": typed.state,
			"health": typed.health, "max_health": typed.max_health,
			"is_terrain": 1 if typed.is_terrain else 0,
			"wall_tier": typed.wall_tier,
			"is_gate": 1 if typed.is_gate else 0,
			"region_id": str(typed.get_meta("region_id", "")),
		})
	# 建造项目（只存未完工的）
	db.delete_rows("construction_projects", "slot_id = %d AND map_id = '%s'" % [slot_id, map_id])
	for p_id in _root._projects.keys():
		var p: ScriptConstructionProject = _root._projects[p_id]
		if p.state == ScriptConstructionProject.State.OPERATIONAL:
			continue
		db.insert_row("construction_projects", {
			"slot_id": slot_id, "project_id": p_id, "map_id": map_id,
			"def_id": p.def_id, "cell_x": p.cell_x, "width": p.width,
			"state": p.state, "total_work": p.total_work,
			"current_work": p.current_work, "region_id": p.region_id,
			"material_progress": p.material_progress,
		})


## 从 DB 恢复建筑和建造项目
func load_from_db(db, slot_id: int, map_id: String) -> void:
	# 清空当前运行时状态
	_clear_all_buildings_and_projects()
	# 恢复建筑（用 spawn_operational_building 重建，再修正状态）
	var bld_rows: Array = db.select_rows("buildings",
		"slot_id = %d AND map_id = '%s'" % [slot_id, map_id], ["*"])
	for row in bld_rows:
		var def_id: String = str(row["def_id"])
		var cx: int = int(row["cell_x"])
		var w: int = int(row["width"])
		var result: Dictionary = _root.spawn_operational_building(def_id, cx, w)
		if result.get("ok", false):
			var new_id: String = result["building_id"]
			var b: Node = _root._buildings.get(new_id)
			if b is ScriptBuilding:
				var typed: ScriptBuilding = b as ScriptBuilding
				typed.health = float(row["health"])
				typed.set_state(int(row["state"]))
				typed.wall_tier = int(row["wall_tier"])
				typed.is_gate = bool(int(row["is_gate"]))
				typed.set_meta("region_id", str(row["region_id"]))
			# 替换为存档原始 building_id
			_root._buildings.erase(new_id)
			_root._buildings[str(row["building_id"])] = b
			if b != null:
				_root._building_to_id[b] = str(row["building_id"])
	# 恢复建造项目
	var proj_rows: Array = db.select_rows("construction_projects",
		"slot_id = %d AND map_id = '%s'" % [slot_id, map_id], ["*"])
	for row in proj_rows:
		_restore_project_from_row(row)
	# 更新 ID 计数器
	_root._next_building_id = _calc_next_id(_root._buildings.keys(), "bld_") + 1
	_root._next_project_id = _calc_next_id(_root._projects.keys(), "proj_") + 1


## 清空所有建筑和项目（读档前调用）
func _clear_all_buildings_and_projects() -> void:
	for b in _root._buildings.values():
		if is_instance_valid(b):
			b.queue_free()
	_root._buildings.clear()
	_root._building_to_id.clear()
	_root._projects.clear()
	# 阶段 E：清理进度条
	for indicator in _root._project_indicators.values():
		if is_instance_valid(indicator):
			(indicator as Node).queue_free()
	_root._project_indicators.clear()


## 从行数据恢复一个建造项目
func _restore_project_from_row(row: Dictionary) -> void:
	if _root._map == null:
		return
	var def_id: String = str(row["def_id"])
	if not _root._catalog.is_registered(def_id):
		return
	var scene: PackedScene = _root._catalog.get_scene(def_id)
	var total_work: float = float(row["total_work"])
	var project_id: String = str(row["project_id"])
	var project := ScriptConstructionProject.new(
		project_id, def_id, int(row["cell_x"]), int(row["width"]),
		_root._map, scene, total_work, str(row["region_id"]))
	project.current_work = float(row["current_work"])
	project.state = int(row["state"])
	# 阶段 E：材料进度按存档真实值恢复（旧档无此字段时兼容为已满，避免阻塞）
	project.material_progress = float(row.get("material_progress", 1.0))
	_root._projects[project_id] = project
	if not project.completed.is_connected(_root._on_project_completed):
		project.completed.connect(_root._on_project_completed)
	# 恢复工地障碍（读档后工地仍需阻挡通行）
	if project.state == ScriptConstructionProject.State.UNDER_CONSTRUCTION:
		project._create_barrier()
	# 恢复派工池注册（否则 NPC 找不到该项目不会来帮忙）
	if _root._assigner != null:
		_root._assigner.add_project(project)
	# 阶段 E：恢复进度条 + 监听进度
	_root._create_progress_indicator(project)
	if not project.progress_changed.is_connected(_root._on_project_progress):
		project.progress_changed.connect(_root._on_project_progress)


## 计算下一个 ID（避免恢复后冲突）
func _calc_next_id(ids: Array, prefix: String) -> int:
	var max_id: int = 0
	for id in ids:
		var s := str(id)
		if s.begins_with(prefix):
			var num_part: String = s.substr(prefix.length())
			var num: int = num_part.to_int()
			if num > max_id:
				max_id = num
	return max_id
