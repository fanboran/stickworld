class_name OrgSlotBoard
extends RefCounted
## 组织槽位板 —— 组织的组成方式（01-组织系统 §2.4，纯机制零数值）。
##
## 组织 = 功能槽位的集合：每个槽位承担一项职能，槽位集合决定组织能做什么；
## 每个槽位至少由一名人员激活（空槽 = 该职能不运转）；槽位也可以放一个机构
## （组织嵌套组织——把运输处整个塞进集团的"物流槽"，运输处以组织形态运转
## 该职能）。组织的强弱来自"哪些槽位被什么激活"，不看面板数字。
##
## 职能名是自由字符串（不设预设职能枚举——职能清单属内容，01 §2.4 仅给示例
## 指挥/传令/参谋/后勤/征兵）；机构激活构成组织嵌套边，嵌套成环 = 病态结构，
## 指派时校验拒绝（A 的槽放 B、B 的槽再放 A 不合法）。

signal slot_activated(org_id: String, function_name: String)
signal slot_deactivated(org_id: String, function_name: String)

## {org_id: {function_name: {"persons": [holder_id...], "institution": org_id}}}
var _orgs: Dictionary = {}


# ─────────────────────────── 槽位增删 ────────────────────────────

## 给组织开一个职能槽位（组织能做什么由槽位集合决定——开槽=定职能）。
func add_slot(org_id: String, function_name: String) -> Dictionary:
	if org_id.is_empty() or function_name.is_empty():
		return {"ok": false, "error": "组织 id 与职能名不能为空"}
	if not _orgs.has(org_id):
		_orgs[org_id] = {}
	var slots: Dictionary = _orgs[org_id]
	if slots.has(function_name):
		return {"ok": false, "error": "该职能槽位已存在: %s（%s）" % [function_name, org_id]}
	slots[function_name] = {"persons": [], "institution": ""}
	return {"ok": true}


## 拆除一个职能槽位（槽位连同其激活关系整体移除）。
func remove_slot(org_id: String, function_name: String) -> Dictionary:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "槽位不存在: %s（%s）" % [function_name, org_id]}
	var was_active := _is_active(slot)
	_orgs[org_id].erase(function_name)
	if _orgs[org_id].is_empty():
		_orgs.erase(org_id)
	if was_active:
		slot_deactivated.emit(org_id, function_name)
	return {"ok": true}


# ─────────────────────────── 人员激活 ────────────────────────────

## 派一名人员入槽（一个槽可多名人员；重复派同一人拒绝）。
func assign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "槽位不存在: %s（%s）" % [function_name, org_id]}
	if holder_id.is_empty():
		return {"ok": false, "error": "人员 id 不能为空"}
	var persons: Array = slot["persons"]
	if persons.has(holder_id):
		return {"ok": false, "error": "该人员已在槽: %s（%s）" % [holder_id, function_name]}
	var was_active := _is_active(slot)
	persons.append(holder_id)
	if not was_active:
		slot_activated.emit(org_id, function_name)
	return {"ok": true}


func unassign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "槽位不存在: %s（%s）" % [function_name, org_id]}
	var persons: Array = slot["persons"]
	if not persons.has(holder_id):
		return {"ok": false, "error": "该人员不在槽: %s（%s）" % [holder_id, function_name]}
	var was_active := _is_active(slot)
	persons.erase(holder_id)
	if was_active and not _is_active(slot):
		slot_deactivated.emit(org_id, function_name)
	return {"ok": true}


# ─────────────────────────── 机构激活（组织嵌套） ────────────────────────────

## 把一个机构整个塞进槽位（机构以组织形态运转该职能；一个槽位至多一个机构）。
## 嵌套边 = "org 的该职能由 institution 承担"；指派后嵌套成环则拒绝。
func assign_institution(org_id: String, function_name: String,
		institution_org_id: String) -> Dictionary:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "槽位不存在: %s（%s）" % [function_name, org_id]}
	if institution_org_id.is_empty():
		return {"ok": false, "error": "机构 id 不能为空"}
	if institution_org_id == org_id:
		return {"ok": false, "error": "机构不能塞进自己的槽位"}
	if not String(slot["institution"]).is_empty():
		return {"ok": false, "error": "该槽位已有机构: %s（%s）" % [function_name, org_id]}
	if _institution_creates_cycle(org_id, institution_org_id):
		return {"ok": false, "error": "机构嵌套成环: %s ← %s" % [org_id, institution_org_id]}
	var was_active := _is_active(slot)
	slot["institution"] = institution_org_id
	if not was_active:
		slot_activated.emit(org_id, function_name)
	return {"ok": true}


func unassign_institution(org_id: String, function_name: String) -> Dictionary:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "槽位不存在: %s（%s）" % [function_name, org_id]}
	if String(slot["institution"]).is_empty():
		return {"ok": false, "error": "该槽位无机构: %s（%s）" % [function_name, org_id]}
	var was_active := _is_active(slot)
	slot["institution"] = ""
	if was_active and not _is_active(slot):
		slot_deactivated.emit(org_id, function_name)
	return {"ok": true}


# ─────────────────────────── 查询 ────────────────────────────

## 槽位是否运转（至少一名人员激活，或塞了机构）。
func is_slot_active(org_id: String, function_name: String) -> bool:
	var slot: Dictionary = _slot(org_id, function_name)
	if slot.is_empty():
		return false
	return _is_active(slot)


## 组织当前在运转的职能清单。
func active_functions(org_id: String) -> Array:
	var out: Array = []
	for function_name: String in _orgs.get(org_id, {}):
		if is_slot_active(org_id, function_name):
			out.append(function_name)
	return out


## 组织的槽位全貌（[{function, persons, institution, active}]——结构与人，即评估依据）。
func get_slots(org_id: String) -> Array:
	var out: Array = []
	for function_name: String in _orgs.get(org_id, {}):
		var slot: Dictionary = _orgs[org_id][function_name]
		out.append({
			"function": function_name,
			"persons": (slot["persons"] as Array).duplicate(),
			"institution": String(slot["institution"]),
			"active": _is_active(slot),
		})
	return out


# ─────────────────────────── 组织生命周期联动 ────────────────────────────

## 组织消失（api 层解散/删层成功后调）：清该组织全部槽位，并全板剪除指向它的
## 机构引用——别家槽里塞着它的，机构没了 = 那个槽位空置；逐槽发 slot_deactivated。
func on_org_removed(org_id: String) -> void:
	if _orgs.has(org_id):
		for function_name: String in _orgs[org_id].keys().duplicate():
			remove_slot(org_id, function_name)
	for host_id: String in _orgs.keys():
		for function_name: String in _orgs[host_id].keys().duplicate():
			if String(_orgs[host_id][function_name]["institution"]) == org_id:
				unassign_institution(host_id, function_name)


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	return {"orgs": _orgs.duplicate(true)}


func from_dict(data: Dictionary) -> void:
	_orgs.clear()
	var orgs: Dictionary = data.get("orgs", {})
	for org_id: String in orgs:
		var slots: Dictionary = {}
		for function_name: String in orgs[org_id]:
			var slot: Dictionary = orgs[org_id][function_name]
			slots[function_name] = {
				"persons": Array(slot.get("persons", [])),
				"institution": String(slot.get("institution", "")),
			}
		_orgs[org_id] = slots


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'org_slots'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'org_slots'"

## 存档回调：槽位板写 world_state 模块行（由 OrgSlotSystem 单例首建时挂接；
## 单测直测 to_dict/from_dict，不触本回调）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "org_slots",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[OrgSlotBoard] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


## 读档回调：无行 = 旧档空态；坏 JSON 按空恢复（inventory 同口径）。
func _on_game_loaded(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null:
		return
	var rows: Array = []
	if db.query_with_bindings(_SQL_ROW_SELECT, [slot_index]):
		rows = db.query_result
	if rows.is_empty():
		return
	var parsed: Variant = JSON.parse_string(str(rows[0].get("data", "")))
	if parsed is Dictionary:
		from_dict(parsed)


# ─────────────────────────── 内部 ────────────────────────────

func _slot(org_id: String, function_name: String) -> Dictionary:
	var slots: Dictionary = _orgs.get(org_id, {})
	var slot: Dictionary = slots.get(function_name, {})
	return slot if slot is Dictionary else {}


static func _is_active(slot: Dictionary) -> bool:
	return not (slot["persons"] as Array).is_empty() or not String(slot["institution"]).is_empty()


## 沿机构嵌套边追索：新边 org→institution 接入后，从 institution 出发沿**全部**
## 机构边能否走到 org（能 = 成环拒绝——一个组织多个槽位可各塞机构，须全边搜索）。
func _institution_creates_cycle(org_id: String, institution_org_id: String) -> bool:
	var visited: Dictionary = {}
	var queue: Array = [institution_org_id]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if current == org_id:
			return true
		if visited.has(current):
			continue
		visited[current] = true
		for function_name: String in _orgs.get(current, {}):
			var inst := String(_orgs[current][function_name]["institution"])
			if not inst.is_empty() and not visited.has(inst):
				queue.append(inst)
	return false
