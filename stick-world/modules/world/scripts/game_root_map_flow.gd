extends RefCounted
## GameRoot 地图生命周期响应助手 —— 无 class_name（经 game_root.gd const preload 引用）。
##
## 职责域：
##   开局分流（主菜单读档槽 vs 新游戏）→ _load_start_village
##   map_loaded 编排（音效宿主/系统注入/玩家 spawn/设施与村民生成）→ _on_map_loaded
##   跨图携带（带队出征：编队快照收集 + 随行重放）→ _on_travel_started / _spawn_travel_followers
##   步行旅行状态消费 → _consume_walk_state
##
## 设计：状态全部留在宿主 GameRoot（_pending_squad_snapshots / _pending_save_load /
## _initial_map_loaded / _boot_world_phase 等），本助手只承载逻辑，经 _host 回引读写；
## 宿主保留同名薄壳转发（信号 / deferred / SaveHandler 直调的连接面不变）。
## 协程（_load_start_village / _on_map_loaded）经薄壳不 await 转发，保持
## fire-and-forget 等价语义。

var _host: GameRoot


func _init(host: GameRoot) -> void:
	_host = host


## 切图：注销已释放的音效空间化宿主（新图加载时会在 _on_map_loaded 重新注册）
func _on_sfx_map_unloaded(_map_id: String) -> void:
	if AudioManager != null and AudioManager.has_method("set_sfx_host"):
		AudioManager.set_sfx_host(null)


func _load_start_village() -> void:
	if _host.scene_loader == null or not _host.scene_loader.has_method("load_map"):
		return
	# 永久监听 map_loaded，处理所有地图加载（初始 + 切换）
	if not _host.scene_loader.map_loaded.is_connected(_host._on_map_loaded):
		_host.scene_loader.map_loaded.connect(_host._on_map_loaded)
	# 切图时注销音效空间化宿主（旧地图即将释放，留着会悬空）
	if _host.scene_loader.has_signal("map_unloaded") \
			and not _host.scene_loader.map_unloaded.is_connected(_host._on_sfx_map_unloaded):
		_host.scene_loader.map_unloaded.connect(_host._on_sfx_map_unloaded)
	# 监听 travel_started：旧图卸载前收集编队快照（跨图携带）
	if not _host.scene_loader.travel_started.is_connected(_host._on_travel_started):
		_host.scene_loader.travel_started.connect(_host._on_travel_started)
	# 主菜单指定读档槽位：启动即读档（代替新游戏）
	if SaveManager and SaveManager.boot_load_slot >= 0:
		var boot_slot: int = SaveManager.boot_load_slot
		SaveManager.boot_load_slot = -1
		print_verbose("[GameRoot] 启动读档: 槽位 %d" % boot_slot)
		_host._show_loading("正在读取存档…（%d/%d）" % [_host.BOOT_STAGES - 1, _host.BOOT_STAGES],
				float(_host.BOOT_STAGES - 1) / float(_host.BOOT_STAGES))
		# 先让"读取存档"这一帧画出来再进同步读档——顺序反了文字永远不上屏，
		# 玩家盯着上一段文字以为卡死（7/9 假死教训）
		await _host._yield_frame()
		var boot_accepted: bool = false
		if _host._save_system != null and _host._save_system.has_method("load_game_from_slot"):
			boot_accepted = _host._save_system.load_game_from_slot(boot_slot)
		if boot_accepted:
			return
		# 拒读（版本过高/迁移失败/存档不存在）：不 return，落到下方新游戏开局——
		# 与 SaveHandler._on_game_loaded「缺地图信息回退新游戏」同一兜底哲学，
		# 避免加载遮罩永久停留黑屏；失败原因已由 SaveHandler 经 ui_notification 提示
		# （此时 UIRoot 已装配，通知随遮罩淡出可见）。
		print_verbose("[GameRoot] 启动读档被拒（槽位 %d），回退新游戏" % boot_slot)
	# 新游戏：重置游戏时间 + 本局随机种子（防上一局残留；读档路径经 load_save_data 恢复种子）
	if WorldState and "game_time" in WorldState:
		WorldState.game_time = 0.0
	# EnvironmentSystem 本地时钟每帧写回 WorldState（其 _process），且同进程重开一局时
	# 其 _ready 已把上一局残留时刻采纳进本地——只归零 WorldState 会被下一帧覆盖回去，
	# 须一并重置到清晨，否则上一局玩到夜里重开的新地图开局即黑夜
	var env = _host.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("reset_to_new_run_clock"):
		env.reset_to_new_run_clock()
	if WorldState and WorldState.has_method("start_new_run"):
		WorldState.start_new_run()
	# 原型阶段：每次启动都是新游戏（重建存档），不自动读档——旧存档与新代码
	# 不兼容会带来异常状态（灰屏/位置错乱）；手动存档/读档（SavePanel/quick_*）保留
	print_verbose("[GameRoot] 开始新游戏")
	_host._show_loading("正在生成世界…（%d/%d）" % [_host.BOOT_STAGES - 1, _host.BOOT_STAGES],
			float(_host.BOOT_STAGES - 1) / float(_host.BOOT_STAGES))
	# 同上：先渲染"生成世界"帧，再进地图实例化的最长同步块
	await _host._yield_frame()
	_host.scene_loader.load_map(_start_map_id_for_fallback())


## 开局图唯一出口：boot 覆盖（测试声明初始图）优先，否则启动直连主图。
## 新游戏开局与存档缺地图信息兜底（SaveHandler）共用，保证两路取图一致。
func _start_map_id_for_fallback() -> String:
	return _host.boot_map_id_override if not _host.boot_map_id_override.is_empty() else _host.START_MAP_ID


## travel_started 回调：旧图卸载前快照全部编队（跨图携带，带队出征）。
func _on_travel_started(_from_id: String, _to_id: String, _mode: int) -> void:
	_snapshot_squads_for_travel()


## 从 FormationSystem 导出编队快照，存入 _pending_squad_snapshots。
## 导出后立即解散全部编队（旧图实体即将随地图销毁，避免 freed 引用残留）。
## 统一走 CombatApi（2026-08 审计收敛，不再直调 combat 内部 manager）。
func _snapshot_squads_for_travel() -> void:
	_host._pending_squad_snapshots = []
	if _host._combat_api == null:
		return
	if _host._combat_api.has_method("export_squads"):
		_host._pending_squad_snapshots = _host._combat_api.export_squads()
	if _host._combat_api.has_method("disband_all_squads"):
		_host._combat_api.disband_all_squads()


## 跨图携带：在新地图 spawn 随行编队成员（在玩家右侧依次排开）并重建编队。
## map 必须为 scene_loader.get_current_map()（新图）——get_current_map() 取
## world_chunk_host 第一个子节点，旧图 queue_free 延迟销毁时可能返回旧图。
## 返回新地图上的随行实体列表（不含玩家）。无快照时返回空数组。
func _spawn_travel_followers(map: Node2D, player: Node2D, spawn_y: float) -> Array:
	var followers: Array = []
	if _host._pending_squad_snapshots.is_empty():
		return followers
	var snapshots: Array = _host._pending_squad_snapshots
	_host._pending_squad_snapshots = []
	if map == null or not map.has_method("spawn_entity"):
		return followers
	# 旧 instance_id -> 新实体
	var entity_map: Dictionary = {}
	var idx: int = 1
	for snap in snapshots:
		for m in snap.get("members", []):
			var old_iid: int = int(m.get("iid", 0))
			if old_iid == 0 or entity_map.has(old_iid):
				continue
			var x: float = player.global_position.x + 70.0 * idx
			var f: Node2D = map.spawn_entity(_host._STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
			if f == null:
				continue
			# 修正 Y：脚部对齐
			if f.get("foot_offset") != null:
				f.global_position.y = spawn_y - f.foot_offset
			# 不附身（AI 接管），注入系统引用
			if f.has_method("set_possessed"):
				f.set_possessed(false)
			if f.has_method("set_construction_manager") and _host._construction_api != null:
				f.set_construction_manager(_host._construction_api)
			if f.has_method("set_formation_system") and _host._formation_system != null:
				f.set_formation_system(_host._formation_system)
			entity_map[old_iid] = f
			followers.append(f)
			idx += 1
	# 重建编队（preset/职责/排长）
	if _host._combat_api != null and _host._combat_api.has_method("restore_squads"):
		_host._combat_api.restore_squads(snapshots, entity_map)
	return followers


## 通用地图加载回调（初始加载 + 地图切换共用）
func _on_map_loaded(map_id: String, map_type: int) -> void:
	var map: Node2D = _host.scene_loader.get_current_map() if _host.scene_loader.has_method("get_current_map") else null
	if map == null or not map.has_method("spawn_entity"):
		return
	# 音效空间化宿主：AudioStreamPlayer2D 必须挂在 Node2D 下（AudioManager 自身是 Node），
	# 挂在当前地图上即可让"屏外的打架声"随距离衰减（详见 音效触发规范.md §八）
	if AudioManager != null and AudioManager.has_method("set_sfx_host"):
		AudioManager.set_sfx_host(map)
	# 注入地图到 ConstructionManager（供项目实例化建筑用；走 api 收敛）
	if _host._construction_api != null and _host._construction_api.has_method("set_map"):
		_host._construction_api.set_map(map)
	# 阶段 F：注入地图到 MapBoundaryDetector
	if _host._boundary_detector != null and _host._boundary_detector.has_method("set_map"):
		_host._boundary_detector.set_map(map)
	# 配置相机：注入 ground_y / ground_ratio / map_bounds（详见 §2.4.7）
	if _host.camera_rig != null and _host.camera_rig.has_method("set_ground_y"):
		_host.camera_rig.set_ground_y(map.ground_y)
	if _host.camera_rig != null and _host.camera_rig.has_method("set_ground_ratio"):
		_host.camera_rig.set_ground_ratio(map.ground_ratio)
	if _host.camera_rig != null and _host.camera_rig.has_method("set_map_bounds"):
		_host.camera_rig.set_map_bounds(map.map_left, map.map_right)
	# 配置小地图地图信息（详见 §10.4.6）
	if _host._minimap != null and _host._minimap.has_method("set_map_info"):
		_host._minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 读档恢复：跳过默认 spawn，由 SaveHandler 接管
	if _host._pending_save_load:
		_host._pending_save_load = false
		await _host._world_sub_phase("存档恢复")
		_host._save_system._restore_from_save(map, map_id)
	# 正常流程：spawn 玩家 + 初始内容
	else:
		var spawn_x: float
		var entry_side: int = _host.scene_loader.get_last_entry_side() if _host.scene_loader.has_method("get_last_entry_side") else WorldAPI.EntrySide.LEFT
		if not _host._initial_map_loaded:
			spawn_x = _host.PLAYER_SPAWN_X
		else:
			if entry_side == WorldAPI.EntrySide.LEFT:
				spawn_x = map.map_left + 150.0
			else:
				spawn_x = map.map_right - 150.0
		var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
		# 地图自定义出生点（如 HD-2D 街景图：街中心前景，而非边缘入口）
		if map.has_method("get_spawn_point"):
			var sp: Vector2 = map.get_spawn_point()
			spawn_x = sp.x
			spawn_y = sp.y
		# Spawn 玩家
		var player: Node2D = map.spawn_entity(_host._STICKMAN_ENTITY_SCENE, Vector2(spawn_x, spawn_y))
		if player == null:
			return
		# 修正 Y：让脚部对齐 spawn_y
		if player.get("foot_offset") != null:
			player.global_position.y = spawn_y - player.foot_offset
			# 附身玩家实体（地图切换时需重新附身新实体）
		if player.has_method("set_possessed"):
			player.set_possessed(true)
		# 玩家也注入 ConstructionManager（按F搬运/建造交互需要）
		if player.has_method("set_construction_manager") and _host._construction_api != null:
			player.set_construction_manager(_host._construction_api)
		# 玩家注入 FormationSystem（编队职责查询）
		if player.has_method("set_formation_system") and _host._formation_system != null:
			player.set_formation_system(_host._formation_system)
		# 玩家注入 OrganizationApi（招兵交互经 org api 转发 RecruitManager）
		if player.has_method("set_organization_api") and _host._organization_api != null:
			player.set_organization_api(_host._organization_api)
		# 让 CameraRig 跟随玩家
		if _host.camera_rig != null and _host.camera_rig.has_method("set_follow_target"):
			_host.camera_rig.set_follow_target(player)
		# 进入即对准玩家（水平居中；1/4 跟随机制下不 snap 会在触发线偏移）
		if _host.camera_rig != null and _host.camera_rig.has_method("snap_to_follow_target"):
			_host.camera_rig.snap_to_follow_target()
		# 仅初始加载时 spawn 村庄仓库、土路资源与 NPC（出生村专属）。
		# 地图可通过 supports_village_facilities()=false 声明无 2D 村庄设施
		# （HD-2D 主街：树/矿走自然物卡+资源点，无运营仓库/工位，NPC 暂不开）。
		var has_facilities: bool = (not map.has_method("supports_village_facilities")) \
				or map.supports_village_facilities()
		if not _host._initial_map_loaded:
			_host._initial_map_loaded = true
			# 村民 NPC 与 2D 建筑设施分开门控：HD-2D 主街无 2D 设施
			# （仓库/程序化资源点跳过）但要有人劳作（伐木/采矿/铁匠铁砧）
			var wants_npcs: bool = has_facilities \
					or (map.has_method("wants_villager_npcs") and map.wants_villager_npcs())
			if has_facilities:
				await _host._world_sub_phase("村庄设施")
				# 预置村庄仓库（搬运系统取货点，放在出生点右侧土路区）
				_host._worldgen.spawn_initial_warehouse()
				# 阶段 F：村庄土路区（出生点±40格）+ 程序化生成自然资源点（土路外，含负坐标侧）
				var spawn_cell: int = int(_host.PLAYER_SPAWN_X / 32.0)
				var safe_radius: int = 40  # 出生点±40格内为村庄土路区
				if map.has_method("set_dirt_road_range"):
					map.set_dirt_road_range(spawn_cell - safe_radius, spawn_cell + safe_radius)
				if map.has_method("generate_resource_nodes_chunked"):
					var map_left_cell: int = int(float(map.get("map_left")) / 32.0) if "map_left" in map else 0
					var map_right_cell: int = int(float(map.get("map_right")) / 32.0) if "map_right" in map else 256
					# 全地图生成，生成器内部会跳过土路 cell，保证硬化路面不长资源。
					# 分块版：每积满时间预算让一帧——~154 个资源点的实例化与首绘因此
					# 摊到多帧，加载屏不再在该子阶段有一段数秒的整屏定格；副条随
					# 放置进度推进（「布置资源点 n/m」）。
					await map.generate_resource_nodes_chunked(
							map_left_cell, map_right_cell, 0.65, _host._world_sub_phase_resources)
				elif map.has_method("generate_resource_nodes"):
					var fb_left_cell: int = int(float(map.get("map_left")) / 32.0) if "map_left" in map else 0
					var fb_right_cell: int = int(float(map.get("map_right")) / 32.0) if "map_right" in map else 256
					map.generate_resource_nodes(fb_left_cell, fb_right_cell, 0.65)
			if wants_npcs:
				await _host._world_sub_phase("村民")
				await _host._worldgen.spawn_npcs(map, spawn_y, _host._world_sub_progress)
			# 重新设置相机/小地图边界（与设施无关，任何地图都要）
			if _host.camera_rig != null and _host.camera_rig.has_method("set_map_bounds"):
				_host.camera_rig.set_map_bounds(map.map_left, map.map_right)
			if _host._minimap != null and _host._minimap.has_method("set_map_info"):
				_host._minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
		# 跨图携带：spawn 随行编队成员并重建编队（带队出征）
		_spawn_travel_followers(map, player, spawn_y)
		# 战场图（battlefield，HD-2D 城郊战场）：进图不再自动刷敌开战（出征与
		# 领地架构 §4.3）；dev 验证走 tests/dev/verify_battle.gd 直达调
		# InitialContent.spawn_battlefield_enemies 组织遭遇战。
		# 切到 EXPLORE 模式激活 handler（此时实体已就绪，不会触发"未找到可附身实体"警告）
	if _host.input_dispatcher and _host.input_dispatcher.has_method("set_mode"):
		_host.input_dispatcher.set_mode(PlayerControlAPI.Mode.EXPLORE)
	# F6 步行旅行（总体设计 §5.10 E5）：道路场景出口按队列状态刷新；进出聚落 = 队列终点/回退
	_consume_walk_state(map_id, map_type)
	# 注册调试绘制器
	_host._bootstrap.register_debug_drawers()
	# 世界就绪：淡出加载覆盖（玩家已生成、相机已跟随）
	_host._boot_world_phase = false
	if _host._world_loading_overlay != null and _host._world_loading_overlay.has_method("hide_loading"):
		_host._world_loading_overlay.hide_loading()


# ─────────────────────────────── 步行旅行（F6/E5，总体设计 §5.10）───────────────────────────────

## 步行状态消费（每次 map_loaded 调用）：
## - 道路场景：校正 walk_index + 按队列位置刷新左右出口（register_map_exit，
##   ChunkTrigger target 留空走出口配置——同一场景正向/反向出去目标不同）
## - 聚落场景：命中终点（步行完成进城）或出发聚落（中途折返）→ 清队列
func _consume_walk_state(map_id: String, map_type: int) -> void:
	if WorldState == null:
		return
	if map_type == WorldAPI.MapType.ROAD:
		if WorldState.walk_legs.is_empty():
			return  # 非步行上下文（防御；存档已跳过 road 场景，读档不会落此处）
		var index := -1
		for i in WorldState.walk_legs.size():
			if str(WorldState.walk_legs[i].get("road_id", "")) == map_id:
				index = i
				break
		if index < 0:
			WorldState.reset_walk()
			return
		WorldState.walk_index = index
		# 左出口：第一段 → 回出发聚落；否则 → 上一段道路（均从其 RIGHT 侧进入）
		var left_target: String = WorldState.walk_origin_map_id if index == 0 \
				else str(WorldState.walk_legs[index - 1].get("road_id", ""))
		# 右出口：最后一段 → 进终点聚落；否则 → 下一段道路（均从其 LEFT 侧进入）
		var right_target: String = WorldState.walk_target_map_id if index == WorldState.walk_legs.size() - 1 \
				else str(WorldState.walk_legs[index + 1].get("road_id", ""))
		if not left_target.is_empty():
			_host.scene_loader.register_map_exit(map_id, WorldAPI.EntrySide.LEFT, left_target, WorldAPI.EntrySide.RIGHT)
		if not right_target.is_empty():
			_host.scene_loader.register_map_exit(map_id, WorldAPI.EntrySide.RIGHT, right_target, WorldAPI.EntrySide.LEFT)
	elif WorldState.is_walking() \
			and (map_id == WorldState.walk_target_map_id or map_id == WorldState.walk_origin_map_id):
		WorldState.reset_walk()  # 进城（终点）或折返回出发聚落：步行结束
