extends Node
## 新游戏初始内容生成器 —— 初始建筑、NPC 与战场敌人的 spawn。
##
## 职责：
## - 初始建筑（读 InitialBuildingsList，直接创建 OPERATIONAL 状态建筑）
## - 村庄仓库预置
## - NPC 村民生成
## - 遭遇战战场敌方生成（红色阵营 + 启动战斗）
## - 火柴人身体颜色设置
##
## 由 GameRoot._ready 挂载为 InitialContent 子节点并调用 setup(root)。

var _root: GameRoot


func setup(root: GameRoot) -> void:
	_root = root


# ─────────────────────────────── 初始建筑 ────────────────────────────────

## 读取地图的 InitialBuildingsList，直接创建 OPERATIONAL 状态建筑（跳过建造过程）。
## P0-2 修复：绕过存档系统，在 VillageMap 首次加载时预置建筑。
func spawn_initial_buildings(map: Node2D) -> void:
	var ibl: Node = map.get("initial_buildings_list") if "initial_buildings_list" in map else null
	if ibl == null or not ibl.has_method("get_defs"):
		return
	var defs: Array = ibl.get_defs()
	if defs.is_empty():
		return
	if _root._construction_manager == null or not _root._construction_manager.has_method("spawn_operational_building"):
		push_warning("[GameRoot] ConstructionManager 未就绪，跳过初始建筑生成")
		return
	for d in defs:
		var def_id: String = d.get("def_id") if d is Dictionary else d.def_id
		var cell_x: int = int(d.get("cell_x") if d is Dictionary else d.cell_x)
		var width: int = int(d.get("width") if d is Dictionary else d.width)
		if def_id.is_empty():
			push_warning("[GameRoot] 初始建筑 def_id 为空，跳过")
			continue
		var result: Dictionary = _root._construction_manager.spawn_operational_building(def_id, cell_x, width)
		if not result.get("ok", false):
			push_warning("[GameRoot] 初始建筑生成失败: %s cell_x=%d: %s" % [def_id, cell_x, result.get("error", "未知错误")])


## 预置村庄仓库（搬运系统取货点，放在出生点右侧土路区）
func spawn_initial_warehouse() -> void:
	if _root._construction_manager != null and _root._construction_manager.has_method("spawn_operational_building"):
		_root._construction_manager.spawn_operational_building("bld_warehouse", 15, 16)


# ─────────────────────────────── NPC 生成 ────────────────────────────────

## 生成 NPC 村民，分布在玩家右侧不同 X 位置，不附身（AI 接管）。
func spawn_npcs(map: Node2D, spawn_y: float) -> void:
	# NPC 生成在仓库右侧，避开仓库 PassageBarrier（cell 15~31, X 480~992）
	var npc_start_x: float = 1050.0
	for i in _root.NPC_COUNT:
		var x: float = npc_start_x + 200.0 * i
		# 确保在地图边界内
		if x > map.map_right - 100.0:
			x = npc_start_x + randf_range(0.0, 400.0)
		var npc: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
		if npc != null:
			# 修正 Y：让脚部对齐 spawn_y
			if npc.get("foot_offset") != null:
				npc.global_position.y = spawn_y - npc.foot_offset
			if npc.has_method("set_possessed"):
				npc.set_possessed(false)  # NPC 不被附身，AIController 自动接管
			# 注入 ConstructionManager 引用，使 NPC 可被派工（§15 阶段 0.4）
			if npc.has_method("set_construction_manager") and _root._construction_manager != null:
				npc.set_construction_manager(_root._construction_manager)
			# 注入 FormationSystem 引用（编队职责查询，AIController 决策过滤）
			if npc.has_method("set_formation_system") and _root._formation_system != null:
				npc.set_formation_system(_root._formation_system)


# ─────────────────────────────── 战场敌人 ────────────────────────────────

## 阶段 E：遭遇战战场生成敌方火柴人并启动战斗。
## 我方为红色阵营（视觉区分），玩家方（allies：玩家 + 随行编队）为进攻方。
## count: 敌方数量（默认 4，dev 场景可调）。
## 默认步兵补位：allies 少于 MIN_DEFAULT_INFANTRY 时补 spawn 蓝方基础步兵
## （玩家没带队伍也能打像样的仗），返回补位后的 allies 列表。
func spawn_battlefield_enemies(map: Node2D, allies: Array, count: int = 4) -> Array:
	if map == null:
		return allies
	# 默认步兵补位（战场应有基础部队，见 GDD §6.7 战场地图）
	var min_infantry: int = 3
	var current: int = 0
	for a in allies:
		if is_instance_valid(a) and not (a.has_method("is_dead") and a.is_dead()):
			current += 1
	var extra: Array = []
	while current < min_infantry:
		var inf: Node2D = _spawn_ally_unit(map, current)
		if inf == null:
			break
		extra.append(inf)
		current += 1
	allies.append_array(extra)
	if allies.is_empty():
		return allies
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var enemies: Array = []
	# 敌方在战场右端（玩家从左侧进入）
	for i in count:
		var x: float = map.map_right - 250.0 - i * 60.0
		var e: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
		if e == null:
			continue
		# 修正 Y：让脚部对齐 spawn_y
		if e.get("foot_offset") != null:
			e.global_position.y = spawn_y - e.foot_offset
		# 不附身（AI 接管）
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		# 红色身体区分敌方
		set_unit_body_color(e, Color(0.82, 0.22, 0.22))
		enemies.append(e)
	# 启动战斗：玩家方（进攻）vs 敌方（防守）
	if not enemies.is_empty():
		_root.start_test_battle(allies, enemies)
		print("[GameRoot] 遭遇战已启动: %d 友军（含 %d 默认步兵） vs %d 敌军" % [allies.size(), extra.size(), enemies.size()])
	return allies


## spawn 一个默认蓝方步兵（玩家侧基础部队），返回实体。
func _spawn_ally_unit(map: Node2D, idx: int) -> Node2D:
	if map == null:
		return null
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var x: float = map.map_left + 250.0 + 70.0 * idx
	var e: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = spawn_y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	if e.has_method("set_construction_manager") and _root._construction_manager != null:
		e.set_construction_manager(_root._construction_manager)
	if e.has_method("set_formation_system") and _root._formation_system != null:
		e.set_formation_system(_root._formation_system)
	# 蓝色身体区分友军（红=敌）
	set_unit_body_color(e, Color(0.35, 0.55, 0.95))
	return e


## 设置火柴人身体颜色（用于阵营视觉区分）
func set_unit_body_color(entity: Node2D, color: Color) -> void:
	if not is_instance_valid(entity):
		return
	var r = entity.get("rig") if "rig" in entity else null
	if r != null and "body_color" in r:
		r.body_color = color
