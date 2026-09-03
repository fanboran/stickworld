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


func setup(root: GameRoot) -> void:
	_root = root
	if EventBus:
		if EventBus.has_signal("game_saving"):
			EventBus.game_saving.connect(_on_game_saving)
		if EventBus.has_signal("game_loaded"):
			EventBus.game_loaded.connect(_on_game_loaded)
	# 实例化存档面板（经 UIAPI 工厂，全屏 UI 根挂 ModalOverlay 槽）
	_root._save_panel = UIAPI.create_save_panel()
	_root._save_panel.visible = false
	if _root.ui_root != null:
		_root.ui_root.add_to_slot("ModalOverlay", _root._save_panel)
	else:
		_root.add_child(_root._save_panel)
	if _root._save_panel.has_method("setup_load_callback"):
		_root._save_panel.setup_load_callback(_on_load_slot)


## SavePanel 读档回调（SavePanel 不反向依赖 world，由本子系统注入）
func _on_load_slot(slot_index: int) -> void:
	load_game_from_slot(slot_index)


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
	# 1. 地图边界 -> maps 表
	if map != null and map.has_method("save_to_db"):
		map.save_to_db(db, slot_id, map_id)
	# 2. 建筑 + 建造项目 -> buildings + construction_projects 表（经 ConstructionAPI 契约，禁止直调内部 manager）
	if _root._construction_api != null and _root._construction_api.has_method("save_to_db"):
		_root._construction_api.save_to_db(db, slot_id, map_id)
	# 3. 实体（玩家+NPC）-> entities 表
	_save_entities(db, slot_id, map_id, map)
	# 4. 资源点 -> resource_nodes 表
	if map != null and map.has_method("save_resource_nodes_to_db"):
		map.save_resource_nodes_to_db(db, slot_id, map_id)
	# 5. 更新 save_meta.current_map_id
	if not db.query_with_bindings(_SQL_META_UPDATE_MAP, [map_id, slot_id]):
		push_error("[SaveHandler] save_meta.current_map_id 更新失败 slot=%d map=%s: %s" % [slot_id, map_id, str(db.error_message)])


## 保存实体到 DB
func _save_entities(db, slot_id: int, map_id: String, map: Node2D) -> void:
	if map == null:
		return
	if not db.query_with_bindings(_SQL_ENT_DELETE, [slot_id, map_id]):
		push_error("[SaveHandler] entities 旧数据清理失败 slot=%d map=%s: %s" % [slot_id, map_id, str(db.error_message)])
	var idx: int = 0
	for entity in map.get_entities():
		if not is_instance_valid(entity):
			continue
		var is_player: int = 1 if (entity.has_method("is_possessed") and entity.is_possessed()) else 0
		var facing: int = int(entity.get("_facing")) if "_facing" in entity else 1
		var extra: Dictionary = {}
		if "faction_id" in entity:
			extra["faction_id"] = entity.faction_id
		if not db.insert_row("entities", {
			"slot_id": slot_id, "map_id": map_id,
			"entity_id": "ent_%04d" % idx,
			"entity_type": "stickman",
			"def_id": "stickman_basic",
			"pos_x": entity.global_position.x,
			"pos_y": entity.global_position.y,
			"facing": facing,
			"is_player": is_player,
			"extra_data": JSON.stringify(extra),
		}):
			push_error("[SaveHandler] 实体写入失败 slot=%d map=%s id=ent_%04d: %s" % [slot_id, map_id, idx, str(db.error_message)])
		idx += 1


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
	# 兜底：存档缺地图信息（空档/损坏档/无图状态下存的档）时回退新游戏开局，
	# 绝不能不加载地图（否则黑屏只剩 UI）
	if _root._cached_load_map_id.is_empty():
		push_warning("[SaveHandler] 存档槽位 %d 无地图信息，回退新游戏开局" % slot_index)
		_root._pending_save_load = false
		_root._cached_load_map_id = _root.VILLAGE_A_MAP_ID
		# 无恢复流程，立即关闭 DB（不等 _load_guard 30s 超时）
		if SaveManager and SaveManager.has_method("end_load"):
			SaveManager.end_load()
	call_deferred("_load_map_for_save")


## 外部调用：启动读档流程
func load_game_from_slot(slot_index: int) -> void:
	_root._pending_save_load = true
	# 清理当前地图实例（如果存在）
	if _root.world_chunk_host != null and _root.world_chunk_host.get_child_count() > 0:
		var old_map: Node2D = _root.world_chunk_host.get_child(0) as Node2D
		if old_map:
			old_map.queue_free()
		_root._initial_map_loaded = false
	# 调用 SaveManager.load_game（会 emit game_loaded -> _on_game_loaded -> 加载地图）
	if SaveManager and SaveManager.has_method("load_game"):
		SaveManager.load_game(slot_index)


## 读档时加载缓存的地图
func _load_map_for_save() -> void:
	if _root.scene_loader == null or not _root.scene_loader.has_method("load_map"):
		return
	if not _root.scene_loader.map_loaded.is_connected(_root._on_map_loaded):
		_root.scene_loader.map_loaded.connect(_root._on_map_loaded)
	if _root._cached_load_map_id.is_empty():
		_root._cached_load_map_id = _root.VILLAGE_A_MAP_ID
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
	# 3. 恢复玩家 + NPC
	_restore_entities(db, slot_id, map_id, map)
	# 4. 恢复资源点
	if map.has_method("load_resource_nodes_from_db"):
		map.load_resource_nodes_from_db(db, slot_id, map_id)
	# 5. 恢复城墙地形遮罩（经 ConstructionAPI 契约）
	if _root._construction_api != null and _root._construction_api.has_method("refresh_city_terrain_mask"):
		_root._construction_api.refresh_city_terrain_mask()
	# 6. 重新设置相机/小地图边界
	if _root.camera_rig != null and _root.camera_rig.has_method("set_map_bounds"):
		_root.camera_rig.set_map_bounds(map.map_left, map.map_right)
	if _root._minimap != null and _root._minimap.has_method("set_map_info"):
		_root._minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 7. 兜底：恢复后无玩家实体（实体表空/损坏）→ 生成默认玩家，保证可操作
	if _root.get_player_entity() == null:
		push_warning("[SaveHandler] 存档无玩家实体，生成默认玩家兜底")
		var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
		var player: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(0.0, spawn_y))
		if player != null:
			if player.get("foot_offset") != null:
				player.global_position.y = spawn_y - player.foot_offset
			if player.has_method("set_possessed"):
				player.set_possessed(true)
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
func _restore_entities(db, slot_id: int, map_id: String, map: Node2D) -> void:
	var rows: Array = []
	if db.query_with_bindings(_SQL_ENT_SELECT, [slot_id, map_id]):
		rows = db.query_result
	for row in rows:
		var pos := Vector2(float(row["pos_x"]), float(row["pos_y"]))
		var entity: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, pos)
		if entity == null:
			continue
		# 修正 Y（脚部对齐）
		if entity.get("foot_offset") != null:
			entity.global_position.y = pos.y - entity.foot_offset
		# 朝向
		if "_facing" in entity:
			entity.set("_facing", int(row["facing"]))
		# 玩家附身
		if int(row["is_player"]) == 1 and entity.has_method("set_possessed"):
			entity.set_possessed(true)
			if _root.camera_rig != null and _root.camera_rig.has_method("set_follow_target"):
				_root.camera_rig.set_follow_target(entity)
			# 读档进入即对准玩家（水平居中）
			if _root.camera_rig != null and _root.camera_rig.has_method("snap_to_follow_target"):
				_root.camera_rig.snap_to_follow_target()
		else:
			if entity.has_method("set_possessed"):
				entity.set_possessed(false)
		# 玩家与 NPC 都注入 ConstructionManager（玩家按E交互需要）
		if entity.has_method("set_construction_manager") and _root._construction_manager != null:
			entity.set_construction_manager(_root._construction_manager)


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
