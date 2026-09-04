extends Node
## 火柴人交互控制器 —— 玩家按 E 交互 + 交互提示弹窗。
##
## 职责：
## - 查找当前可交互目标（工地 / 仓库 / 资源点）并返回提示文字
## - 玩家按 E 执行交互（交付材料 / 敲击建造 / 取放材料 / 采集）
## - 交互提示弹窗（挂到地图前景层，跟随目标建筑显示）
##
## 由 StickmanEntity._ready 挂载为 InteractionController 子节点并调用 setup(entity)，
## 由实体 _unhandled_input / _physics_process 驱动。

var _entity: Node2D = null

## 交互 X 范围：建筑左右各内缩 1 格（16 格建筑 → 角色需在中间 14 格内）
const INTERACT_CELL_INSET: float = 32.0
## 交互垂直范围外延容忍（px）
const INTERACT_VERT_TOL: float = 40.0
## 工地主体高度（与 ConstructionProject._create_barrier 默认障碍高一致）
const PROJECT_BODY_HEIGHT: float = 390.0

## 采集判定范围（与资源点中心的 X/Y 距离，px；地面带宽 3 格内可采）
const HARVEST_X_RANGE: float = 72.0
const HARVEST_Y_RANGE: float = 96.0
## 单次采集量（一次敲击动作的产出）
const HARVEST_PER_ACTION: int = 20
## 手动采集入库的 region（与开局资源、建造扣减同账）
const HARVEST_REGION: String = "test_region"

## ResourcesApi 惰性缓存（挂 GameRoot 下，名字固定；经模块 API 入库，不直连内部）
var _resources_api_cache: Node = null


func setup(entity: Node2D) -> void:
	_entity = entity


# ─────────────────────────────── 玩家交互（按E）────────────────────────────────

## 玩家附身时按E：仓库取放材料、工地交付/建造、资源点采集。
func try_interact() -> void:
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		return
	var target = info.get("target", null)
	if target == null:
		return
	match String(info.get("kind", "")):
		"project":
			var project: RefCounted = target as RefCounted
			if _entity.is_carrying():
				project.deliver_material()
				_entity.set_carrying(false)
			elif not project.needs_material():
				# 敲击一次：推进建造进度 + 播放 build 动画
				var per_hit: float = project.total_work / 8.0
				project.add_build_progress(per_hit)
				_entity.set_action_anim("build")
				_entity.set_player_build_timer(1.8)
		"warehouse":
			if _entity.is_carrying():
				# 扔回材料到仓库
				_entity.set_carrying(false)
			else:
				_entity.set_carrying(true)
		"resource":
			_try_harvest_resource_node(target as Node2D)


## 按住 E 的连续交互（采集手感）：动作锁解除后自动续作，由实体物理帧驱动。
## 单次按下仍走 try_interact（_unhandled_input），本方法只负责"按住"的续采。
func try_hold_interact() -> void:
	if not Input.is_key_pressed(KEY_E):
		return
	# 敲击动作锁期间不重复触发（1.8s 一拍，与单次交互同节奏）
	if float(_entity.get("_player_build_timer")) > 0.0:
		return
	try_interact()


## 对资源点执行一次采集：harvest 扣储量 → 经 ResourcesApi 入库 → 播放敲击动作。
func _try_harvest_resource_node(rn: Node2D) -> void:
	if rn == null or not is_instance_valid(rn) or not rn.has_method("harvest"):
		return
	var gained: int = rn.harvest(HARVEST_PER_ACTION)
	if gained <= 0:
		return
	var api: Node = _get_resources_api()
	if api != null and api.has_method("produce"):
		api.produce(String(rn.get_resource_id()), gained, HARVEST_REGION, "手动采集")
	_entity.set_action_anim("build")
	_entity.set_player_build_timer(1.8)


## 惰性获取 ResourcesApi（GameRoot 下具名节点；采集入库必须走模块 API）
func _get_resources_api() -> Node:
	if _resources_api_cache != null and is_instance_valid(_resources_api_cache):
		return _resources_api_cache
	var scene_root: Node = _entity.get_tree().current_scene
	if scene_root != null:
		_resources_api_cache = scene_root.find_child("ResourcesApi", true, false)
	return _resources_api_cache


## 找采集范围内的最近资源点（resource_node 组全局扫描，地图内节点数 ~几十，开销可忽略）
func _find_nearest_resource_node() -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	for node in _entity.get_tree().get_nodes_in_group("resource_node"):
		var rn := node as Node2D
		if rn == null or not is_instance_valid(rn) or not rn.is_inside_tree():
			continue
		var dx: float = absf(rn.global_position.x - _entity.global_position.x)
		var dy: float = absf(rn.global_position.y - _entity.global_position.y)
		if dx > HARVEST_X_RANGE or dy > HARVEST_Y_RANGE:
			continue
		if dx + dy < best_dist:
			best_dist = dx + dy
			best = rn
	return best


# ─────────────────────────────── 交互目标检测 ────────────────────────────────

## 从建筑 PassageBarrier CollisionShape2D 读取真实世界边界。
## 返回 {left, right, center, top, bottom} 或回退到 width*32 估算。
func _get_building_barrier_bounds(building: Node2D) -> Dictionary:
	var pb: Node = building.get_node_or_null("PassageBarrier") if building.has_method("get_node_or_null") else null
	if pb != null:
		for child in pb.get_children():
			if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
				var cs: CollisionShape2D = child as CollisionShape2D
				var s: RectangleShape2D = (cs.shape as RectangleShape2D)
				var cx: float = cs.global_position.x
				var cy: float = cs.global_position.y
				return {
					"left": cx - s.size.x * 0.5, "right": cx + s.size.x * 0.5, "center": cx,
					"top": cy - s.size.y * 0.5, "bottom": cy + s.size.y * 0.5,
				}
	# 回退：用 width 属性估算（垂直按基线向上 PROJECT_BODY_HEIGHT）
	var w: int = int(building.get("width")) if "width" in building else 2
	var left_x: float = building.global_position.x
	var map: Node2D = _entity.get_map()
	var ground_y: float = float(map.get("ground_y") if map != null and "ground_y" in map else 810.0)
	var baseline_offset: float = float(map.get("building_baseline_offset") if map != null and "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	return {
		"left": left_x, "right": left_x + float(w) * 32.0, "center": left_x + float(w) * 16.0,
		"top": baseline - PROJECT_BODY_HEIGHT, "bottom": baseline,
	}


## 实体 X 是否位于建筑横向中间 (width-2) 格区间内（左右各内缩 1 格；宽度不足时退化为整体）
func _is_x_in_building_zone(zone_left: float, zone_right: float) -> bool:
	var zl: float = zone_left + INTERACT_CELL_INSET
	var zr: float = zone_right - INTERACT_CELL_INSET
	if zr <= zl:
		zl = zone_left
		zr = zone_right
	return _entity.global_position.x >= zl and _entity.global_position.x <= zr


## 实体 Y 是否在建筑垂直范围（上下各外延 INTERACT_VERT_TOL）内
func _is_y_in_building_zone(top: float, bottom: float) -> bool:
	return _entity.global_position.y >= top - INTERACT_VERT_TOL and _entity.global_position.y <= bottom + INTERACT_VERT_TOL


## 检测实体是否在工地交互范围内（横向中间 (width-2) 格 + 垂直在主体范围内）。
func _is_near_project(project: RefCounted) -> bool:
	var left_x: float = float(project.cell_x) * 32.0
	var right_x: float = left_x + float(project.width) * 32.0
	if not _is_x_in_building_zone(left_x, right_x):
		return false
	var map: Node2D = _entity.get_map()
	var ground_y: float = float(map.get("ground_y") if map != null and "ground_y" in map else 810.0)
	var baseline_offset: float = float(map.get("building_baseline_offset") if map != null and "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	return _is_y_in_building_zone(baseline - PROJECT_BODY_HEIGHT, baseline)


## 检测实体是否在建筑 PassageBarrier 交互范围内（横向中间 (width-2) 格 + 垂直在范围内）。
func _is_near_building(building: Node2D) -> bool:
	var bounds: Dictionary = _get_building_barrier_bounds(building)
	if not _is_x_in_building_zone(float(bounds.left), float(bounds.right)):
		return false
	return _is_y_in_building_zone(float(bounds.top), float(bounds.bottom))


## 查找当前可交互目标及提示文字。返回 {target, kind, hint, center_x, hint_y} 或空。
## 优先级：工地 > 仓库 > 资源点（工地/仓库依赖 ConstructionApi，资源点独立可用）
func _find_interact_target() -> Dictionary:
	if _entity.get_construction_manager() != null:
		# 优先：工地
		var project: RefCounted = _entity.get_construction_manager().get_nearest_project(_entity.global_position)
		if project != null and _is_near_project(project):
			var left_x: float = float(project.cell_x) * 32.0
			var right_x: float = left_x + float(project.width) * 32.0
			var cx: float = (left_x + right_x) * 0.5
			var hint: String = ""
			if _entity.is_carrying():
				hint = "按E交付材料"
			elif project.needs_material():
				hint = "材料不足，等待搬运"
			else:
				hint = "按E敲击建造"
			return {"target": project, "kind": "project", "hint": hint, "center_x": cx, "hint_y": -1.0}
		# 仓库
		var warehouse: Node2D = _entity.get_construction_manager().get_nearest_warehouse(_entity.global_position)
		if warehouse != null and _is_near_building(warehouse):
			var bounds: Dictionary = _get_building_barrier_bounds(warehouse)
			var hint: String = ""
			if _entity.is_carrying():
				hint = "按E放回材料"
			else:
				hint = "按E拿起建材"
			return {"target": warehouse, "kind": "warehouse", "hint": hint, "center_x": float(bounds.center), "hint_y": -1.0}
	# 资源点（采集）
	var rn: Node2D = _find_nearest_resource_node()
	if rn != null:
		var hint: String = "按E采集%s（剩 %d）" % [rn.get_display_name(), rn.amount]
		return {"target": rn, "kind": "resource", "hint": hint,
				"center_x": rn.global_position.x, "hint_y": rn.global_position.y - 72.0}
	return {}


# ─────────────────────────────── 交互提示弹窗 ────────────────────────────────

## 交互提示节点（Node2D 容器，挂到地图前景层，跟随目标建筑显示）
var _interact_hint_node: Node2D = null
var _interact_hint_label: Label = null

## 确保交互提示节点存在，挂到地图前景层（z_index=10，在建筑之上）。
func _ensure_interact_hint() -> void:
	if _interact_hint_node != null and is_instance_valid(_interact_hint_node):
		return
	var map: Node2D = _entity.get_map()
	if map == null:
		return
	_interact_hint_node = Node2D.new()
	_interact_hint_node.name = "InteractHint"
	_interact_hint_node.visible = false
	_interact_hint_node.z_index = WorldZ.OVERLAY_HINT
	# 挂到 foreground_layer（z_index=10），确保在建筑之上
	var layer: Node2D = map.get("foreground_layer") if "foreground_layer" in map else null
	if layer != null:
		layer.add_child(_interact_hint_node)
	else:
		map.add_child(_interact_hint_node)
	_interact_hint_label = Label.new()
	_interact_hint_label.add_theme_font_size_override("font_size", 14)
	_interact_hint_label.position = Vector2(-100, -20)
	_interact_hint_label.size = Vector2(200, 24)
	_interact_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 暗色圆角背景
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.8)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.border_width_bottom = 1
	style.border_width_top = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_color = Color(1, 1, 1, 0.25)
	_interact_hint_label.add_theme_stylebox_override("normal", style)
	_interact_hint_node.add_child(_interact_hint_label)


## 隐藏交互提示。
func _hide_interact_hint() -> void:
	if _interact_hint_node != null and is_instance_valid(_interact_hint_node):
		_interact_hint_node.visible = false


## 更新交互提示（玩家附身时，靠近仓库/工地/资源点在目标上方显示弹窗）。
## 由实体 _physics_process 每帧调用。
func update_hint() -> void:
	if not _entity.is_possessed() or _entity.get_map() == null:
		_hide_interact_hint()
		return
	_ensure_interact_hint()
	if _interact_hint_node == null:
		return
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		_hide_interact_hint()
		return
	# 弹窗位置：资源点在节点上方（hint_y），建筑沿用地面线上方固定高度
	var hint_y: float = float(info.get("hint_y", -1.0))
	if hint_y < 0.0:
		var map: Node2D = _entity.get_map()
		var ground_y: float = map.get("ground_y") if map != null and "ground_y" in map else 810.0
		hint_y = ground_y - 280.0
	_interact_hint_node.global_position = Vector2(float(info.center_x), hint_y)
	_interact_hint_label.text = String(info.hint)
	_interact_hint_node.visible = true
