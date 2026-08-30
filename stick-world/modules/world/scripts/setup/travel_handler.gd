extends Node
## GameRoot 传送/旅行子系统 —— 大建筑内部传送、过场动画、室内退出检查。
##
## 职责：
## - 订阅 EventBus.mega_interior_entered / mega_interior_exited / interior_exited
## - 进入/退出大建筑：校验 -> 记录返回信息 -> 过场 -> 旅行
## - 过场黑屏（TransitionOverlay）显示/隐藏
## - 玩家实体查找（供 GameRoot.get_player_entity 转发）
## - INDOOR 模式退出检查（玩家离开所有建筑后切回 EXPLORE）
##
## 由 GameRoot._ready 挂载为 TravelHandler 子节点并调用 setup(root)。

var _root: GameRoot


func setup(root: GameRoot) -> void:
	_root = root
	if not EventBus:
		return
	if EventBus.has_signal("mega_interior_entered"):
		EventBus.mega_interior_entered.connect(_on_mega_interior_entered)
	if EventBus.has_signal("mega_interior_exited"):
		EventBus.mega_interior_exited.connect(_on_mega_interior_exited)
	if EventBus.has_signal("interior_exited"):
		EventBus.interior_exited.connect(_on_interior_exited)


# ─────────────────────────────── 传送系统（§5.6）───────────────────────────────

## 进入大建筑：校验 -> 记录返回信息 -> 过场 -> 旅行
func _on_mega_interior_entered(_building_id: int, map_id: String) -> void:
	# 校验：战斗中禁止传送
	if _root.is_in_battle():
		push_warning("[GameRoot] 战斗中禁止传送进入大建筑")
		return
	# 校验：附身中禁止传送
	if _root._possession_interface != null and _root._possession_interface.has_method("get_possessed_entity"):
		var pe: Node = _root._possession_interface.get_possessed_entity()
		if pe != null and is_instance_valid(pe) and _root._possession_interface.get("_slowed_time") == true:
			push_warning("[GameRoot] 附身中禁止传送进入大建筑")
			return
	# 记录返回信息
	# 2026-08 修复：原 has_method("get") 恒真（Object.get 恒存在），改为检查真实方法
	_root._return_map_id = _root.scene_loader.current_map_id if _root.scene_loader != null and _root.scene_loader.has_method("get_current_map_id") else ""
	var player: Node2D = find_player_entity()
	if player != null and is_instance_valid(player):
		_root._return_spawn_x = player.global_position.x
	# 显示过场
	_show_transition_overlay("进入宫殿")
	# 延迟执行旅行（等过场淡入完成）
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_callback(_travel_to_interior.bind(map_id))


func _travel_to_interior(map_id: String) -> void:
	if _root.scene_loader == null or not _root.scene_loader.has_method("travel_to_map"):
		_hide_transition_overlay()
		return
	_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.TELEPORT, WorldAPI.EntrySide.LEFT)
	# 地图加载完成后隐藏过场
	var tween := create_tween()
	tween.tween_interval(0.05)
	tween.tween_callback(_hide_transition_overlay)


## 从大建筑返回
func _on_mega_interior_exited(_return_map_id_received: String) -> void:
	var target: String = String(_root._return_map_id)
	if target.is_empty():
		target = _return_map_id_received
	if target.is_empty():
		push_warning("[GameRoot] 无返回地图 ID，无法退出大建筑")
		return
	_show_transition_overlay("离开宫殿")
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_callback(_travel_back.bind(target))


func _travel_back(target: String) -> void:
	if _root.scene_loader == null or not _root.scene_loader.has_method("travel_to_map"):
		_hide_transition_overlay()
		return
	_root.scene_loader.travel_to_map(target, WorldAPI.TravelMode.TELEPORT, WorldAPI.EntrySide.LEFT)
	var tween := create_tween()
	tween.tween_interval(0.05)
	tween.tween_callback(_hide_transition_overlay)
	# 清空返回记录
	_root._return_map_id = ""
	_root._return_spawn_x = 0.0


# ─────────────────────────────── 过场黑屏 ────────────────────────────────

## 显示过场黑屏
func _show_transition_overlay(text: String) -> void:
	if _root.ui_root == null:
		return
	# 移除旧 overlay
	_hide_transition_overlay()
	var overlay := ColorRect.new()
	overlay.name = "TransitionOverlay"
	overlay.color = Color(0, 0, 0, 0)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.ui_root.add_child(overlay)
	var label := Label.new()
	label.name = "TransitionLabel"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_color_override("font_color", Color.WHITE)
	overlay.add_child(label)
	# 淡入动画
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 1.0, 0.5)


## 隐藏过场
func _hide_transition_overlay() -> void:
	if _root.ui_root == null:
		return
	var overlay: Node = _root.ui_root.get_node_or_null("TransitionOverlay")
	if overlay == null:
		return
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.0, 0.5)
	tween.tween_callback(overlay.queue_free)


# ─────────────────────────────── 玩家实体查找 ────────────────────────────────

## 查找当前玩家实体（供 GameRoot.get_player_entity 转发）
func find_player_entity() -> Node2D:
	# 装配早期（system_setup 期间 HUD 面板 setup）_root 可能尚未注入，返回空而非报错
	if _root == null:
		return null
	var map: Node2D = _root.get_current_map()
	if map == null:
		return null
	for e in map.get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


# ─────────────────────────────── 室内退出检查 ────────────────────────────────

## 某个建筑的 InteractionZone 离开 -> 检查是否所有建筑都不含玩家
func _on_interior_exited(_building_id: int) -> void:
	_check_indoor_exit()


## 遍历当前地图所有 Building，无玩家在内则退出 INDOOR 模式
func _check_indoor_exit() -> void:
	if _root.input_dispatcher == null or not _root.input_dispatcher.has_method("get_mode"):
		return
	if _root.input_dispatcher.get_mode() != PlayerControlAPI.Mode.INDOOR:
		return
	var map: Node2D = _root.get_current_map()
	if map == null:
		return
	if not _has_any_player_in_building(map):
		if _root.input_dispatcher.has_method("exit_to_explore"):
			_root.input_dispatcher.exit_to_explore()


## 递归遍历节点树，检查是否有 Building 内含玩家
func _has_any_player_in_building(node: Node) -> bool:
	if node is Building and node.has_method("is_player_inside_interaction_zone"):
		if node.is_player_inside_interaction_zone():
			return true
	for child in node.get_children():
		if _has_any_player_in_building(child):
			return true
	return false
