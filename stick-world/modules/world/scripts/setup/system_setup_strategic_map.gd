extends RefCounted
## SystemSetup 战略图装配助手 —— 承接宿主分帧步骤表中战略图域各步骤的函数体
## （小地图 / 战略图 L1·L3 / 地图缩略窗 / 边界检测）与 Tab 三态、M 键 L3、
## 地图旅行等战略图运行时交互逻辑。
##
## 纪律：
## - Tab 三态枚举与状态（TabMapState/_tab_state/_l1_thumbnail）留在宿主，
##   本助手经 _host 回引读写，不另立状态；
## - 跨模块 preload 属 composition root 豁免、全部留在宿主，此处经 _host 取用；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。

var _host: Node  ## SystemSetup 宿主（无 class_name，动态回引）


func bind(host: Node) -> void:
	_host = host


# ─────────────────────────────── 小地图装配（§15 阶段 0.6）────────────────────────────────

## 创建顶部小地图区（Minimap + L1 缩略窗）并挂到 UIRoot。详见 §10.4。
## Minimap（本城市俯视）**常驻恒显**——Tab 三态不影响（创始人反馈）；
## L1 缩略窗也常驻（创始人反馈：Tab 地图默认展开），初始隐藏，由步骤表
## 后段的「地图缩略窗」步骤喂完数据后显示。
func _setup_minimap() -> void:
	if _host._root.ui_root == null:
		return
	var mm := UIKit.widget(_host._MinimapScript, "Minimap")
	_host._root.ui_root.add_to_slot("HudOverlay", mm)
	# 定位归 zone（顶部中央堆叠区，见 hud_zone_layout.gd）；先落位再 setup，
	# 让 L1 缩略窗读到最终 rect
	_host._root.ui_root.place_in_zone(&"top_center", mm)
	_host._root._minimap = mm
	if mm.has_method("setup"):
		mm.setup(_host._root)
	mm.visible = true
	# L1 世界缩略窗（贴 Minimap 右侧并列；点击 = 切到 L1 大图）
	_host._l1_thumbnail = UIKit.widget(_host._L1ThumbnailScript, "L1Thumbnail")
	_host._root.ui_root.add_to_slot("HudOverlay", _host._l1_thumbnail)
	if _host._l1_thumbnail.has_signal("open_l1_requested"):
		_host._l1_thumbnail.open_l1_requested.connect(_on_l1_thumbnail_clicked)
	if _host._l1_thumbnail.has_method("place_right_of_minimap"):
		# deferred：top_center 已改 stack 模式，Minimap 的 rect 由 deferred 重排
		# 写入，立即调用会读到旧 rect（0,0 起）；call_deferred 排在重排之后必就绪
		_host._l1_thumbnail.call_deferred("place_right_of_minimap", mm)
	_host._l1_thumbnail.visible = false


# ─────────────────────────────── 阶段 F：边界检测出城系统 ────────────────────────────────

func _setup_boundary_detector() -> void:
	# 实例化边界检测器
	_host._root._boundary_detector = Node.new()
	_host._root._boundary_detector.set_script(_host._MapBoundaryDetectorScript)
	_host._root._boundary_detector.name = "MapBoundaryDetector"
	_host._root.add_child(_host._root._boundary_detector)
	# 注入 GameRoot（替代根节点遍历反查）
	if _host._root._boundary_detector.has_method("setup"):
		_host._root._boundary_detector.setup(_host._root)
	# 战略图初始化已进装配步骤表（「战略图 L1/L3」两步分帧，创始人反馈 Tab 地图
	# 默认展开）；此处仍留 _ensure_strategic_maps 兜底——步骤表未跑到的早开路径
	# （Tab / M / 边界提示）首次触发时补初始化，见 _open_strategic_map。
	_host._root._boundary_detector.open_world_map_requested.connect(_open_strategic_map)
	# 战略图关闭 -> 恢复场景图输入（api.close_strategic_map / ESC 都发此信号）
	if EventBus != null:
		EventBus.strategic_map_closed.connect(_on_strategic_map_closed)
	# F2/C1 玩家位置动态接线（总体设计 §5.6）：每次场景图加载 → world_map api
	# 反查所在聚落，更新图钉 + 当前地块描边（跨 L1 的 region/Tab 跟随留 D 期）
	if _host._root.scene_loader != null and _host._root.scene_loader.has_signal("map_loaded") \
			and not _host._root.scene_loader.map_loaded.is_connected(_on_player_map_changed):
		_host._root.scene_loader.map_loaded.connect(_on_player_map_changed)


## 玩家所在场景图变化（F2/C1）：经 world_map api 反查所在聚落。
## api 未初始化（战略图未装配）时跳过——图钉默认锚出生聚落，语义仍正确。
func _on_player_map_changed(map_id: String, _map_type: int) -> void:
	if _host._root._strategic_map == null:
		return
	var content: Node = _host._root._strategic_map.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("is_initialized") and api.is_initialized() \
			and api.has_method("set_player_map"):
		api.set_player_map(map_id)
	# 缩略窗常驻（创始人反馈）：随场景图切换重喂，保当前位置标记新鲜
	_feed_thumbnail_data()


## 战略图初始化（幂等兜底）：常规路径由装配步骤表「战略图 L1/L3」分帧完成，
## 早于步骤表的打开路径（Tab / M / 边界提示）经此处补齐。
## 战略图 Content 常驻隐藏，其 instantiate + 数据加载（l1/l3 JSON + 索引图）耗时巨大，
## 已拆进步骤表借加载屏分帧消化（当年整段同步曾致启动卡 10s+）。
func _ensure_strategic_maps() -> void:
	if _host._root._strategic_map == null:
		_setup_l1_strategic_map()
	if _host._root._strategic_map_l3 == null:
		_setup_l3_strategic_map()


## 装配 L1 战略图（Tab / 边界提示打开的世界地图）
func _setup_l1_strategic_map() -> void:
	_host._root._strategic_map = _host._StrategicMapScene.instantiate()
	_host._root._strategic_map.name = "StrategicMap"
	_host._root.add_child(_host._root._strategic_map)
	# 初始化 L1 世界数据（Api 在 Content 子节点下）
	var content: Node = _host._root._strategic_map.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("initialize"):
		api.initialize(
			"res://config/strategic_map/l1_world.json",
			"res://config/strategic_map"
		)


## 装配 L3 大世界战略图（M 键视图）
func _setup_l3_strategic_map() -> void:
	_host._root._strategic_map_l3 = _host._StrategicMapL3Scene.instantiate()
	_host._root._strategic_map_l3.name = "StrategicMapL3"
	_host._root.add_child(_host._root._strategic_map_l3)
	# 初始化 L3 数据（渲染器持有）
	var content: Node = _host._root._strategic_map_l3.get_node_or_null("Content")
	var renderer: Node = content.get_node_or_null("L3MapRenderer") if content != null else null
	if renderer != null and renderer.has_method("set_data"):
		var data := L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json",
			"res://config/strategic_map"
		)
		renderer.set_data(data)
	# 装配 L2 下钻视图（L3 单击地区 -> L2 详细地图）
	var l2: Node = _host._StrategicMapL2Scene.instantiate()
	l2.name = "StrategicMapL2"
	_host._root.add_child(l2)
	var l2_content: Node = l2.get_node_or_null("Content")
	if l2_content != null and content != null and content.has_method("set_l2_view") \
			and l2_content.has_method("open"):
		content.call("set_l2_view", l2_content)
	# 装配 L2 -> L1 下钻（L2 点击 L1 地块打开对应老 L1 的 Tab 视图；L1 controller = strategic_map.tscn 的 Content）
	var l1_content: Node = _host._root._strategic_map.get_node_or_null("Content") if _host._root._strategic_map != null else null
	if l2_content != null and l1_content != null and l2_content.has_method("set_l1_view"):
		l2_content.call("set_l1_view", l1_content)


func _toggle_l3_strategic_map() -> void:
	_ensure_strategic_maps()
	if _host._root._strategic_map_l3 == null:
		return
	var content: Node = _host._root._strategic_map_l3.get_node_or_null("Content")
	if content == null or not content.has_method("open"):
		return
	if content.visible:
		content.close()
		_pause_scene_input(false)
	else:
		# 打开 L3 前先关掉 L1（互斥）
		var l1_content: Node = _host._root._strategic_map.get_node_or_null("Content") if _host._root._strategic_map != null else null
		if l1_content != null and l1_content.visible and l1_content.has_method("close"):
			l1_content.close()
		content.open()
		_pause_scene_input(true)


## Tab / 边界触发入口（Minimap 常驻不受 Tab 影响；L1 缩略窗也常驻——创始人反馈）。
## full_map=true（边界自动触发，如顶边界持续推进）：直接开 L1 大图（保留原"出城看图"语义）；
## full_map=false（玩家按 Tab）：缩略窗态开 L1 大图 / 大图态关闭回缩略窗（互切）。
## M（L3/L2）会话期间忽略：新开视图 = 玩家所见的互斥原则——否则状态机在 L3 海洋层下
## 悄悄切态（L1 被盖住打开），M 一关 L1 意外弹出。
func _open_strategic_map(full_map: bool) -> void:
	if _is_l3_session_active():
		return
	_ensure_strategic_maps()
	if full_map:
		if _host._tab_state != _host.TabMapState.FULL_L1:
			_set_l1_thumbnail_visible(false)
			_open_l1_full_map()
		return
	# 三态分派用 if/elif：TabMapState 经宿主实例回引（_host.TabMapState）不是
	# 编译期常量，进不了 match 模式（原文件类内直引 TabMapState 才可用 match）
	var state: int = _host._tab_state
	if state == _host.TabMapState.HIDDEN:
		_feed_thumbnail_data()
		_set_l1_thumbnail_visible(true)
		_host._tab_state = _host.TabMapState.TOP_MINIMAPS
	elif state == _host.TabMapState.TOP_MINIMAPS:
		_set_l1_thumbnail_visible(false)
		_open_l1_full_map()
	elif state == _host.TabMapState.FULL_L1:
		_close_l1_full_map()


## M 会话是否激活（L3 可见，或下钻中的 L2 可见——L3 隐藏但 _l2_active 保留）
func _is_l3_session_active() -> bool:
	if _host._root._strategic_map_l3 == null:
		return false
	var l3_content: Node = _host._root._strategic_map_l3.get_node_or_null("Content")
	if l3_content == null:
		return false
	if l3_content.visible:
		return true
	var l2_active: Variant = l3_content.get("_l2_active")
	return l2_active != null and bool(l2_active) and l3_content.l2_view != null \
			and l3_content.l2_view.visible


## L1 缩略窗显隐（仅开 L1 大图时收起、关闭即回显；Minimap/缩略窗双常驻——创始人反馈）
func _set_l1_thumbnail_visible(v: bool) -> void:
	if _host._l1_thumbnail != null:
		_host._l1_thumbnail.visible = v


## 喂 L1 缩略窗世界数据（当前位置标记数据源）：从 L1 战略图 api 取已初始化的
## L1WorldData（ensure 后必就绪；幂等，每次进入顶部小地图态时刷新）
func _feed_thumbnail_data() -> void:
	if _host._l1_thumbnail == null or not _host._l1_thumbnail.has_method("set_map_data"):
		return
	var content: Node = _host._root._strategic_map.get_node_or_null("Content") \
			if _host._root._strategic_map != null else null
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("is_initialized") and api.is_initialized() \
			and api.has_method("get_data"):
		_host._l1_thumbnail.set_map_data(api.get_data())


## 地图缩略窗默认展开（装配步骤表「地图缩略窗」；创始人反馈：Tab 地图开局即显示）。
## 前置：战略图 L1/L3 步骤已完成初始化，此处只喂数据 + 置顶双窗态。
func _open_tab_map_default() -> void:
	if _host._l1_thumbnail == null:
		return
	_feed_thumbnail_data()
	_host._tab_state = _host.TabMapState.TOP_MINIMAPS
	_set_l1_thumbnail_visible(true)


## 打开 L1 大图（三态第三态；L1 缩略窗先收起，Minimap 常驻不动）
func _open_l1_full_map() -> void:
	if _host._root._strategic_map == null:
		return
	# 战略图是 CanvasLayer，控制器在 Content 子节点（visible 控制全层显隐）
	var content: Node = _host._root._strategic_map.get_node_or_null("Content")
	if content == null or not content.has_method("open"):
		return
	content.open()
	_pause_scene_input(true)
	_host._tab_state = _host.TabMapState.FULL_L1


## 关闭 L1 大图（close 发 strategic_map_closed → _on_strategic_map_closed 归位 HIDDEN）
func _close_l1_full_map() -> void:
	var content: Node = _host._root._strategic_map.get_node_or_null("Content") \
			if _host._root._strategic_map != null else null
	if content != null and content.visible and content.has_method("close"):
		content.close()
	else:
		_host._tab_state = _host.TabMapState.HIDDEN


## L1 缩略窗点击 = 缩略窗态 → 大图（与 Tab 第二次按下等效；Minimap 常驻不动）
func _on_l1_thumbnail_clicked() -> void:
	if _host._tab_state != _host.TabMapState.TOP_MINIMAPS:
		return
	_set_l1_thumbnail_visible(false)
	_open_l1_full_map()


func _on_strategic_map_closed() -> void:
	_pause_scene_input(false)
	# L1 大图任何路径关闭（ESC / Tab / M 互斥）都回到顶部双窗态（缩略窗常驻，
	# 创始人反馈；关闭时重喂数据刷新当前位置标记）。TOP_MINIMAPS 态下的 M 开关
	# L3 不影响（其 close 也发此信号，但此时不在 FULL_L1）
	if _host._tab_state == _host.TabMapState.FULL_L1:
		_host._tab_state = _host.TabMapState.TOP_MINIMAPS
		_feed_thumbnail_data()
		_set_l1_thumbnail_visible(true)


## 暂停/恢复场景图输入（战略图打开时场景图不响应输入）
## 方式：地图内容（WorldChunkHost）+ 相机置为 DISABLED（子树 _input/_process 全停），
## 场景图仍保持渲染（战略图透明背景悬浮其上，作背景可见）；
## 战略图（CanvasLayer 100）/UIRoot 不受影响；关闭时恢复 INHERIT
func _pause_scene_input(paused: bool) -> void:
	var mode := Node.PROCESS_MODE_INHERIT if not paused else Node.PROCESS_MODE_DISABLED
	if _host._root.world_chunk_host != null:
		_host._root.world_chunk_host.process_mode = mode
	if _host._root.camera_rig != null:
		_host._root.camera_rig.process_mode = mode
	if _host._root.scene_loader != null:
		_host._root.scene_loader.process_mode = mode


func _on_world_map_travel(target_map_id: String, entry_side: int) -> void:
	if _host._root.scene_loader != null and _host._root.scene_loader.has_method("travel_to_map"):
		_host._root.scene_loader.travel_to_map(target_map_id, WorldAPI.TravelMode.WALK, entry_side)
