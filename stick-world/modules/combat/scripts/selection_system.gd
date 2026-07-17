class_name SelectionSystem
extends Control
## 框选系统 -- BATTLE 模式下用鼠标框选/点选单位。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.3、§14.4。
##
## 交互方式：
##   - 左键拖拽：框选矩形内所有可选单位
##   - 左键单击：选中点击位置最近的单位（Shift 追加 / 切换）
##   - 右键 / ESC：清空选择
##
## 作为 InputDispatcher 的 BATTLE 模式 handler 注册（与 ExploreHandler 同构）。
## 激活时接管左键输入（set_input_as_handled 阻止 CameraRig 拖拽相机）。
##
## 信号：
##   - selection_changed(unit_ids: Array) -- 选择变化时发射（§14.4）
##   - 同时通过 EventBus.selection_changed 广播

# PlayerControlAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 常量 ────────────────────────────────
## 拖拽触发阈值（屏幕像素），小于此值视为单击
const DRAG_THRESHOLD: float = 8.0
## 单击选中的世界坐标容差（像素）
const CLICK_TOLERANCE: float = 45.0
## 选中框边框颜色
const BOX_BORDER_COLOR: Color = Color(0.4, 0.85, 1.0, 0.9)
## 选中框填充颜色
const BOX_FILL_COLOR: Color = Color(0.4, 0.85, 1.0, 0.15)
## 选中单位脚下的圆环颜色
const RING_COLOR: Color = Color(0.35, 1.0, 0.5, 0.9)
## 选中圆环半径（屏幕像素）
const RING_RADIUS: float = 30.0

# ─────────────────────────────── 信号 ────────────────────────────────
## 选择变化时发射，参数为选中单位的 instance_id 数组
signal selection_changed(unit_ids: Array)

# ─────────────────────────────── 状态 ────────────────────────────────
## 是否激活（BATTLE 模式时为 true）
var _active: bool = false
## 左键是否按下中
var _left_held: bool = false
## 是否正在拖拽（超过阈值后判定为框选）
var _dragging: bool = false
## 拖拽起始点（屏幕坐标）
var _drag_start_screen: Vector2 = Vector2.ZERO
## 当前鼠标位置（屏幕坐标）
var _drag_current_screen: Vector2 = Vector2.ZERO
## 当前选中的单位列表（StickmanEntity 数组）
var _selected_units: Array = []
## 可选阵营过滤（0 = 所有阵营，>0 = 仅该阵营）
var _selectable_faction: int = 0
## GameRoot 引用（用于查找当前地图）
var _game_root: Node = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 不拦截 UI 事件，仅通过 _unhandled_input 处理游戏世界点击
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 初始禁用输入/帧处理，等 BATTLE 模式激活再开启
	set_process_unhandled_input(false)
	set_process(false)
	call_deferred("_resolve_game_root")


func _resolve_game_root() -> void:
	var p := get_parent()
	while p != null:
		if p.has_method("get_current_map"):
			_game_root = p
			return
		p = p.get_parent()


# ─────────────────────────────── 模式回调（InputDispatcher handler 接口）────────────────────────────────

func _on_mode_activated(mode: int) -> void:
	if mode == PlayerControlAPI.Mode.BATTLE:
		_active = true
		set_process_unhandled_input(true)
		set_process(true)


func _on_mode_deactivated(mode: int) -> void:
	if mode == PlayerControlAPI.Mode.BATTLE:
		_active = false
		set_process_unhandled_input(false)
		set_process(false)
		_left_held = false
		_dragging = false
		clear_selection()
		queue_redraw()


# ─────────────────────────────── 输入处理 ────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE:
			clear_selection()
			get_viewport().set_input_as_handled()


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_left_held = true
			_dragging = false
			_drag_start_screen = event.position
			_drag_current_screen = event.position
		else:
			if _left_held:
				if _dragging:
					# 框选完成
					var world_start := _screen_to_world(_drag_start_screen)
					var world_end := _screen_to_world(_drag_current_screen)
					var rect := Rect2(world_start, world_end - world_start).abs()
					_do_box_select(rect, event.shift_pressed)
				else:
					# 单击选择
					var world_pos := _screen_to_world(event.position)
					_do_click_select(world_pos, event.shift_pressed)
				_left_held = false
				_dragging = false
				queue_redraw()
			# 消费左键事件，阻止 CameraRig 拖拽相机
			get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# 右键清空选择
		clear_selection()
		_left_held = false
		_dragging = false
		get_viewport().set_input_as_handled()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _left_held:
		return
	if not _dragging:
		# 判断是否超过拖拽阈值
		if _drag_start_screen.distance_to(event.position) >= DRAG_THRESHOLD:
			_dragging = true
	if _dragging:
		_drag_current_screen = event.position
		queue_redraw()
		get_viewport().set_input_as_handled()


# ─────────────────────────────── 选择逻辑 ────────────────────────────────

## 框选：选中世界矩形内所有可选单位。返回本次选中的单位数组。
func box_select(world_rect: Rect2, additive: bool = false) -> Array:
	return _do_box_select(world_rect, additive)


## 单击选择：选中 world_pos 附近最近的单位。返回是否选中了单位。
func click_select(world_pos: Vector2, additive: bool = false) -> bool:
	return _do_click_select(world_pos, additive)


## 显式选中指定单位列表。
func select_units(units: Array, additive: bool = false) -> void:
	_apply_selection(units, additive)


## 显式选中单个单位。
func select_unit(unit: Node, additive: bool = false) -> void:
	if additive:
		if unit not in _selected_units:
			_selected_units.append(unit)
			_emit_selection_changed()
			queue_redraw()
	else:
		_apply_selection([unit], false)


## 清空选择。
func clear_selection() -> void:
	if _selected_units.is_empty():
		return
	_selected_units.clear()
	_emit_selection_changed()
	queue_redraw()


# ─────────────────────────────── 内部选择实现 ────────────────────────────────

func _do_box_select(world_rect: Rect2, additive: bool) -> Array:
	var in_box: Array = []
	for u in _get_selectable_units():
		if world_rect.has_point(u.global_position):
			in_box.append(u)
	_apply_selection(in_box, additive)
	return in_box.duplicate()


func _do_click_select(world_pos: Vector2, additive: bool) -> bool:
	var best: Node = null
	var best_dist: float = CLICK_TOLERANCE
	for u in _get_selectable_units():
		var d: float = u.global_position.distance_to(world_pos)
		if d < best_dist:
			best_dist = d
			best = u
	if additive:
		if best != null:
			if best in _selected_units:
				_selected_units.erase(best)  # Shift+点击已选中单位 = 取消
			else:
				_selected_units.append(best)
			_emit_selection_changed()
			queue_redraw()
		return best != null
	else:
		if best != null:
			_apply_selection([best], false)
		else:
			# 点击空地：清空
			clear_selection()
		return best != null


func _apply_selection(new_units: Array, additive: bool) -> void:
	if additive:
		for u in new_units:
			if u not in _selected_units:
				_selected_units.append(u)
	else:
		_selected_units = new_units.duplicate()
	_emit_selection_changed()
	queue_redraw()


## 获取所有可选单位（当前地图上的存活 StickmanEntity，按阵营过滤）
func _get_selectable_units() -> Array:
	var map: Node2D = _get_current_map()
	if map == null or not map.has_method("get_entities"):
		return []
	var units: Array = []
	for e in map.get_entities():
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if _selectable_faction != 0:
			var fid: int = e.faction_id if "faction_id" in e else 0
			if fid != _selectable_faction:
				continue
		units.append(e)
	return units


## 死亡/释放的单位自动移除
func _process(_delta: float) -> void:
	if not _active:
		return
	if _selected_units.is_empty():
		return
	var changed: bool = false
	var i: int = _selected_units.size() - 1
	while i >= 0:
		var u: Node = _selected_units[i]
		if not is_instance_valid(u):
			_selected_units.remove_at(i)
			changed = true
		elif u.has_method("is_dead") and u.is_dead():
			_selected_units.remove_at(i)
			changed = true
		i -= 1
	if changed:
		_emit_selection_changed()
		queue_redraw()


func _emit_selection_changed() -> void:
	var ids: Array = []
	for u in _selected_units:
		if is_instance_valid(u):
			ids.append(u.get_instance_id())
	selection_changed.emit(ids)
	if EventBus != null and EventBus.has_signal("selection_changed"):
		EventBus.selection_changed.emit(ids)


# ─────────────────────────────── 坐标转换 ────────────────────────────────

## 屏幕坐标 -> 世界坐标（使用 viewport 的 canvas transform）
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	# 拖拽中的选中框
	if _dragging:
		var rect := Rect2(_drag_start_screen, _drag_current_screen - _drag_start_screen).abs()
		draw_rect(rect, BOX_FILL_COLOR, true)
		draw_rect(rect, BOX_BORDER_COLOR, false, 2.0)
	# 选中单位脚下的圆环
	if _selected_units.is_empty():
		return
	var canvas_xform: Transform2D = get_viewport().get_canvas_transform()
	for u in _selected_units:
		if not is_instance_valid(u):
			continue
		var screen_pos: Vector2 = canvas_xform * u.global_position
		# 椭圆形环（略扁，贴合地面透视）
		draw_arc(screen_pos, RING_RADIUS, 0.0, TAU, 36, RING_COLOR, 2.0)


# ─────────────────────────────── 查询 API ────────────────────────────────

func get_selected_units() -> Array:
	return _selected_units.duplicate()


func get_selected_count() -> int:
	return _selected_units.size()


func is_selected(unit: Node) -> bool:
	return unit in _selected_units


func is_active() -> bool:
	return _active


## 设置可选阵营过滤（0 = 所有阵营）
func set_selectable_faction(fid: int) -> void:
	_selectable_faction = fid
	# 过滤后清除已选中的不在阵营内的单位
	if _selectable_faction != 0:
		var i: int = _selected_units.size() - 1
		var changed: bool = false
		while i >= 0:
			var u: Node = _selected_units[i]
			var unit_fid: int = u.faction_id if (is_instance_valid(u) and "faction_id" in u) else 0
			if unit_fid != _selectable_faction:
				_selected_units.remove_at(i)
				changed = true
			i -= 1
		if changed:
			_emit_selection_changed()
			queue_redraw()


# ─────────────────────────────── 内部辅助 ────────────────────────────────

func _get_current_map() -> Node2D:
	if _game_root == null:
		_resolve_game_root()
	if _game_root == null:
		return null
	if _game_root.has_method("get_current_map"):
		return _game_root.get_current_map()
	return null
