extends RefCounted
## 跨图携带快照助手 —— 从 formation_system.gd 拆出的编队快照/恢复子域，
## 并收敛三段 BalanceConfig 覆盖装载循环。
##
## 职责：
## - export_squads：导出全部编队快照（跨图携带用，travel 前由 GameRoot 收集）；
## - restore_squads：按快照重建编队（跨图携带恢复，map_loaded 后由 GameRoot 调用，
##   经宿主 create_squad/assign_leader 等既有 API 重建，零新增迁移路径）；
## - load_overrides（static）：BalanceConfig 类型路径行覆盖装载的统一内核——
##   宿主 _apply_balance_tuning（balance.variables，本文件 apply_balance_tuning）/
##   _load_phase_plan_params（ai.squad_phase_plan.global）/ _load_authority_params
##   （ai.formation_authority.global）各段装载循环收敛于此；
## - apply_balance_tuning：编队几何数值校准（balance.variables 覆盖宿主几何 var +
##   伤亡上报阈值 + 间距不变式自检），宿主 setup 调用。
##
## 纪律：_squads 状态留宿主经 _host 动态回引；恢复走宿主公共 API（快照导出后
## 由宿主 disband_all_squads 清空，旧图实体 freed 不残留）；几何 var 与伤亡阈值
## 亦留宿主，经 _host 读改（严禁缓存快照）。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 导出全部编队快照（跨图携带用，travel 前由 GameRoot 收集）。
## 返回 Array[Dictionary]：{"name", "preset_id", "work_types", "leader_iid",
##                           "members": [{"iid", "role"}]}
func export_squads() -> Array:
	var result: Array = []
	for squad_id in _host._squads.keys():
		var s: Dictionary = _host._squads[squad_id]
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
			"follow_player": s.get("follow_player", false),
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
		var squad_id: String = _host.create_squad(
			members, snap.get("name", ""), snap.get("preset_id", _host.DEFAULT_PRESET_ID)
		)
		if squad_id.is_empty():
			continue
		# 恢复自定义职责范围
		var work_types: Array = snap.get("work_types", [])
		if not work_types.is_empty():
			_host.set_squad_work_types(squad_id, work_types)
		# 恢复排长
		var leader_iid: int = int(snap.get("leader_iid", 0))
		if leader_iid != 0 and entity_map.has(leader_iid):
			var leader: Node = entity_map[leader_iid]
			if is_instance_valid(leader) and leader in members:
				_host.assign_leader(squad_id, leader)
		# 恢复跟随玩家标志（跨图后跟随不丢）
		if snap.get("follow_player", false):
			_host.set_squad_follow(squad_id, true)
		restored += 1
	return restored


# ──────────────── 存档导出/回读（读档完整性批次）────────────────

## 存档行格式（与跨图快照的分野）：
## - 跨图快照只带班（排/火力组是战斗域本地聚合）；存档是全量冻结——班 + 排
##   （编制聚合层）都入档。火力组仍不入档（号令寻址粒度随班消亡，与跨图同口径）。
## - 本助手导出以实体 iid（内存句柄）为键，由 save_handler 换算成 entities 表的
##   entity_id 稳定键落档；回读时 save_handler 传回 entity_id → 活实体映射，
##   本助手不解释键语义（跨图链传 iid、存档链传 ent id，同一套逻辑复用）。
## - 班 id = 组织 id（create_squad 经 OrganizationApi 建组织），存档透传 org_id，
##   回读时组织侧已由 save_handler 收编档内组织（id 不变），班在本体上原位重建。

## 导出全部编队 + 编制（存档用，save_handler 经 CombatAPI 调用）。
## 返回 {"squads": [{org_id, name, preset_id, work_types, leader_iid,
##                   "members": [iid], follow_player, follow_front, follow_gap}],
##        "platoons": [{platoon_id, name, squads, leader_iid, company_id}]}
func export_for_save() -> Dictionary:
	var squads: Array = []
	for squad_id in _host._squads.keys():
		var s: Dictionary = _host._squads[squad_id]
		var members: Array = []
		for u in s["units"]:
			if is_instance_valid(u):
				members.append(u.get_instance_id())
		var leader_iid: int = 0
		if s["leader"] != null and is_instance_valid(s["leader"]):
			leader_iid = s["leader"].get_instance_id()
		var follow: Dictionary = _host.get_squad_follow(String(squad_id))
		squads.append({
			"org_id": String(squad_id),
			"name": s["name"],
			"preset_id": s["preset_id"],
			"work_types": (s["work_types"] as Array).duplicate(),
			"leader_iid": leader_iid,
			"members": members,
			"follow_player": bool(s.get("follow_player", false)),
			"follow_front": String(follow.get("front", "")),
			"follow_gap": float(follow.get("gap", 0.0)),
		})
	var platoons: Array = []
	for pid in _host._platoons.keys():
		var p: Dictionary = _host._platoons[pid]
		var leader_iid: int = 0
		var pleader: Node = p.get("leader")
		if pleader != null and is_instance_valid(pleader):
			leader_iid = pleader.get_instance_id()
		platoons.append({
			"platoon_id": String(pid),
			"name": String(p.get("name", "")),
			"squads": (p.get("squads", []) as Array).duplicate(),
			"leader_iid": leader_iid,
			"company_id": String(p.get("company_id", "")),
		})
	return {"squads": squads, "platoons": platoons}


## 从存档行重建编队 + 编制（save_handler._restore_from_save 调用，编排前置：
## 宿主旧班已解散、档内组织已收编进组织模块——本方法只在既有组织上重建班本体）。
## data = save_handler 落档的 formation 行（members/leader_ent 为存档键）；
## entity_map = 存档键 → 活实体。返回成功恢复的班数。
func restore_from_save(data: Dictionary, entity_map: Dictionary) -> int:
	var restored := 0
	var built: Array = []
	for s_v in data.get("squads", []):
		var snap: Dictionary = s_v
		var org_id := String(snap.get("org_id", ""))
		if org_id.is_empty():
			continue
		# 组织侧必须有该组织（档内组织已收编）；缺 = 组织链断，跳过不硬造
		if not _org_exists(org_id):
			push_warning("[SquadSnapshot] 编队恢复跳过 %s：组织侧无此组织" % org_id)
			continue
		var members: Array = []
		for key_v in snap.get("members", []):
			var e: Node = entity_map.get(String(key_v))
			if e != null and is_instance_valid(e):
				members.append(e)
		if members.is_empty():
			push_warning("[SquadSnapshot] 编队恢复跳过 %s：无有效成员" % org_id)
			continue
		_build_squad_on_org(org_id, snap, members, entity_map)
		built.append(snap)
		restored += 1
	# 跟队锚定统一恢复（全部班就位后前队引用才必然有效；前队缺失时宿主 API 自拒）
	for snap_v in built:
		var front := String(snap_v.get("follow_front", ""))
		if not front.is_empty():
			_host.set_squad_follow_squad(String(snap_v.get("org_id", "")), front,
					float(snap_v.get("follow_gap", 0.0)))
		elif bool(snap_v.get("follow_player", false)):
			_host.set_squad_follow(String(snap_v.get("org_id", "")), true)
	# 排聚合层（班已就位后重建；排号计数器按档内最大后缀推进防新排撞车）
	for p_v in data.get("platoons", []):
		_build_platoon_from_save(p_v, entity_map)
	return restored


## 组织侧是否已有该组织（档内组织收编结果查询；duck 调 OrganizationApi 契约）。
func _org_exists(org_id: String) -> bool:
	if _host._org_api == null or not _host._org_api.has_method("get_organization"):
		return false
	return bool(_host._org_api.get_organization(org_id).get("ok", false))


## 在既有组织上重建班本体（create_squad 的"不建组织版"：状态装配/人员账/槽位/
## 军衔/信号与创建路径同形，只跳过 OrganizationApi.create_organization）。
func _build_squad_on_org(org_id: String, snap: Dictionary, members: Array, entity_map: Dictionary) -> void:
	var preset: Dictionary = _host._resolve_preset(String(snap.get("preset_id", _host.DEFAULT_PRESET_ID)))
	var work_types: Array = snap.get("work_types", [])
	if work_types.is_empty():
		work_types = (preset["work_types"] as Array).duplicate()
	var name_str := String(snap.get("name", ""))
	_host._squads[org_id] = {
		"units": members.duplicate(),
		"leader": null,
		"preset_id": preset["id"],
		"work_types": work_types,
		"role": preset["default_role"],
		"name": name_str,
		"follow_player": false,
		"follow_squad_id": "",
		"follow_gap": 0.0,
		"slots": {},
		"casualty_dead": 0,
		"casualty_reported": false,
	}
	# 班号计数器按档内默认名后缀推进（防读档后新建班默认名撞车；仅装饰性 id）
	var suffix := name_str.trim_prefix("squad_").to_int()
	if suffix > int(_host._squad_counter):
		_host._squad_counter = suffix
	var id_strings: Array = []
	for u in members:
		_host._unit_to_squad[u.get_instance_id()] = org_id
		id_strings.append(str(u.get_instance_id()))
		_host._recompute_unit_rank(u)
		_host._requisition_unit(u)
	# 组织人员账重建：档内组织 personnel 存的是存档时旧 iid（跨会话已死），
	# 按恢复后的活实体整表重写（读档完整性批次新增 OrganizationApi.set_personnel）
	if _host._org_api != null and _host._org_api.has_method("set_personnel"):
		_host._org_api.set_personnel(org_id, id_strings)
	# 编队槽位重排（几何派生数据不入档，与创建路径同源重算）
	_host._assign_formation_slots(org_id)
	# 班长恢复（组织指挥官 + rank 1 + 信号，走宿主既有 API 全语义）
	var leader: Node = entity_map.get(String(snap.get("leader_ent", "")))
	if leader != null and is_instance_valid(leader) and leader in members:
		_host.assign_leader(org_id, leader)
	# 发射信号（与 create_squad 同形，消费方按新建班处理）
	var unit_ids: Array = []
	for u in members:
		unit_ids.append(u.get_instance_id())
	_host.squad_created.emit(org_id, unit_ids)
	if EventBus != null and EventBus.has_signal("squad_created"):
		EventBus.squad_created.emit(org_id, unit_ids)


## 从存档行重建排（create_platoon 的"保 id 版"：排 id/所属班原样还原，
## 排长走宿主既有任命 API；班缺失/已属他排的剔除，剔空的排丢弃）。
func _build_platoon_from_save(p_snap: Dictionary, entity_map: Dictionary) -> void:
	var pid := String(p_snap.get("platoon_id", ""))
	if pid.is_empty():
		return
	var valid: Array = []
	for sid_v in p_snap.get("squads", []):
		var sid := String(sid_v)
		if _host._squads.has(sid) and not _host._squad_to_platoon.has(sid):
			valid.append(sid)
	if valid.is_empty():
		return
	_host._platoons[pid] = {
		"name": String(p_snap.get("name", "")),
		"squads": valid,
		"leader": null,
		"company_id": String(p_snap.get("company_id", "")),
	}
	for sid in valid:
		_host._squad_to_platoon[sid] = pid
	# 排号计数器推进（防读档后新建排 id 撞车）
	var suffix := pid.trim_prefix("platoon_").to_int()
	if suffix > int(_host._platoon_counter):
		_host._platoon_counter = suffix
	# 排长恢复（须为排内班成员，宿主 API 自校验；缺档/实体失效 = 保持缺口，
	# 与"排长阵亡无补位"的编制语义一致）
	var leader: Node = entity_map.get(String(p_snap.get("leader_ent", "")))
	if leader != null and is_instance_valid(leader):
		_host.assign_platoon_leader(pid, leader)
	_host.platoon_created.emit(pid, valid.duplicate())


# ──────────────── BalanceConfig 覆盖装载（三段循环收敛）────────────────

## 统一装载内核：代码默认 ← BalanceConfig 类型路径行覆盖（只认默认键，未知键
## 忽略防错字）。BalanceConfig 缺载/路径缺失安全回退代码默认（unit 测试不依赖
## autoload）。兼容两种行形态：
##   - Dictionary 行（ai.*.global）：逐键覆盖 defaults 已有键；
##   - Array 行（balance.variables，{id, value} 行表）：按 id→value 展开，
##     仅当值为数值（float/int）时覆盖同 id 键（几何/阈值类数值门槛，语义不变）。
static func load_overrides(defaults: Dictionary, type_path: String) -> Dictionary:
	var merged: Dictionary = defaults.duplicate(true)
	var cfg: Node = _balance_config()
	if cfg == null or cfg.data.is_empty():
		return merged
	var row_v: Variant = cfg.get_value(type_path)
	if row_v is Dictionary:
		var row: Dictionary = row_v
		for k in row.keys():
			if merged.has(k):
				merged[k] = row[k]
	elif row_v is Array:
		var by_id := {}
		for r: Dictionary in row_v:
			if r.has("id"):
				by_id[r["id"]] = r.get("value")
		for k in merged.keys():
			var v: Variant = by_id.get(k)
			if v is float or v is int:
				merged[k] = v
	return merged


## BalanceConfig autoload 稳健解析（static 上下文不直引 autoload 标识符；
## 主循环未就绪/非 SceneTree 返回 null，调用方空档案例外兜底）。
## 先例：team_ai_profiles._balance_config 同款写法。
static func _balance_config() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("BalanceConfig")


## 编队几何数值校准（宿主 setup 调用）：balance.variables（Excel 平衡变量表）覆盖
## 代码默认（装载循环 = 本文件 load_overrides，BalanceConfig 装载职责同一收敛面，
## 不分住两处）。几何 var 与伤亡上报阈值状态留宿主，经 _host 回引读改（严禁缓存
## 快照——balance 可覆盖，读改须直达宿主字段）。
## 间距不变式自检（formation_spacing 头部不变式的代码化）：调参表只覆盖间距，
## 不校验链式关系——压穿分离椭圆 = 分离力常驻 + 位置伺服极限环（全员蛇形
## 抽动，2026-10-05 实测 vx 翻转 8.67 次/s）。违例如实打 error，启动不阻断
##（数值档问题归调参，不让游戏起不来）
func apply_balance_tuning() -> void:
	var merged: Dictionary = load_overrides({
		"var_spread_spacing": _host.SPREAD_SPACING,
		"var_follow_default_gap": _host.FOLLOW_DEFAULT_GAP,
		"var_row_gap": _host.ROW_GAP,
		"var_catchup_run_dist": _host.CATCHUP_RUN_DIST,
		"var_report_casualty_threshold": _host._casualty_report_threshold,
	}, "balance.variables")
	_host.SPREAD_SPACING = float(merged["var_spread_spacing"])
	_host.FOLLOW_DEFAULT_GAP = float(merged["var_follow_default_gap"])
	_host.ROW_GAP = float(merged["var_row_gap"])
	_host.CATCHUP_RUN_DIST = float(merged["var_catchup_run_dist"])
	_host._casualty_report_threshold = float(merged["var_report_casualty_threshold"])
	for violation in FormationSpacing.check_invariants(_host.SPREAD_SPACING, _host.ROW_GAP,
			FormationSpacing.ARRIVE_TOLERANCE):
		push_error("[Formation] 间距不变式违例：%s" % violation)
