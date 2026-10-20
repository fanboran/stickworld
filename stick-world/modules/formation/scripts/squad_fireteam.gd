extends RefCounted
## 火力组助手 —— 从 formation_system.gd 拆出的班内指挥分组子域。
##
## 火力组 = 班内成员子集的指挥分组（RL 层级指挥训练 v3 §一编制的地基层：班长以
## 火力组为单位细分命令——「一号攻 X、二号攻 Y」，火力组是最小指挥单元）。
## 设计边界（v3 §一定案）：
##   - 只是命令的粒度，不是组织树节点/编制实体——不动组织模块、不占军衔
##    （组长 = 组内首员，无任何标记）；战斗中组随成员阵亡收缩，不重组不跳槽；
##   - 不拆散班聚结：一次性归队锚点仍是班长（squad_cohesion 零改动），班内
##     槽位/集火全按班走——火力组只回答「号令发给谁」（TacticalOrders.issue
##     对 ft_id 寻址分流，按班下令原语义不变）；
##   - 战斗域本地聚合（同排 platoon 口径）：不入组织树、不进跨图快照，
##     disband_all_squads 一并清空。
##
## 纪律：_fireteams/_unit_to_fireteam/_fireteam_counter 全部留宿主，经 _host
## 动态回引读写（状态唯一真相源在宿主）；本类无自持状态。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 创建火力组：把班内若干成员编为一组。units 须全部是该班在册存活成员（无效/
## 阵亡者滤除，重复成员去重）；已在本班其他火力组的成员自动移入新组（班长重劈
## 组常用）。返回 ft_id（失败返回 ""）。
func create_fireteam(squad_id: String, units: Array, ft_name: String = "") -> String:
	if not _host._squads.has(squad_id):
		push_warning("[FormationSystem] 创建火力组失败：班不存在 %s" % squad_id)
		return ""
	var squad: Dictionary = _host._squads[squad_id]
	var members: Array = []
	for u in units:
		if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
			continue
		if u not in squad["units"]:
			push_warning("[FormationSystem] 创建火力组失败：单位不在该班 %s 中" % squad_id)
			return ""
		if u in members:
			continue
		members.append(u)
	if members.is_empty():
		push_warning("[FormationSystem] 创建火力组失败：无有效成员")
		return ""
	_host._fireteam_counter += 1
	var ft_id: String = "fireteam_%d" % _host._fireteam_counter
	_host._fireteams[ft_id] = {
		"squad_id": squad_id,
		"units": members,
		"name": ft_name if not ft_name.is_empty() else ft_id,
	}
	for u in members:
		# 从旧组移入新组（仅同班可能——异班单位通不过上面的成员校验）
		var old := String(_host._unit_to_fireteam.get(u.get_instance_id(), ""))
		if not old.is_empty() and _host._fireteams.has(old):
			(_host._fireteams[old]["units"] as Array).erase(u)
		_host._unit_to_fireteam[u.get_instance_id()] = ft_id
	purge_empty_fireteams(squad_id)
	return ft_id


## 班内火力组 id 列表（编组序）。
func get_squad_fireteams(squad_id: String) -> Array:
	var out: Array = []
	for ft_id_v in _host._fireteams.keys():
		var ft_id := String(ft_id_v)
		if String(_host._fireteams[ft_id]["squad_id"]) == squad_id:
			out.append(ft_id)
	return out


## 全场火力组数（调试/测试观测位；同 get_platoon_count 口径）。
func get_fireteam_count() -> int:
	return _host._fireteams.size()


## 火力组成员（值拷贝；含阵亡者——死亡清理由 _process 逐出，口径同 get_squad_units）。
func get_fireteam_units(ft_id: String) -> Array:
	if not _host._fireteams.has(ft_id):
		return []
	return (_host._fireteams[ft_id]["units"] as Array).duplicate()


## 单位所属火力组 id（未入组返回 ""）。
func get_unit_fireteam(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	return String(_host._unit_to_fireteam.get(unit.get_instance_id(), ""))


## 火力组父班 id（ft_id 无效返回 ""）。
func get_fireteam_squad(ft_id: String) -> String:
	if not _host._fireteams.has(ft_id):
		return ""
	return String(_host._fireteams[ft_id]["squad_id"])


## id 是否为火力组（TacticalOrders 寻址分流用；班 id 返回 false）。
func is_fireteam(id: String) -> bool:
	return _host._fireteams.has(id)


## 火力组组长（组内首员，无军衔无标记——纯语义寻址；首员阵亡/失效顺延下一位）。
func get_fireteam_leader(ft_id: String) -> Node:
	if not _host._fireteams.has(ft_id):
		return null
	for u in _host._fireteams[ft_id]["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			return u
	return null


## 解散火力组（成员留班不散；组无存续价值时班长重劈用）。
func disband_fireteam(ft_id: String) -> void:
	if not _host._fireteams.has(ft_id):
		return
	for u in _host._fireteams[ft_id]["units"]:
		if is_instance_valid(u):
			_host._unit_to_fireteam.erase(u.get_instance_id())
	_host._fireteams.erase(ft_id)


## 清扫某班的空组（成员死绝/被移走的火力组自动消亡——组随成员阵亡收缩，
## 空组无指挥粒度）。
func purge_empty_fireteams(squad_id: String) -> void:
	for ft_id_v in _host._fireteams.keys().duplicate():
		var ft_id := String(ft_id_v)
		if String(_host._fireteams[ft_id]["squad_id"]) != squad_id:
			continue
		if (_host._fireteams[ft_id]["units"] as Array).is_empty():
			disband_fireteam(ft_id)


## 单位移出其所在火力组（离班/阵亡共用；空组随之消亡）。
func remove_unit_from_fireteam(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	var ft_id := String(_host._unit_to_fireteam.get(iid, ""))
	if ft_id.is_empty():
		return
	_host._unit_to_fireteam.erase(iid)
	if not _host._fireteams.has(ft_id):
		return
	(_host._fireteams[ft_id]["units"] as Array).erase(unit)
	purge_empty_fireteams(String(_host._fireteams[ft_id]["squad_id"]))
