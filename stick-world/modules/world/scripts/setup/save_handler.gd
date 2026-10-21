extends Node
## GameRoot 存档子系统 —— 负责存档/读档全流程。
##
## 职责：
## - 订阅 EventBus.game_saving / game_loaded
## - 保存地图 / 建筑 / 实体 / 资源点到 SQLite DB
## - 从 DB 恢复场景（地图 / 建筑 / 实体 / 资源点）
## - SavePanel 实例化与显隐、快速存档/读档
##
## 由 GameRoot._ready 挂载为 SaveHandler 子节点并调用 setup(root)。
## 对外提供 load_game_from_slot / quick_save / quick_load / toggle_save_panel，
## 由 GameRoot 主脚本转发调用。

var _root: GameRoot

# SQL 白名单：表名/列名为固定常量；运行时值（slot_id/map_id）一律经 ? 绑定
# （query_with_bindings），禁止字符串拼接进 SQL。
const _SQL_META_UPDATE_MAP := "UPDATE save_meta SET current_map_id = ? WHERE slot_id = ?"
const _SQL_META_SELECT_MAP := "SELECT current_map_id FROM save_meta WHERE slot_id = ?"
const _SQL_ENT_DELETE := "DELETE FROM entities WHERE slot_id = ? AND map_id = ?"
const _SQL_ENT_SELECT := "SELECT * FROM entities WHERE slot_id = ? AND map_id = ?"
# 编队/编制行（world_state 表模块数据通道，同 inventory 契约；无行 = 旧档，向后兼容空编队）
const _SQL_FORMATION_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'formation'"
const _SQL_FORMATION_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'formation'"


func setup(root: GameRoot) -> void:
	_root = root
	for step in _step_table():
		(step[1] as Callable).call()


## 分帧装配入口（启动加载屏用）：绑定 root 并返回步骤表——调用方逐步执行、
## 每步之间让一帧并推进副进度条（与 SystemSetup 同模式，语义与 setup() 一致）。
func setup_steps(root: GameRoot) -> Array:
	_root = root
	return _step_table()


## 装配步骤表：每项 = [细分标签, 可调用]，顺序即依赖顺序。
func _step_table() -> Array:
	return [
		["订阅存档事件", _subscribe_save_events],
		["构造存档面板", _create_save_panel],
		["挂载面板槽位", _attach_save_panel],
	]


func _subscribe_save_events() -> void:
	if EventBus:
		if EventBus.has_signal("game_saving"):
			EventBus.game_saving.connect(_on_game_saving)
		if EventBus.has_signal("game_loaded"):
			EventBus.game_loaded.connect(_on_game_loaded)


## 实例化存档面板（经 UIAPI 构造，全屏 UI 根挂 ModalOverlay 槽）
func _create_save_panel() -> void:
	_root._save_panel = UIAPI.create_save_panel()
	_root._save_panel.visible = false


func _attach_save_panel() -> void:
	if _root.ui_root != null:
		_root.ui_root.add_to_slot("ModalOverlay", _root._save_panel)
	else:
		_root.add_child(_root._save_panel)
	if _root._save_panel.has_method("setup_load_callback"):
		_root._save_panel.setup_load_callback(_on_load_slot)


## SavePanel 读档回调（SavePanel 不反向依赖 world，由本子系统注入）
func _on_load_slot(slot_index: int) -> bool:
	return load_game_from_slot(slot_index)


# ─────────────────────────────── 保存流程 ────────────────────────────────

## 存档保存回调（由 EventBus.game_saving 触发）
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null:
		return
	var slot_id: int = SaveManager.get_current_slot() if SaveManager.has_method("get_current_slot") else -1
	if slot_id < 0:
		return
	var map: Node2D = _root.get_current_map()
	var map_id: String = ""
	if _root.scene_loader and "current_map_id" in _root.scene_loader:
		map_id = _root.scene_loader.current_map_id
	# F6 步行中（道路场景）跳过本次存档：道路场景不落盘（会话内缓存），
	# 读档恒回上次成功存档的聚落，避免 meta.current_map_id 指向无法恢复的 road_*
	if map_id.begins_with("road_"):
		return
	# 1. 地图边界 -> maps 表
	if map != null and map.has_method("save_to_db"):
		map.save_to_db(db, slot_id, map_id)
	# 2. 建筑 + 建造项目 -> buildings + construction_projects 表（经 ConstructionAPI 契约，禁止直调内部 manager）
	if _root._construction_api != null and _root._construction_api.has_method("save_to_db"):
		_root._construction_api.save_to_db(db, slot_id, map_id)
	# 3. 实体（玩家+NPC）-> entities 表（返回 iid→entity_id 映射，编队导出用）
	var iid_to_ent: Dictionary = _save_entities(db, slot_id, map_id, map)
	# 4. 资源点 -> resource_nodes 表
	if map != null and map.has_method("save_resource_nodes_to_db"):
		map.save_resource_nodes_to_db(db, slot_id, map_id)
	# 5. 编队/编制 -> world_state 表 module_name='formation'（经 CombatAPI 契约；
	#    成员/排长以 entities 表的 entity_id 为稳定键落档）
	_save_formation(db, slot_id, iid_to_ent)
	# 6. 更新 save_meta.current_map_id
	if not db.query_with_bindings(_SQL_META_UPDATE_MAP, [map_id, slot_id]):
		push_error("[SaveHandler] save_meta.current_map_id 更新失败 slot=%d map=%s: %s" % [slot_id, map_id, str(db.error_message)])


## 编队/编制落档（读档完整性批次）：CombatAPI 导出（成员/排长 = 实体 iid）→
## 换算成 entities 表的 entity_id 稳定键 → 写 world_state 表（module_name='formation'）。
## 火力组不入档（号令寻址粒度，战斗域本地聚合，与跨图快照同口径）。
func _save_formation(db, slot_id: int, iid_to_ent: Dictionary) -> void:
	var raw: Dictionary = {}
	if _root._combat_api != null and _root._combat_api.has_method("export_for_save"):
		raw = _root._combat_api.export_for_save()
	var row: Dictionary = _remap_formation_keys(raw, iid_to_ent)
	if not db.query_with_bindings(_SQL_FORMATION_DELETE, [slot_id]):
		push_error("[SaveHandler] 编队旧档清理失败 slot=%d: %s" % [slot_id, str(db.error_message)])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "formation",
		"data": JSON.stringify(row),
	}):
		push_error("[SaveHandler] 编队存档写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


## 编队导出键换算：iid（内存句柄，跨会话失效）→ entity_id（存档稳定键）。
## 成员不在映射内（已释放实体）剔除；成员剔空的班、班剔空后的排整体丢弃；
## 班长缺失落空串（读侧按无班长恢复）。org_id / follow_front / platoon.squads
## 是组织侧稳定 id，原样透传；排的 squads 过滤到存活班集合。
func _remap_formation_keys(raw: Dictionary, iid_to_ent: Dictionary) -> Dictionary:
	var squads_out: Array = []
	var surviving_orgs: Dictionary = {}
	for s_v in raw.get("squads", []):
		var s: Dictionary = s_v
		var members: Array = []
		for iid_v in s.get("members", []):
			var ent: Variant = iid_to_ent.get(int(iid_v))
			if ent != null:
				members.append(str(ent))
		if members.is_empty():
			continue
		var leader_ent: String = ""
		var leader_iid: int = int(s.get("leader_iid", 0))
		if leader_iid != 0 and iid_to_ent.has(leader_iid):
			leader_ent = str(iid_to_ent[leader_iid])
		var org_id := String(s.get("org_id", ""))
		squads_out.append({
			"org_id": org_id,
			"name": String(s.get("name", "")),
			"preset_id": String(s.get("preset_id", "")),
			"work_types": s.get("work_types", []),
			"leader_ent": leader_ent,
			"members": members,
			"follow_player": bool(s.get("follow_player", false)),
			"follow_front": String(s.get("follow_front", "")),
			"follow_gap": float(s.get("follow_gap", 0.0)),
		})
		if not org_id.is_empty():
			surviving_orgs[org_id] = true
	var platoons_out: Array = []
	for p_v in raw.get("platoons", []):
		var p: Dictionary = p_v
		var p_squads: Array = []
		for sid_v in p.get("squads", []):
			var sid := String(sid_v)
			if surviving_orgs.has(sid):
				p_squads.append(sid)
		if p_squads.is_empty():
			continue
		var leader_ent: String = ""
		var leader_iid: int = int(p.get("leader_iid", 0))
		if leader_iid != 0 and iid_to_ent.has(leader_iid):
			leader_ent = str(iid_to_ent[leader_iid])
		platoons_out.append({
			"platoon_id": String(p.get("platoon_id", "")),
			"name": String(p.get("name", "")),
			"squads": p_squads,
			"leader_ent": leader_ent,
			"company_id": String(p.get("company_id", "")),
		})
	return {"squads": squads_out, "platoons": platoons_out}


## 保存实体到 DB
## 实体行收集后走 insert_rows 事务批包（逐行 insert_row 每行一次磁盘提交，
## 中期存档数百实体时为存档卡顿主源之一，同 building_persistence 的批包改造）
## 返回 iid→entity_id 映射（编队导出把成员/排长换算成存档稳定键用）。
func _save_entities(db, slot_id: int, map_id: String, map: Node2D) -> Dictionary:
	var iid_to_ent: Dictionary = {}
	if map == null:
		return iid_to_ent
	if not db.query_with_bindings(_SQL_ENT_DELETE, [slot_id, map_id]):
		push_error("[SaveHandler] entities 旧数据清理失败 slot=%d map=%s: %s" % [slot_id, map_id, str(db.error_message)])
	var rows: Array = []
	var idx: int = 0
	for entity in map.get_entities():
		if not is_instance_valid(entity):
			continue
		var is_player: int = 1 if (entity.has_method("is_user_controlled") and entity.is_user_controlled()) else 0
		var facing: int = int(entity.get("_facing")) if "_facing" in entity else 1
		var extra: Dictionary = {}
		if "faction_id" in entity:
			extra["faction_id"] = entity.faction_id
		# town_life 持久化：职业 id 与村民身份随档（读档回填恢复劳作循环）。
		# 装具（工具变体）不落档——读档按 profession 重新应用（_restore_entities），
		# 与 assign 路径同一出口（TownLifeAPI.apply_profession_appearance）。
		if "is_villager" in entity:
			extra["is_villager"] = bool(entity.get("is_villager"))
		if entity.has_method("get_profession"):
			extra["profession"] = String(entity.get_profession())
		# AI 决策时钟族（WB2 错峰读档保真）：只带相对剩余时长 + 错峰种子，
		# 读档按 spawn 后回填（不重掷假偏移，见 ai_controller.import_timing_state）
		var ai: Node = entity.get_ai_controller() if entity.has_method("get_ai_controller") else null
		if ai != null and is_instance_valid(ai) and ai.has_method("export_timing_state"):
			extra["ai_timing"] = ai.export_timing_state()
		# 个体装备记录（loadout 奠基）：随档往返（读档经 set_loadout 应用主手）
		if entity.has_method("get_loadout") and not entity.get_loadout().is_empty():
			extra["loadout"] = entity.get_loadout()
		rows.append({
			"slot_id": slot_id, "map_id": map_id,
			"entity_id": "ent_%04d" % idx,
			"entity_type": "stickman",
			"def_id": "stickman_basic",
			"pos_x": entity.global_position.x,
			"pos_y": entity.global_position.y,
			"facing": facing,
			"is_player": is_player,
			"extra_data": JSON.stringify(extra),
		})
		iid_to_ent[entity.get_instance_id()] = "ent_%04d" % idx
		idx += 1
	if not rows.is_empty() and not db.insert_rows("entities", rows):
		push_error("[SaveHandler] 实体批量写入失败 slot=%d map=%s（%d 行）: %s" % [slot_id, map_id, rows.size(), str(db.error_message)])
	return iid_to_ent


# ─────────────────────────────── 加载流程 ────────────────────────────────

## 存档加载回调（由 EventBus.game_loaded 触发）
func _on_game_loaded(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db != null:
		var rows: Array = []
		if db.query_with_bindings(_SQL_META_SELECT_MAP, [slot_index]):
			rows = db.query_result
		if not rows.is_empty():
			_root._cached_load_map_id = str(rows[0].get("current_map_id", ""))
		# F6 防御：road_* 不入档（步行中存档被跳过），旧档异常带出时回退出生城
		if _root._cached_load_map_id.begins_with("road_"):
			push_warning("[SaveHandler] 存档指向道路场景（异常档），回退出生城")
			_root._cached_load_map_id = "l1_settlement_00"
	# 兜底：存档缺地图信息（空档/损坏档/无图状态下存的档）时回退新游戏开局，
	# 绝不能不加载地图（否则黑屏只剩 UI）
	if _root._cached_load_map_id.is_empty():
		push_warning("[SaveHandler] 存档槽位 %d 无地图信息，回退新游戏开局" % slot_index)
		_root._pending_save_load = false
		_root._cached_load_map_id = _root._start_map_id_for_fallback()
		# 无恢复流程，立即关闭 DB（不等 _load_guard 30s 超时）
		if SaveManager and SaveManager.has_method("end_load"):
			SaveManager.end_load()
	call_deferred("_load_map_for_save")


## 外部调用：启动读档流程。
## 返回 false = 拒读（版本过高/迁移失败/存档不存在等，原因见 SaveManager.last_load_fail_reason）：
## 已弹 ui_notification，且不动当前世界（旧地图清理移到受理之后）。
func load_game_from_slot(slot_index: int) -> bool:
	_root._pending_save_load = true
	# 先试读：拒读（game_loaded 不发射、恢复流程不启动）时保持当前世界原状
	var accepted: bool = false
	if SaveManager and SaveManager.has_method("load_game"):
		accepted = SaveManager.load_game(slot_index)
	if not accepted:
		_root._pending_save_load = false
		_notify_load_failed(slot_index)
		return false
	# 读档已受理（game_loaded 已同步发射，地图恢复走 call_deferred）：
	# 清理当前地图实例（如果存在）
	if _root.world_chunk_host != null and _root.world_chunk_host.get_child_count() > 0:
		var old_map: Node2D = _root.world_chunk_host.get_child(0) as Node2D
		if old_map:
			old_map.queue_free()
		_root._initial_map_loaded = false
	return true


## 读档失败的用户可见反馈（走 EventBus ui_notification → UIRoot 左下通知 feed）。
## boot 主菜单阶段无 UIRoot 时 emit 会被静默丢弃，只剩 push_error（客观限制，无害）。
func _notify_load_failed(slot_index: int) -> void:
	var reason: String = ""
	if SaveManager and "last_load_fail_reason" in SaveManager:
		reason = str(SaveManager.last_load_fail_reason)
	if reason.is_empty():
		reason = "未知原因"
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("读档失败", "槽位 %d：%s" % [slot_index, reason], "error")


## 读档时加载缓存的地图
func _load_map_for_save() -> void:
	if _root.scene_loader == null or not _root.scene_loader.has_method("load_map"):
		return
	if not _root.scene_loader.map_loaded.is_connected(_root._on_map_loaded):
		_root.scene_loader.map_loaded.connect(_root._on_map_loaded)
	if _root._cached_load_map_id.is_empty():
		_root._cached_load_map_id = _root._start_map_id_for_fallback()
	_root.scene_loader.load_map(_root._cached_load_map_id)


## 从存档恢复场景
func _restore_from_save(map: Node2D, map_id: String) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	# 1. 恢复地图边界
	if map.has_method("load_from_db"):
		map.load_from_db(db, slot_id, map_id)
	# 2. 恢复建筑 + 建造项目（经 ConstructionAPI 契约）
	if _root._construction_api != null and _root._construction_api.has_method("load_from_db"):
		_root._construction_api.load_from_db(db, slot_id, map_id)
	# 3. 编队清场 + 组织收编（读档完整性批次，顺序不可换）：
	#    先清编队本地态（clear_squads_for_load：不触组织侧——mid-session 读档时
	#    game_loaded 已把 WorldState 容器覆盖为档内组织，班 id = 组织 id 与旧班撞车，
	#    经 disband_organization 解散旧班会把档内组织从容器反注销，收编即断链），
	#    再从 WorldState 容器收编档内组织（game_loaded 时容器已被回读覆盖，此处
	#    同步本模块工作集；旧班对应的旧组织随工作集整体覆盖消亡）。
	#    boot 读档两步皆空操作；旧档无编队数据时也照常执行（清残留语义）。
	if _root._combat_api != null and _root._combat_api.has_method("clear_squads_for_load"):
		_root._combat_api.clear_squads_for_load()
	if _root._organization_api != null and _root._organization_api.has_method("restore_from_world"):
		_root._organization_api.restore_from_world()
	# 4. 恢复玩家 + NPC（返回 entity_id → 实体映射，编队回读用）
	var ent_map: Dictionary = _restore_entities(db, slot_id, map_id, map)
	# 5. 恢复编队/编制（world_state 表 module_name='formation'；旧档无此行 = 空编队）
	_restore_formation(db, slot_id, ent_map)
	# 6. 恢复资源点
	if map.has_method("load_resource_nodes_from_db"):
		map.load_resource_nodes_from_db(db, slot_id, map_id)
	# 7. 恢复城墙地形遮罩（经 ConstructionAPI 契约）
	if _root._construction_api != null and _root._construction_api.has_method("refresh_city_terrain_mask"):
		_root._construction_api.refresh_city_terrain_mask()
	# 8. 重新设置相机/小地图边界
	if _root.camera_rig != null and _root.camera_rig.has_method("set_map_bounds"):
		_root.camera_rig.set_map_bounds(map.map_left, map.map_right)
	if _root._minimap != null and _root._minimap.has_method("set_map_info"):
		_root._minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 9. 兜底：恢复后无玩家实体（实体表空/损坏）→ 生成默认玩家，保证可操作
	if _root.get_player_entity() == null:
		push_warning("[SaveHandler] 存档无玩家实体，生成默认玩家兜底")
		var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
		var player: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(0.0, spawn_y))
		if player != null:
			if player.get("foot_offset") != null:
				player.global_position.y = spawn_y - player.foot_offset
			if player.has_method("set_user_controlled"):
				player.set_user_controlled(true)
			if player.has_method("set_construction_manager") and _root._construction_api != null:
				player.set_construction_manager(_root._construction_api)
			if player.has_method("set_formation_system") and _root._formation_system != null:
				player.set_formation_system(_root._formation_system)
			if _root.camera_rig != null and _root.camera_rig.has_method("set_follow_target"):
				_root.camera_rig.set_follow_target(player)
			# 兜底生成玩家同样对准（水平居中）
			if _root.camera_rig != null and _root.camera_rig.has_method("snap_to_follow_target"):
				_root.camera_rig.snap_to_follow_target()
	# 关闭 DB
	if SaveManager and SaveManager.has_method("end_load"):
		SaveManager.end_load()


## 从 DB 恢复实体
## 返回 entity_id → 实体节点映射（编队回读把档内成员键换算回活实体用）。
func _restore_entities(db, slot_id: int, map_id: String, map: Node2D) -> Dictionary:
	var ent_map: Dictionary = {}
	var rows: Array = []
	if db.query_with_bindings(_SQL_ENT_SELECT, [slot_id, map_id]):
		rows = db.query_result
	for row in rows:
		var pos := Vector2(float(row["pos_x"]), float(row["pos_y"]))
		var entity: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, pos)
		if entity == null:
			continue
		ent_map[str(row.get("entity_id", ""))] = entity
		# 修正 Y（脚部对齐）
		if entity.get("foot_offset") != null:
			entity.global_position.y = pos.y - entity.foot_offset
		# 朝向
		if "_facing" in entity:
			entity.set("_facing", int(row["facing"]))
		# 玩家接管
		if int(row["is_player"]) == 1 and entity.has_method("set_user_controlled"):
			entity.set_user_controlled(true)
			if _root.camera_rig != null and _root.camera_rig.has_method("set_follow_target"):
				_root.camera_rig.set_follow_target(entity)
			# 读档进入即对准玩家（水平居中）
			if _root.camera_rig != null and _root.camera_rig.has_method("snap_to_follow_target"):
				_root.camera_rig.snap_to_follow_target()
		else:
			if entity.has_method("set_user_controlled"):
				entity.set_user_controlled(false)
		# AI 决策时钟族（WB2）：档内有 ai_timing 才导入——相位（错峰）保真且不再重掷；
		# 老存档无该字段（或字段损坏）→ 保持 spawn 时装配语义，不报错
		var timing: Variant = _parse_extra_field(row, "ai_timing")
		if timing is Dictionary:
			var ai: Node = entity.get_ai_controller() if entity.has_method("get_ai_controller") else null
			if ai != null and is_instance_valid(ai) and ai.has_method("import_timing_state"):
				ai.import_timing_state(timing)
		# 个体装备记录回填（loadout）：main_hand 覆盖兵种默认武器。老档无字段
		# → 保持 spawn 默认，不报错
		var loadout: Variant = _parse_extra_field(row, "loadout")
		if loadout is Dictionary and entity.has_method("set_loadout"):
			entity.set_loadout(loadout)
		# town_life 回填（职业/村民身份随档）：读档后村民才能继续劳作——
		# 职业回填后重挂装具（工具不入档，按 id 重新应用）。老档无字段 →
		# 保持默认（无职业/非村民），不报错；配置已删改的职业 id 回待业池。
		var prof: Variant = _parse_extra_field(row, "profession")
		if prof is String and entity.has_method("set_profession"):
			var pid := str(prof)
			if not pid.is_empty() and TownLifeAPI.get_profession(pid).is_empty():
				pid = ""
			entity.set_profession(pid)
			if not pid.is_empty():
				TownLifeAPI.apply_profession_appearance(entity, pid)
		var villager: Variant = _parse_extra_field(row, "is_villager")
		if villager != null:
			entity.set("is_villager", bool(villager))
		# 阵营回填（读档完整性批次）：faction_id 写侧既有而读侧此前缺失——经
		# set_faction 恢复阵营（同步血条阵营色）。旧档缺字段 → null → 保持
		# spawn 默认 0（未参战），不报错。
		var fid: Variant = _parse_extra_field(row, "faction_id")
		if fid != null and entity.has_method("set_faction"):
			entity.set_faction(int(fid))
		# 玩家与 NPC 都注入 ConstructionManager（玩家按F交互需要）
		if entity.has_method("set_construction_manager") and _root._construction_api != null:
			entity.set_construction_manager(_root._construction_api)
	return ent_map


## 从 world_state 表恢复编队/编制（读档完整性批次）。
## 行格式权威 = _save_formation（org_id/成员 ent 键）；恢复本体在 formation 模块
## （经 CombatAPI 契约，squad_snapshot.restore_from_save）。无行/坏 JSON → 空编队
## （旧档向后兼容缺省）。
func _restore_formation(db, slot_id: int, ent_map: Dictionary) -> void:
	if _root._combat_api == null or not _root._combat_api.has_method("restore_from_save"):
		return
	var rows: Array = []
	if db.query_with_bindings(_SQL_FORMATION_SELECT, [slot_id]):
		rows = db.query_result
	if rows.is_empty():
		return
	var parsed: Variant = JSON.parse_string(str(rows[0].get("data", "")))
	if not (parsed is Dictionary):
		push_warning("[SaveHandler] 编队存档行 JSON 损坏 slot=%d，按无编队恢复" % slot_id)
		return
	_root._combat_api.restore_from_save(parsed, ent_map)


## 解析 entities.extra_data 中的指定字段（列缺失/空串/非 JSON/非字典/无该键 → null；
## 老档安全回退，调用方按"字段不存在"处理）
func _parse_extra_field(row: Dictionary, key: String) -> Variant:
	var raw: String = str(row.get("extra_data", ""))
	if raw.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return null
	var d: Dictionary = parsed
	return d[key] if d.has(key) else null


# ─────────────────────────────── 对外接口（由 GameRoot 转发） ────────────────────────────────

## 切换存档面板可见性（经模态栈层键 SAVE_PANEL；无栈环境回退面板自身 toggle）
func toggle_save_panel() -> void:
	if _root._save_panel == null:
		return
	var stack: UIModalStack = _root.ui_root.get_modal_stack() if _root.ui_root != null else null
	if stack != null:
		if stack.is_open(UIModalStack.Layer.SAVE_PANEL):
			stack.pop(UIModalStack.Layer.SAVE_PANEL)
		else:
			stack.push(_root._save_panel, UIModalStack.Layer.SAVE_PANEL)
	elif _root._save_panel.has_method("toggle"):
		_root._save_panel.toggle()


## 快速保存到槽位 0
func quick_save() -> void:
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(0)
		print_verbose("[GameRoot] 快速保存到槽位 0")


## 快速读取槽位 0
func quick_load() -> void:
	if SaveManager and SaveManager.has_method("slot_exists") and SaveManager.slot_exists(0):
		load_game_from_slot(0)
		print_verbose("[GameRoot] 快速读取槽位 0")
	else:
		push_warning("[GameRoot] 槽位 0 无存档")
		# 用户可见反馈（游戏内快捷键路径，UIRoot 必已装配）
		if EventBus != null and EventBus.has_signal("ui_notification"):
			EventBus.ui_notification.emit("读档失败", "槽位 0 无存档", "error")
