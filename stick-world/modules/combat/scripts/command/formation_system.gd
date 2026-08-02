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
## 小队对应的组织标签
const SQUAD_TAG := "MILITARY"
## 小队对应的组织层级（L1 = 最低层，排级）
const SQUAD_TIER := 1
## 小队成员默认角色
const SQUAD_DEFAULT_ROLE := "member"

# ─────────────────────────────── 信号 ────────────────────────────────
## 小队创建：squad_id + unit instance_id 数组
signal squad_created(squad_id: String, unit_ids: Array)
## 小队解散
signal squad_disbanded(squad_id: String)

# ─────────────────────────────── 状态 ────────────────────────────────
## OrganizationApi 引用（由 GameRoot 注入）
var _org_api: Node = null
## squad_id -> {"units": Array[Node], "leader": Node}
var _squads: Dictionary = {}
## unit.get_instance_id() -> squad_id（快速反查）
var _unit_to_squad: Dictionary = {}
## 小队名称自增计数
var _squad_counter: int = 0


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 由 GameRoot 装配时注入 OrganizationApi 引用
func setup(org_api: Node) -> void:
	_org_api = org_api


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
			var u: Node = units[i]
			if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
				_unit_to_squad.erase(u.get_instance_id())
				units.remove_at(i)
				changed = true
				if squad["leader"] == u:
					squad["leader"] = null
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
## 已在其他小队中的单位会先被移出。
func create_squad(units: Array, squad_name: String = "") -> String:
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
	# 已在其他小队的单位先移出
	for u in valid_units:
		_remove_unit_from_squad(u)
	# 创建 L1 MILITARY 组织
	_squad_counter += 1
	var name_str: String = squad_name if not squad_name.is_empty() else "squad_%d" % _squad_counter
	var result: Dictionary = _org_api.create_organization(name_str, SQUAD_TAG, SQUAD_TIER, "")
	if not result.get("ok", false):
		push_warning("[FormationSystem] 创建组织失败: %s" % result.get("error", ""))
		return ""
	var squad_id: String = result["data"]["org_id"]
	# 将单位分配到组织
	for u in valid_units:
		var sid: String = str(u.get_instance_id())
		_org_api.assign_stickman(squad_id, sid, SQUAD_DEFAULT_ROLE)
		_unit_to_squad[u.get_instance_id()] = squad_id
	# 本地追踪
	_squads[squad_id] = {"units": valid_units.duplicate(), "leader": null}
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
		_org_api.assign_stickman(squad_id, str(unit.get_instance_id()), SQUAD_DEFAULT_ROLE)
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
	# 同步到组织模块
	if _org_api != null and _org_api.has_method("remove_stickman"):
		_org_api.remove_stickman(squad_id, str(iid))
