extends RefCounted
## 排聚合层助手 —— 从 formation_system.gd 拆出的排（platoon）子域。
##
## 排 = 2~3 个班 + 排长 1 名（rank 2）。排是战斗域本地聚合（不入组织树）：
## 组织侧继任/补位只认班（L1 org）的指挥官——排长阵亡天然无继任，指挥链缺口
## 保持到战斗结束（"屏蔽继任"由构造保证）。连/战场层挂载点：platoon 的
## company_id 字段（2~4 排归属哪个连，由指挥官批次接入）。
##
## 纪律：_platoons/_squad_to_platoon/_platoon_counter/_squads/_unit_to_squad
## 全部留宿主，经 _host 动态回引读写（状态唯一真相源在宿主）；本类无自持状态。
## 军衔联动（_recompute_unit_rank）与信号（platoon_created/platoon_leader_lost）
## 都走宿主。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 创建排：把若干已存在班聚合为一个排。班须存在且未属于其他排。
## 返回 platoon_id（失败返回 ""）。
func create_platoon(squad_ids: Array, platoon_name: String = "") -> String:
	var valid: Array = []
	for sid_v in squad_ids:
		var sid := String(sid_v)
		if not _host._squads.has(sid):
			push_warning("[FormationSystem] 创建排失败：班不存在 %s" % sid)
			return ""
		if _host._squad_to_platoon.has(sid):
			push_warning("[FormationSystem] 创建排失败：班已属于其他排 %s" % sid)
			return ""
		valid.append(sid)
	if valid.is_empty():
		push_warning("[FormationSystem] 创建排失败：无有效班")
		return ""
	_host._platoon_counter += 1
	var pid: String = "platoon_%d" % _host._platoon_counter
	_host._platoons[pid] = {
		"name": platoon_name if not platoon_name.is_empty() else pid,
		"squads": valid,
		"leader": null,
		"company_id": "",  # 连层挂载点预留（指挥官批次接入）
	}
	for sid in valid:
		_host._squad_to_platoon[sid] = pid
	_host.platoon_created.emit(pid, valid.duplicate())
	return pid


## 任命排长（rank 2）。排长须是排内某班的成员（随班行军、占编队槽位）。
## 排长阵亡后本 API 仍可手动重任命（测试/剧情口），但系统侧永不自动补位。
## 返回是否成功。
func assign_platoon_leader(platoon_id: String, leader: Node) -> bool:
	if not _host._platoons.has(platoon_id):
		push_warning("[FormationSystem] 排不存在: %s" % platoon_id)
		return false
	if not is_instance_valid(leader):
		return false
	# 须为排内班的成员
	var in_platoon := false
	for sid_v in _host._platoons[platoon_id]["squads"]:
		var sid := String(sid_v)
		if _host._squads.has(sid) and leader in _host._squads[sid]["units"]:
			in_platoon = true
			break
	if not in_platoon:
		push_warning("[FormationSystem] 任命排长失败：单位不在该排任何班中")
		return false
	# 若在他排挂职先卸任（一人不领两排）
	for pid_v in _host._platoons.keys():
		if String(pid_v) != platoon_id and _host._platoons[pid_v].get("leader") == leader:
			_host._platoons[pid_v]["leader"] = null
	_host._platoons[platoon_id]["leader"] = leader
	_host._recompute_unit_rank(leader)
	return true


## 排长查询（缺口时返回 null）。
func get_platoon_leader(platoon_id: String) -> Node:
	if not _host._platoons.has(platoon_id):
		return null
	return _host._platoons[platoon_id]["leader"]


## 排内班 id 列表。
func get_platoon_squads(platoon_id: String) -> Array:
	if not _host._platoons.has(platoon_id):
		return []
	return (_host._platoons[platoon_id]["squads"] as Array).duplicate()


## 班所属排 id（独立班返回 ""）。
func get_platoon_of_squad(squad_id: String) -> String:
	return String(_host._squad_to_platoon.get(squad_id, ""))


## 单位所属排 id（未编队/独立班成员返回 ""）。
func get_unit_platoon(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	return get_platoon_of_squad(_host.get_unit_squad(unit))


## 排内全部单位（各班成员拼合；排级作用域遍历用）。
func get_platoon_units(platoon_id: String) -> Array:
	if not _host._platoons.has(platoon_id):
		return []
	var out: Array = []
	for sid_v in _host._platoons[platoon_id]["squads"]:
		var sid := String(sid_v)
		if _host._squads.has(sid):
			out.append_array(_host._squads[sid]["units"])
	return out


func get_all_platoons() -> Array:
	return _host._platoons.keys()


func get_platoon_count() -> int:
	return _host._platoons.size()


## 解散排（班保留转独立，不随排散；排长卸任削秩）。
func disband_platoon(platoon_id: String) -> void:
	if not _host._platoons.has(platoon_id):
		return
	var leader: Node = _host._platoons[platoon_id].get("leader")
	for sid_v in _host._platoons[platoon_id]["squads"]:
		_host._squad_to_platoon.erase(String(sid_v))
	_host._platoons.erase(platoon_id)
	if leader != null and is_instance_valid(leader):
		_host._recompute_unit_rank(leader)


## 班指挥链是否完整（集火/光环决策口径）：独立班恒完整（班长口径自管）；
## 排内班 = 排长存活。排长缺口 → false（该排失去集火号令）。
func has_squad_command_chain(squad_id: String) -> bool:
	var pid := get_platoon_of_squad(squad_id)
	if pid.is_empty() or not _host._platoons.has(pid):
		return true
	var leader: Node = _host._platoons[pid]["leader"]
	if leader == null or not is_instance_valid(leader):
		return false
	return not (leader.has_method("is_dead") and leader.is_dead())


## 班离排（班解散/移编时清理归属；排内班空自动解散排）。
func remove_squad_from_platoon(squad_id: String) -> void:
	var pid := String(_host._squad_to_platoon.get(squad_id, ""))
	if pid.is_empty():
		return
	_host._squad_to_platoon.erase(squad_id)
	if not _host._platoons.has(pid):
		return
	(_host._platoons[pid]["squads"] as Array).erase(squad_id)
	if (_host._platoons[pid]["squads"] as Array).is_empty():
		disband_platoon(pid)


## 单位死亡后核对排长身份（_process 死亡清理处调用）：是排长则置指挥链缺口——
## leader 置空 + 该排班集火清空 + 发 platoon_leader_lost。无任何补位/继任路径
##（排不入组织树，组织侧继任不触达），缺口保持到战斗结束。
func check_platoon_leader_death(u: Node) -> void:
	for pid_v in _host._platoons.keys():
		var pid := String(pid_v)
		if _host._platoons[pid].get("leader") != u:
			continue
		_host._platoons[pid]["leader"] = null
		for sid_v in _host._platoons[pid]["squads"]:
			_host._squad_targets.erase(String(sid_v))
		_host.platoon_leader_lost.emit(pid)
