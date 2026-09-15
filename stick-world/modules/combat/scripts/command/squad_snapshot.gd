extends RefCounted
## 跨图携带快照助手 —— 从 formation_system.gd 拆出的编队快照/恢复子域，
## 并收敛三段 BalanceConfig 覆盖装载循环。
##
## 职责：
## - export_squads：导出全部编队快照（跨图携带用，travel 前由 GameRoot 收集）；
## - restore_squads：按快照重建编队（跨图携带恢复，map_loaded 后由 GameRoot 调用，
##   经宿主 create_squad/assign_leader 等既有 API 重建，零新增迁移路径）；
## - load_overrides（static）：BalanceConfig 类型路径行覆盖装载的统一内核——
##   宿主 _apply_balance_tuning（balance.variables）/ _load_phase_plan_params
##   （ai.squad_phase_plan.global）/ _load_authority_params
##   （ai.formation_authority.global）三段近似相同的装载循环收敛于此。
##
## 纪律：_squads 状态留宿主经 _host 动态回引；恢复走宿主公共 API（快照导出后
## 由宿主 disband_all_squads 清空，旧图实体 freed 不残留）。

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
