class_name FormationSystem
extends Node
## 编队系统 -- 将选中的单位编为小队（squad），复用组织模块的 L1 节点。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2、§8.3。
##
## 流程：
##   1. selection_system 返回 unit_ids 数组
##   2. formation_system.create_squad(units) -> 返回 squad_id
##   3. formation_system.assign_leader(squad_id, leader_unit) 任命排长
##   4. tactical_orders.issue(order, squad_id, ...) 对小队下令
##
## 小队 = L1 MILITARY 组织节点（§8.3: "任命排长 = 创建 L1 组织节点"）。
## 本系统在组织模块之上封装小队级别的便捷 API，并维护 unit<->squad 双向映射。

# ─────────────────────────────── 常量 ────────────────────────────────
## 小队对应的组织层级（L1 = 最低层，排级）
const SQUAD_TIER := 1
## 默认预设（未指定时使用战斗班，保持旧行为兼容）
const DEFAULT_PRESET_ID := "fp_combat_squad"
## 预设配置文件路径
const PRESET_CONFIG_PATH := "res://config/formations/formation_presets.tres"

## 工作类型（RimWorld 式抽象职责，见 docs 设计 §二）
const WorkType := {
	COMBAT = "WORK_COMBAT",   ## 战斗/掩体/撤退/接号令
	BUILD = "WORK_BUILD",     ## 工地建造
	HAUL = "WORK_HAUL",       ## 搬运材料
	FORAGE = "WORK_FORAGE",   ## 采集劳作（预留）
}

# ─────────────────────────────── 信号 ────────────────────────────────
## 小队创建：squad_id + unit instance_id 数组
signal squad_created(squad_id: String, unit_ids: Array)
## 小队解散
signal squad_disbanded(squad_id: String)

# ─────────────────────────────── 状态 ────────────────────────────────
## OrganizationApi 引用（由 GameRoot 注入）
var _org_api: Node = null
## squad_id -> {"units": Array[Node], "leader": Node, "preset_id": String,
##              "work_types": Array[String], "role": String, "name": String}
var _squads: Dictionary = {}
## unit.get_instance_id() -> squad_id（快速反查）
var _unit_to_squad: Dictionary = {}
## 小队名称自增计数
var _squad_counter: int = 0
## 编制预设：preset_id -> {"id", "name", "tag", "work_types", "default_role"}
var _presets: Dictionary = {}
## 预设是否已加载
var _presets_loaded: bool = false


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 由 GameRoot 装配时注入 OrganizationApi 引用
func setup(org_api: Node) -> void:
	_org_api = org_api
	_load_presets()


## 从 config/formations/formation_presets.tres 加载编制预设。
## 加载失败时使用内置默认预设兜底，保证系统可用。
func _load_presets() -> void:
	if _presets_loaded:
		return
	_presets_loaded = true
	# 内置兜底：战斗班（与旧行为一致）
	_presets[DEFAULT_PRESET_ID] = {
		"id": DEFAULT_PRESET_ID,
		"name": "战斗班",
		"tag": "MILITARY",
		"work_types": [WorkType.COMBAT],
		"default_role": "fighter",
	}
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not "variables" in res:
		push_warning("[FormationSystem] 预设配置加载失败: %s，使用内置默认" % PRESET_CONFIG_PATH)
		return
	var data: Array = res.get("variables").get("data", [])
	for p in data:
		var pid: String = p.get("id", "")
		if pid.is_empty():
			continue
		_presets[pid] = {
			"id": pid,
			"name": p.get("name", pid),
			"tag": p.get("tag", "MILITARY"),
			"work_types": (p.get("work_types", [WorkType.COMBAT]) as Array).duplicate(),
			"default_role": p.get("default_role", "member"),
		}


func _process(_delta: float) -> void:
	if _squads.is_empty():
		return
	# 清理死亡/释放的单位，空小队自动解散
	var to_disband: Array = []
	for squad_id in _squads.keys():
		var squad: Dictionary = _squads[squad_id]
		var units: Array = squad["units"]
		var changed: bool = false
		var i: int = units.size() - 1
		while i >= 0:
			var u = units[i]
			# 防御：实例已释放（如跨图销毁）时无法读取 iid，整体解散兜底
			if not is_instance_valid(u):
				to_disband.append(squad_id)
				break
			if u.has_method("is_dead") and u.is_dead():
				_unit_to_squad.erase(u.get_instance_id())
				units.remove_at(i)
				changed = true
				if squad["leader"] == u:
					squad["leader"] = null
				# 清除编队派生角色（单位仍有效时）
				if u.has_method("set_role"):
					u.set_role("")
			i -= 1
		if units.is_empty():
			to_disband.append(squad_id)
		elif changed:
			# 同步到组织模块（移除已死单位）
			# 组织模块的 remove_stickman 已在 _remove_unit_from_squad 中调用
			pass
	for sid in to_disband:
		disband_squad(sid)


# ─────────────────────────────── 核心 API ────────────────────────────────

## 创建小队。units 为 StickmanEntity 节点数组。返回 squad_id（失败返回 ""）。
## preset_id 指定编制预设（如 fp_combat_squad / fp_builder_crew / fp_worker_crew），
## 决定组织标签、成员职责范围（work_types）与成员角色（role）。
## 已在其他小队中的单位会先被移出。
func create_squad(units: Array, squad_name: String = "", preset_id: String = DEFAULT_PRESET_ID) -> String:
	if _org_api == null:
		push_warning("[FormationSystem] organization_api 未注入")
		return ""
	# 过滤有效单位（存活）
	var valid_units: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		valid_units.append(u)
	if valid_units.is_empty():
		push_warning("[FormationSystem] 无有效单位，无法创建小队")
		return ""
	# 解析预设
	var preset: Dictionary = _resolve_preset(preset_id)
	# 已在其他小队的单位先移出
	for u in valid_units:
		_remove_unit_from_squad(u)
	# 创建 L1 组织（标签来自预设）
	_squad_counter += 1
	var name_str: String = squad_name if not squad_name.is_empty() else "squad_%d" % _squad_counter
	var result: Dictionary = _org_api.create_organization(name_str, preset["tag"], SQUAD_TIER, "")
	if not result.get("ok", false):
		push_warning("[FormationSystem] 创建组织失败: %s" % result.get("error", ""))
		return ""
	var squad_id: String = result["data"]["org_id"]
	# 将单位分配到组织，写入角色
	var work_types: Array = (preset["work_types"] as Array).duplicate()
	for u in valid_units:
		var sid: String = str(u.get_instance_id())
		_org_api.assign_stickman(squad_id, sid, preset["default_role"])
		if u.has_method("set_role"):
			u.set_role(preset["default_role"])
		_unit_to_squad[u.get_instance_id()] = squad_id
	# 本地追踪
	_squads[squad_id] = {
		"units": valid_units.duplicate(),
		"leader": null,
		"preset_id": preset["id"],
		"work_types": work_types,
		"role": preset["default_role"],
		"name": name_str,
		"follow_player": false,
	}
	# 发射信号
	var unit_ids: Array = []
	for u in valid_units:
		unit_ids.append(u.get_instance_id())
	squad_created.emit(squad_id, unit_ids)
	if EventBus != null and EventBus.has_signal("squad_created"):
		EventBus.squad_created.emit(squad_id, unit_ids)
	return squad_id


## 解散小队。
func disband_squad(squad_id: String) -> void:
	if not _squads.has(squad_id):
		return
	var squad: Dictionary = _squads[squad_id]
	# 清除单位映射
	for u in squad["units"]:
		if is_instance_valid(u):
			_unit_to_squad.erase(u.get_instance_id())
	# 解散组织
	if _org_api != null and _org_api.has_method("disband_organization"):
		_org_api.disband_organization(squad_id)
	# 移除本地追踪
	_squads.erase(squad_id)
	squad_disbanded.emit(squad_id)


## 解散全部小队并清空本地状态（跨图携带前调用：快照导出后调用，
## 避免旧图实体 freed 后残留引用导致 _process 报错）。
func disband_all_squads() -> void:
	for squad_id in _squads.keys():
		var squad: Dictionary = _squads[squad_id]
		for u in squad["units"]:
			if is_instance_valid(u):
				_unit_to_squad.erase(u.get_instance_id())
				if u.has_method("set_role"):
					u.set_role("")
		if _org_api != null and _org_api.has_method("disband_organization"):
			_org_api.disband_organization(squad_id)
		squad_disbanded.emit(squad_id)
	_squads.clear()
	_unit_to_squad.clear()


## 任命小队长（排长）。返回是否成功。
func assign_leader(squad_id: String, leader: Node) -> bool:
	if not _squads.has(squad_id):
		push_warning("[FormationSystem] 小队不存在: %s" % squad_id)
		return false
	if not is_instance_valid(leader):
		return false
	# 必须是小队成员
	if leader not in _squads[squad_id]["units"]:
		push_warning("[FormationSystem] 任命失败：单位不在该小队中")
		return false
	# 设置组织指挥官
	if _org_api != null and _org_api.has_method("assign_commander"):
		_org_api.assign_commander(squad_id, str(leader.get_instance_id()))
	_squads[squad_id]["leader"] = leader
	if EventBus != null and EventBus.has_signal("commander_assigned"):
		EventBus.commander_assigned.emit(squad_id, leader.get_instance_id())
	return true


## 将单位加入已有小队。
func add_unit(squad_id: String, unit: Node) -> bool:
	if not _squads.has(squad_id):
		return false
	if not is_instance_valid(unit):
		return false
	if unit.has_method("is_dead") and unit.is_dead():
		return false
	# 先从当前小队移出
	_remove_unit_from_squad(unit)
	# 加入组织
	if _org_api != null and _org_api.has_method("assign_stickman"):
		_org_api.assign_stickman(squad_id, str(unit.get_instance_id()), _squads[squad_id]["role"])
	if unit.has_method("set_role"):
		unit.set_role(_squads[squad_id]["role"])
	_squads[squad_id]["units"].append(unit)
	_unit_to_squad[unit.get_instance_id()] = squad_id
	return true


## 将单位从小队移除。
func remove_unit(unit: Node) -> void:
	_remove_unit_from_squad(unit)


# ─────────────────────────────── 查询 API ────────────────────────────────

func get_squad_units(squad_id: String) -> Array:
	if not _squads.has(squad_id):
		return []
	return (_squads[squad_id]["units"] as Array).duplicate()


func get_squad_leader(squad_id: String) -> Node:
	if not _squads.has(squad_id):
		return null
	return _squads[squad_id]["leader"]


func get_unit_squad(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	return _unit_to_squad.get(unit.get_instance_id(), "")


func get_all_squads() -> Array:
	return _squads.keys()


func get_squad_count() -> int:
	return _squads.size()


func is_in_squad(unit: Node) -> bool:
	return get_unit_squad(unit) != ""


func get_squad_size(squad_id: String) -> int:
	if not _squads.has(squad_id):
		return 0
	return _squads[squad_id]["units"].size()


# ─────────────────────────────── 内部 ────────────────────────────────

## 将单位从其当前小队中移除（如有）
func _remove_unit_from_squad(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	var squad_id: String = _unit_to_squad.get(iid, "")
	if squad_id == "":
		return
	if not _squads.has(squad_id):
		_unit_to_squad.erase(iid)
		return
	var squad: Dictionary = _squads[squad_id]
	(squad["units"] as Array).erase(unit)
	_unit_to_squad.erase(iid)
	if squad["leader"] == unit:
		squad["leader"] = null
	# 清除编队派生角色
	if unit.has_method("set_role"):
		unit.set_role("")
	# 同步到组织模块
	if _org_api != null and _org_api.has_method("remove_stickman"):
		_org_api.remove_stickman(squad_id, str(iid))


# ─────────────────────────────── 预设 API ────────────────────────────────

## 获取全部编制预设列表（用于 UI 下拉）。返回 Array[Dictionary]。
func get_all_presets() -> Array:
	_load_presets()
	var result: Array = []
	for pid in _presets.keys():
		result.append(_presets[pid].duplicate(true))
	return result


## 按 id 获取编制预设（不存在返回空 Dictionary）。
func get_preset(preset_id: String) -> Dictionary:
	_load_presets()
	return _presets.get(preset_id, {})


## 解析预设：不存在或字段缺失时回退内置战斗班。
func _resolve_preset(preset_id: String) -> Dictionary:
	_load_presets()
	var p: Dictionary = _presets.get(preset_id, {})
	if p.is_empty():
		p = _presets[DEFAULT_PRESET_ID]
	return p


# ─────────────────────────────── 职责 API ────────────────────────────────

## 获取小队使用的预设 id。
func get_squad_preset(squad_id: String) -> String:
	if not _squads.has(squad_id):
		return ""
	return _squads[squad_id]["preset_id"]


## 获取小队当前职责范围（工作类型数组）。
func get_squad_work_types(squad_id: String) -> Array:
	if not _squads.has(squad_id):
		return []
	return (_squads[squad_id]["work_types"] as Array).duplicate()


## 调整小队职责范围（工作类型数组，如 ["WORK_COMBAT", "WORK_HAUL"]）。
## 职责可自由调整；组织标签不随调整迁移（P0 简化，阶段 1 并入组织系统）。
## 返回是否成功。
func set_squad_work_types(squad_id: String, work_types: Array) -> bool:
	if not _squads.has(squad_id):
		return false
	_squads[squad_id]["work_types"] = work_types.duplicate()
	return true


## 判断单位是否允许执行某工作类型。
## 未编队单位视为全能（允许一切）；编队单位受队伍职责范围限制。
func is_work_allowed(unit: Node, work_type: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return true
	var squad_id: String = _unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id == "" or not _squads.has(squad_id):
		return true
	return work_type in _squads[squad_id]["work_types"]


## 小队是否允许战斗类职责（供号令可用性过滤）。
func is_combat_squad(squad_id: String) -> bool:
	if not _squads.has(squad_id):
		return false
	return WorkType.COMBAT in _squads[squad_id]["work_types"]


## 设置小队"跟随玩家"模式：开启后成员自动跟随玩家移动（跟到战场）。
## 由编制窗口勾选触发，BehaviorFollow 行为执行。
func set_squad_follow(squad_id: String, follow: bool) -> bool:
	if not _squads.has(squad_id):
		return false
	_squads[squad_id]["follow_player"] = follow
	return true


## 小队是否处于跟随玩家模式。
func is_squad_following(squad_id: String) -> bool:
	if not _squads.has(squad_id):
		return false
	return _squads[squad_id].get("follow_player", false)


## 单位所在小队是否跟随玩家（供 AI 决策查询）。
func is_unit_squad_following(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var squad_id: String = _unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id == "" or not _squads.has(squad_id):
		return false
	return _squads[squad_id].get("follow_player", false)


## 获取小队名称。
func get_squad_name(squad_id: String) -> String:
	if not _squads.has(squad_id):
		return ""
	return _squads[squad_id]["name"]


# ─────────────────────────────── 跨图携带（快照/恢复）────────────────────────────────

## 导出全部编队快照（跨图携带用，travel 前由 GameRoot 收集）。
## 返回 Array[Dictionary]：{"name", "preset_id", "work_types", "leader_iid",
##                           "members": [{"iid", "role"}]}
func export_squads() -> Array:
	var result: Array = []
	for squad_id in _squads.keys():
		var s: Dictionary = _squads[squad_id]
		var members: Array = []
		for u in s["units"]:
			if is_instance_valid(u):
				members.append({
					"iid": u.get_instance_id(),
					"role": u.get_role() if u.has_method("get_role") else "",
				})
		var leader_iid: int = 0
		if s["leader"] != null and is_instance_valid(s["leader"]):
			leader_iid = s["leader"].get_instance_id()
		result.append({
			"name": s["name"],
			"preset_id": s["preset_id"],
			"work_types": (s["work_types"] as Array).duplicate(),
			"leader_iid": leader_iid,
			"members": members,
		})
	return result


## 按快照重建编队（跨图携带恢复，map_loaded 后由 GameRoot 调用）。
## entity_map: 旧 instance_id(int) -> 新实体(Node)。
## 返回成功恢复的小队数。
func restore_squads(snapshots: Array, entity_map: Dictionary) -> int:
	var restored: int = 0
	for snap in snapshots:
		var members: Array = []
		for m in snap.get("members", []):
			var e: Node = entity_map.get(int(m.get("iid", 0)))
			if e != null and is_instance_valid(e):
				members.append(e)
		if members.is_empty():
			continue
		var squad_id: String = create_squad(
			members, snap.get("name", ""), snap.get("preset_id", DEFAULT_PRESET_ID)
		)
		if squad_id.is_empty():
			continue
		# 恢复自定义职责范围
		var work_types: Array = snap.get("work_types", [])
		if not work_types.is_empty():
			set_squad_work_types(squad_id, work_types)
		# 恢复排长
		var leader_iid: int = int(snap.get("leader_iid", 0))
		if leader_iid != 0 and entity_map.has(leader_iid):
			var leader: Node = entity_map[leader_iid]
			if is_instance_valid(leader) and leader in members:
				assign_leader(squad_id, leader)
		restored += 1
	return restored
