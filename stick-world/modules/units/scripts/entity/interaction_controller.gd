extends Node
## 火柴人交互控制器 —— 玩家按 E 交互 + 交互提示弹窗。
##
## 职责：
## - 查找当前可交互目标（工地 / 仓库）并返回提示文字
## - 玩家按 E 执行交互（交付材料 / 敲击建造 / 取放材料）
## - 交互提示弹窗（挂到地图前景层，跟随目标建筑显示）
##
## 由 StickmanEntity._ready 挂载为 InteractionController 子节点并调用 setup(entity)，
## 由实体 _unhandled_input / _physics_process 驱动。

var _entity: Node2D = null


func setup(entity: Node2D) -> void:
	_entity = entity


# ─────────────────────────────── 玩家交互（按E）────────────────────────────────

## 玩家附身时按E：在仓库附近取材料，在工地附近交付/建造。
func try_interact() -> void:
	if _entity._construction_manager == null:
		return
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		return
	var target = info.get("target", null)
	if target == null:
		return
	# 工地交互
	if target is RefCounted:
		var project: RefCounted = target as RefCounted
		if _entity._carrying:
			project.deliver_material()
			_entity.set_carrying(false)
		elif not project.needs_material():
			# 敲击一次：推进建造进度 + 播放 build 动画
			var per_hit: float = project.total_work / 8.0
			project.add_build_progress(per_hit)
			_entity.set_action_anim("build")
			_entity._player_build_timer = 1.8
	# 仓库交互
	elif target is Node2D:
		if _entity._carrying:
			# 扔回材料到仓库
			_entity.set_carrying(false)
		else:
			_entity.set_carrying(true)


# ─────────────────────────────── 交互目标检测 ────────────────────────────────

## 从建筑 PassageBarrier CollisionShape2D 读取真实世界边界。
## 返回 {left, right, center} 或回退到 width*32 估算。
func _get_building_barrier_bounds(building: Node2D) -> Dictionary:
	var pb: Node = building.get_node_or_null("PassageBarrier") if building.has_method("get_node_or_null") else null
	if pb != null:
		for child in pb.get_children():
			if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
				var cs: CollisionShape2D = child as CollisionShape2D
				var s: RectangleShape2D = (cs.shape as RectangleShape2D)
				var cx: float = cs.global_position.x
				return {"left": cx - s.size.x * 0.5, "right": cx + s.size.x * 0.5, "center": cx}
	# 回退：用 width 属性估算
	var w: int = int(building.get("width")) if "width" in building else 2
	var left_x: float = building.global_position.x
	return {"left": left_x, "right": left_x + float(w) * 32.0, "center": left_x + float(w) * 16.0}


## 检测实体 X 是否在工地建筑范围外延 margin 内。
func _is_near_project(project: RefCounted, margin: float = 80.0) -> bool:
	var left_x: float = float(project.cell_x) * 32.0
	var right_x: float = left_x + float(project.width) * 32.0
	return _entity.global_position.x >= left_x - margin and _entity.global_position.x <= right_x + margin


## 检测实体 X 是否在建筑 PassageBarrier 范围外延 margin 内。
func _is_near_building(building: Node2D, margin: float = 80.0) -> bool:
	var bounds: Dictionary = _get_building_barrier_bounds(building)
	return _entity.global_position.x >= float(bounds.left) - margin and _entity.global_position.x <= float(bounds.right) + margin


## 查找当前可交互目标及提示文字。返回 {target, hint, center_x} 或空。
func _find_interact_target() -> Dictionary:
	if _entity._construction_manager == null:
		return {}
	# 优先：工地
	var project: RefCounted = _entity._construction_manager.get_nearest_project(_entity.global_position)
	if project != null and _is_near_project(project):
		var left_x: float = float(project.cell_x) * 32.0
		var right_x: float = left_x + float(project.width) * 32.0
		var cx: float = (left_x + right_x) * 0.5
		var hint: String = ""
		if _entity._carrying:
			hint = "按E交付材料"
		elif project.needs_material():
			hint = "材料不足，等待搬运"
		else:
			hint = "按E敲击建造"
		return {"target": project, "hint": hint, "center_x": cx}
	# 仓库
	var warehouse: Node2D = _entity._construction_manager.get_nearest_warehouse(_entity.global_position)
	if warehouse != null and _is_near_building(warehouse):
		var bounds: Dictionary = _get_building_barrier_bounds(warehouse)
		var hint: String = ""
		if _entity._carrying:
			hint = "按E放回材料"
		else:
			hint = "按E拿起建材"
		return {"target": warehouse, "hint": hint, "center_x": float(bounds.center)}
	return {}


# ─────────────────────────────── 交互提示弹窗 ────────────────────────────────

## 交互提示节点（Node2D 容器，挂到地图前景层，跟随目标建筑显示）
var _interact_hint_node: Node2D = null
var _interact_hint_label: Label = null

## 确保交互提示节点存在，挂到地图前景层（z_index=10，在建筑之上）。
func _ensure_interact_hint() -> void:
	if _interact_hint_node != null and is_instance_valid(_interact_hint_node):
		return
	if _entity._map_ref == null:
		return
	_interact_hint_node = Node2D.new()
	_interact_hint_node.name = "InteractHint"
	_interact_hint_node.visible = false
	_interact_hint_node.z_index = 20
	# 挂到 foreground_layer（z_index=10），确保在建筑之上
	var layer: Node2D = _entity._map_ref.get("foreground_layer") if "foreground_layer" in _entity._map_ref else null
	if layer != null:
		layer.add_child(_interact_hint_node)
	else:
		_entity._map_ref.add_child(_interact_hint_node)
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


## 更新交互提示（玩家附身时，靠近仓库/工地在建筑上方显示弹窗）。
## 由实体 _physics_process 每帧调用。
func update_hint() -> void:
	if not _entity.possessed or _entity._construction_manager == null or _entity._map_ref == null:
		_hide_interact_hint()
		return
	_ensure_interact_hint()
	if _interact_hint_node == null:
		return
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		_hide_interact_hint()
		return
	# 弹窗显示在目标建筑上方
	var ground_y: float = _entity._map_ref.get("ground_y") if "ground_y" in _entity._map_ref else 810.0
	_interact_hint_node.global_position = Vector2(float(info.center_x), ground_y - 280.0)
	_interact_hint_label.text = String(info.hint)
	_interact_hint_node.visible = true
