extends Node
## 新游戏初始内容生成器 —— 初始建筑、NPC 与战场敌人的 spawn。
##
## 职责：
## - 初始建筑（读 InitialBuildingsList，直接创建 OPERATIONAL 状态建筑）
## - 村庄仓库预置
## - NPC 村民生成（含职业分配与着装，经 TownLifeAPI，town_life 模块实现）
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
	# 走 ConstructionApi（2026-08 审计收敛，不再直调内部 manager）
	var construction_api: Node = _root.get_construction_api() if _root.has_method("get_construction_api") else null
	if construction_api == null or not construction_api.has_method("spawn_operational_building"):
		push_warning("[GameRoot] ConstructionApi 未就绪，跳过初始建筑生成")
		return
	var i: int = 0
	for d in defs:
		var def_id: String = d.get("def_id") if d is Dictionary else d.def_id
		var cell_x: int = int(d.get("cell_x") if d is Dictionary else d.cell_x)
		var width: int = int(d.get("width") if d is Dictionary else d.width)
		if def_id.is_empty():
			push_warning("[GameRoot] 初始建筑 def_id 为空，跳过")
			continue
		var result: Dictionary = construction_api.spawn_operational_building(def_id, cell_x, width)
		if not result.get("ok", false):
			push_warning("[GameRoot] 初始建筑生成失败: %s cell_x=%d: %s" % [def_id, cell_x, result.get("error", "未知错误")])
		# 逐栋让帧：建筑实例化+落位是生成链大头，分帧保加载动画不断流
		i += 1
		if i % 2 == 0:
			await RenderingServer.frame_post_draw


## 预置主街东端民居（搬运系统送货/取货点）：placeholder 兼任仓库，
## 与 InitialBuildingsList 的初始布局衔接成完整主街——
## 西村口民居(-51) → 石造仓库(-34) → 铁匠铺(-17) → 宅邸地标(1) → 东侧民居(17)，
## 全部落在出生土路区（cell -40±40 的净空带内，不长树），巷道 2 格。
func spawn_initial_warehouse() -> void:
	var construction_api: Node = _root.get_construction_api() if _root.has_method("get_construction_api") else null
	if construction_api != null and construction_api.has_method("spawn_operational_building"):
		construction_api.spawn_operational_building("placeholder", 17, 16)


# ─────────────────────────────── NPC 生成 ────────────────────────────────

## 生成 NPC 村民，按职业分布两簇落脚（批次 4 配比分配），不附身（AI 接管）。
##
## 分布设计（[提案/待定]，依据 village_a 布局：硬化区 -1280~1280、仓库
## X 480~992、铁匠占位工位 X=1120、右城墙 1900、左侧森林带 -2160~-1280）：
##   - 右簇（i=0~4）：1100 + 180*i → 1100~1820，贴铁匠占位工位与仓库右缘
##     （沿用批次 1~3 的村民区，避开仓库 PassageBarrier）；
##   - 左簇（i=5~9）：-250 - 180*(i-5) → -250~-970，靠左侧资源带方向——
##     伐木/挖矿的劳作点在村外森林，就近落脚少跑通勤。
## 超界 fallback 保留（其他地图复用时防越界）。
func spawn_npcs(map: Node2D, spawn_y: float) -> void:
	# NPC 生成在东侧民居右缘之外，避开民居 PassageBarrier（cell 17~33, X 544~1088，
	# 建筑与美术升级线批次 6 布局）；右簇起点 1100 与两簇设计对齐（铁匠工位 X=1120）
	var npc_start_x: float = 1100.0
	var npcs: Array = []
	for i in _root.NPC_COUNT:
		var x: float = npc_start_x + 180.0 * float(i) if i < 5 else -250.0 - 180.0 * float(i - 5)
		# 确保在地图边界内（village_a 右簇最远 1770 < map_right-100=2060，不触发）
		if x > map.map_right - 100.0:
			x = npc_start_x + randf_range(0.0, 400.0)
		elif x < map.map_left + 100.0:
			x = randf_range(-400.0, -100.0)
		var npc: Node2D = map.spawn_entity(_root._STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
		if npc != null:
			# 修正 Y：让脚部对齐 spawn_y
			if npc.get("foot_offset") != null:
				npc.global_position.y = spawn_y - npc.foot_offset
			if npc.has_method("set_possessed"):
				npc.set_possessed(false)  # NPC 不被附身，AIController 自动接管
			# 注入 ConstructionAPI 引用（统一走 api，2026-08 审计收敛），使 NPC 可被派工（§15 阶段 0.4）
			if npc.has_method("set_construction_manager") and _root.get_construction_api() != null:
				npc.set_construction_manager(_root.get_construction_api())
			# 注入 FormationSystem 引用（编队职责查询，AIController 决策过滤）
			if npc.has_method("set_formation_system") and _root._formation_system != null:
				npc.set_formation_system(_root._formation_system)
			# 村民身份标志（批次 4）：与职业解耦——待业/被征用离岗后仍是村民
			#（wander 闲逛作用域），战斗/敌方单位无此标志（duck 写入，无类型依赖）
			npc.set("is_villager", true)
			npcs.append(npc)
		# 逐个让帧：实体实例化+依赖注入分帧，加载动画不断流
		if i % 2 == 1:
			await RenderingServer.frame_post_draw
	# 批量配比分配（town_life 模块：各职业不超过 min(quota, 工位容量)，
	# 配额满待业 wander；契约见 modules/town_life/api.gd）
	var stats: Dictionary = TownLifeAPI.assign_village_jobs(npcs)
	# stdout 证据：配比总览 + 逐村民职业/工位（视觉/日志验收材料）
	print("[TownLife] 村庄配比: 在职=%s 待业=%d（共 %d 人）" % [stats.get("jobs", {}), stats.get("idle", 0), npcs.size()])
	for npc in npcs:
		if npc == null or not is_instance_valid(npc):
			continue
		var pid := String(npc.get_profession()) if npc.has_method("get_profession") else ""
		if pid.is_empty():
			print("[TownLife]   %s 待业（村庄闲逛）" % npc.name)
			continue
		var prof: Dictionary = TownLifeAPI.get_profession(pid)
		var site_desc: String = "资源点(%s)" % prof.get("product", "?")
		var site_def := String(prof.get("work_site_def", ""))
		if not site_def.is_empty():
			var site: Dictionary = TownLifeAPI.get_work_site(npc, site_def)
			site_desc = "工位 X=%d" % int((site.get("pos", Vector2()) as Vector2).x) if not site.is_empty() else "无可用工位"
		print("[TownLife]   %s 职业=%s(%s) %s" % [npc.name, prof.get("name_zh", pid), pid, site_desc])


# ─────────────────────────────── 战场敌人 ────────────────────────────────

## 遭遇战战场生成敌方火柴人并启动战斗（battlefield 退役后的 dev 直达入口，
## 出征与领地架构 §4.3——正式进图不再自动调用，由 tests/dev/verify_battle.gd
## 等验证脚本直达组织遭遇战）。
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
		enemies.append(e)
	# 启动战斗：玩家方（进攻）vs 敌方（防守）
	if not enemies.is_empty():
		_root.start_test_battle(allies, enemies)
		print_verbose("[GameRoot] 遭遇战已启动: %d 友军（含 %d 默认步兵） vs %d 敌军" % [allies.size(), extra.size(), enemies.size()])
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
	if e.has_method("set_construction_manager") and _root.get_construction_api() != null:
		e.set_construction_manager(_root.get_construction_api())
	if e.has_method("set_formation_system") and _root._formation_system != null:
		e.set_formation_system(_root._formation_system)
	return e

