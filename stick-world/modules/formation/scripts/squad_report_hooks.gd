extends RefCounted
## 信息上报挂点助手 —— 从 formation_system.gd 拆出的战斗域上报出口子域
## （§4.4，3-F2）+ 编队征用互斥。
##
## combat 只发原始事件，档位门控（autonomy 三档）归组织侧 evaluate_report_gate
## 判定；P0 三类事件全产自战斗域，经此出口落 report_filed 信号（一层直报）。
##
## 职责：
## - file_squad_report：上报出口（组织侧门控通过才落报告，架构文档 §4.4）；
## - evaluate_casualty_report：伤亡上报评估（死亡清理处每次死亡调用一次，
##   存活比跌破阈值沿只报首次，回升后重置沿标记再报）；
## - squad_contact_enemy_count：小队接敌规模统计（contact payload.enemy_count）；
## - requisition_unit：编队征用互斥（在岗村民入伍自动离岗）。
##
## 纪律：_squads/_casualty_report_threshold/_org_api 全部留宿主，经 _host 动态
## 回引读写（_casualty_report_threshold 是 var，balance 可覆盖，严禁缓存快照）。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 上报出口：组织侧门控通过才落报告（combat 挂点统一用法，架构文档 §4.4）
func file_squad_report(squad_id: String, type: String, payload: Dictionary) -> void:
	if _host._org_api == null or not _host._org_api.has_method("evaluate_report_gate"):
		return
	if not _host._org_api.evaluate_report_gate(squad_id, type, payload):
		return
	_host._org_api.file_report(squad_id, {
		"type": type,
		"filed_at": Time.get_ticks_msec(),
		"payload": payload,
	})


## 伤亡上报评估（死亡清理处每次死亡调用一次）：存活比跌破阈值沿只报首次，
## 回升（增员/救治）后重置沿标记再报；档位差异由门控承担（HIGH 恒不报/LOW 全量口径下
## 仍按沿触发——架构文档 §4.4 挂点规格统一状态机）。
func evaluate_casualty_report(squad_id: String) -> void:
	var squad: Dictionary = _host._squads.get(squad_id, {})
	if squad.is_empty():
		return
	var alive: int = 0
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			alive += 1
	var dead: int = int(squad.get("casualty_dead", 0))
	var total: int = alive + dead
	if total <= 0:
		return
	var ratio: float = float(alive) / float(total)
	if ratio >= _host._casualty_report_threshold:
		squad["casualty_reported"] = false
		return
	if bool(squad.get("casualty_reported", false)):
		return
	squad["casualty_reported"] = true
	file_squad_report(squad_id, "casualty_threshold", {
		"alive": alive,
		"dead": dead,
		"total": total,
		"loss_rate": 1.0 - ratio,
	})


## 小队接敌规模（contact payload.enemy_count）：小队成员射程内去重存活敌人数
##（口径同宿主 _member_enemy_in_range 的接敌判定，P0 首次接敌时一次性统计）
func squad_contact_enemy_count(squad_id: String) -> int:
	var seen: Dictionary = {}
	if not _host._squads.has(squad_id):
		return 0
	for u in _host._squads[squad_id]["units"]:
		if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
			continue
		if not u.has_method("get_battle_instance"):
			continue
		var bi: Node = u.get_battle_instance()
		if bi == null or not is_instance_valid(bi) or not bi.has_method("get_enemies_of"):
			continue
		var faction: int = u.get_faction() if u.has_method("get_faction") else 0
		if faction == 0:
			continue
		var weapon: Node = u.get_weapon() if u.has_method("get_weapon") else null
		var attack_range: float = float(weapon.attack_range) if weapon != null and "attack_range" in weapon else 100.0
		for e in bi.get_enemies_of(faction):
			if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
				continue
			if u.global_position.distance_to(e.global_position) <= attack_range:
				seen[e.get_instance_id()] = true
	return seen.size()


## 编队征用互斥（小镇生活批次 4）：在岗村民被征入伍自动离岗——清职业回
## 待业池。duck 协议（get_profession/set_profession），零 town_life 模块依赖，
## 无职业协议/已待业的单位跳过。离岗后劳作由 BehaviorHarvest 自查职业清空
## 即时收工（AI 决策层 _try_harvest 同判职业空，不会重进劳作）。
## 释放/解散不自动回岗（P0 决策：进待业池闲逛，重新分配走存档/后续系统）。
func requisition_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not unit.has_method("get_profession") or not unit.has_method("set_profession"):
		return
	if not String(unit.get_profession()).is_empty():
		unit.set_profession("")
