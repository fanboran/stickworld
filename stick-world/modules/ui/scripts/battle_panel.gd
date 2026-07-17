class_name BattlePanel
extends Control
## 战斗面板 —— BATTLE 模式下的底部 HUD。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.1、§10.2、§8.3。
## 三大区域：
##   1. 框选信息：选中单位数量/概要
##   2. 编制树：当前所有小队列表（名称、人数、排长）
##   3. 指令按钮：前进/坚守/后撤/掩体 + 编队/任命排长
##
## 由 GameRoot 在 _ready 中 set_script 装配，随后调用 setup(game_root)。
## 信号驱动更新：selection_changed / squad_created / squad_disbanded。

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _selection: Node = null
var _formation: Node = null
var _tactical: Node = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _selection_label: Label = null
var _squad_container: VBoxContainer = null
var _order_buttons: Dictionary = {}  # order_type(int) -> Button
var _create_squad_btn: Button = null
var _assign_leader_btn: Button = null
var _possess_btn: Button = null

# ─────────────────────────────── 常量 ────────────────────────────────
## 前进号令的目标偏移（向右 800px，P0 简化）
const ADVANCE_OFFSET_X: float = 800.0


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入系统引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_selection = game_root.get_selection_system() if game_root.has_method("get_selection_system") else null
	_formation = game_root.get_formation_system() if game_root.has_method("get_formation_system") else null
	_tactical = game_root.get_tactical_orders() if game_root.has_method("get_tactical_orders") else null
	_build_ui()
	_connect_signals()
	_refresh_all()


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 清空占位子节点
	for child in get_children():
		child.queue_free()
	# 根容器：水平布局，填满面板
	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 16)
	hbox.offset_left = 8
	hbox.offset_top = 4
	hbox.offset_right = -8
	hbox.offset_bottom = -4
	add_child(hbox)

	# ── 1. 框选信息 ──
	var sel_section := _create_section(hbox, "框选")
	_selection_label = Label.new()
	_selection_label.text = "选中: 0 人"
	sel_section.add_child(_selection_label)

	# 分隔线
	_add_separator(hbox)

	# ── 2. 编制树 ──
	var squad_section := _create_section(hbox, "编制")
	_squad_container = VBoxContainer.new()
	_squad_container.add_theme_constant_override("separation", 2)
	squad_section.add_child(_squad_container)
	var _no_squad_label := Label.new()
	_no_squad_label.text = "（无小队）"
	_no_squad_label.name = "NoSquadLabel"
	_squad_container.add_child(_no_squad_label)

	# 分隔线
	_add_separator(hbox)

	# ── 3. 指令按钮 ──
	var order_section := _create_section(hbox, "号令")
	var order_hbox := HBoxContainer.new()
	order_hbox.add_theme_constant_override("separation", 6)
	order_section.add_child(order_hbox)
	_create_order_button(order_hbox, "前进", 0)   # ADVANCE_ALL
	_create_order_button(order_hbox, "坚守", 2)   # HOLD_POSITION
	_create_order_button(order_hbox, "后撤", 3)   # RETREAT
	_create_order_button(order_hbox, "掩体", 4)   # TAKE_COVER

	# 分隔线
	_add_separator(hbox)

	# ── 4. 操作按钮 ──
	var action_section := _create_section(hbox, "操作")
	var action_hbox := HBoxContainer.new()
	action_hbox.add_theme_constant_override("separation", 6)
	action_section.add_child(action_hbox)
	_create_squad_btn = _create_button(action_hbox, "编队", _on_create_squad_pressed)
	_assign_leader_btn = _create_button(action_hbox, "任命排长", _on_assign_leader_pressed)

	# 分隔线
	_add_separator(hbox)

	# ── 5. 附身按钮 ──
	var possess_section := _create_section(hbox, "附身")
	var possess_hbox := HBoxContainer.new()
	possess_hbox.add_theme_constant_override("separation", 6)
	possess_section.add_child(possess_hbox)
	_possess_btn = _create_button(possess_hbox, "附身选中单位", _on_possess_pressed)


func _create_section(parent: Container, title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 11)
	title_label.modulate = Color(0.7, 0.7, 0.7)
	section.add_child(title_label)
	parent.add_child(section)
	return section


func _add_separator(parent: Container) -> void:
	var sep := VSeparator.new()
	parent.add_child(sep)


func _create_button(parent: Container, text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 28)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn


func _create_order_button(parent: Container, text: String, order_type: int) -> void:
	var btn := _create_button(parent, text, Callable(self, "_on_order_pressed").bind(order_type))
	_order_buttons[order_type] = btn


# ─────────────────────────────── 信号连接 ────────────────────────────────

func _connect_signals() -> void:
	if _selection != null and _selection.has_signal("selection_changed"):
		_selection.selection_changed.connect(_on_selection_changed)
	if _formation != null:
		if _formation.has_signal("squad_created"):
			_formation.squad_created.connect(_on_squad_changed)
		if _formation.has_signal("squad_disbanded"):
			_formation.squad_disbanded.connect(_on_squad_changed)
	# EventBus 备用通道
	if EventBus != null:
		if EventBus.has_signal("commander_assigned"):
			EventBus.commander_assigned.connect(_on_squad_changed)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_selection_changed(_unit_ids: Array) -> void:
	_refresh_selection_info()
	_refresh_buttons()


func _on_squad_changed(_arg1 = null, _arg2 = null) -> void:
	_refresh_squad_list()
	_refresh_buttons()


# ─────────────────────────────── 刷新 ────────────────────────────────

func _refresh_all() -> void:
	_refresh_selection_info()
	_refresh_squad_list()
	_refresh_buttons()


func _refresh_selection_info() -> void:
	if _selection_label == null:
		return
	var count: int = 0
	if _selection != null and _selection.has_method("get_selected_count"):
		count = _selection.get_selected_count()
	_selection_label.text = "选中: %d 人" % count


func _refresh_squad_list() -> void:
	if _squad_container == null or _formation == null:
		return
	# 清空旧条目
	for child in _squad_container.get_children():
		child.queue_free()
	var squads: Array = _formation.get_all_squads() if _formation.has_method("get_all_squads") else []
	if squads.is_empty():
		var label := Label.new()
		label.text = "（无小队）"
		_squad_container.add_child(label)
		return
	for squad_id in squads:
		var size: int = _formation.get_squad_size(squad_id) if _formation.has_method("get_squad_size") else 0
		var leader: Node = _formation.get_squad_leader(squad_id) if _formation.has_method("get_squad_leader") else null
		var leader_str: String = "无" if leader == null else "#%d" % leader.get_instance_id()
		var entry := Label.new()
		entry.text = "%s (%d人, 排长:%s)" % [squad_id, size, leader_str]
		_squad_container.add_child(entry)


func _refresh_buttons() -> void:
	# 编队按钮：有选中单位时可用
	var has_selection: bool = _selection != null and _selection.has_method("get_selected_count") and _selection.get_selected_count() > 0
	if _create_squad_btn != null:
		_create_squad_btn.disabled = not has_selection
	# 任命排长按钮：有选中单位且该单位在小队中时可用
	var can_assign: bool = false
	if has_selection and _formation != null and _formation.has_method("get_unit_squad"):
		var units: Array = _selection.get_selected_units() if _selection.has_method("get_selected_units") else []
		if not units.is_empty() and is_instance_valid(units[0]):
			var sid: String = _formation.get_unit_squad(units[0])
			can_assign = not sid.is_empty()
	if _assign_leader_btn != null:
		_assign_leader_btn.disabled = not can_assign
	# 号令按钮：选中单位在小队中时可用
	var can_order: bool = can_assign
	for btn in _order_buttons.values():
		btn.disabled = not can_order
	# 附身按钮：有选中单位时可用
	if _possess_btn != null:
		_possess_btn.disabled = not has_selection


# ─────────────────────────────── 按钮回调 ────────────────────────────────

## 编队：将当前选中单位编为一个小队
func _on_create_squad_pressed() -> void:
	if _selection == null or _formation == null:
		return
	var units: Array = _selection.get_selected_units() if _selection.has_method("get_selected_units") else []
	if units.is_empty():
		return
	if _formation.has_method("create_squad"):
		var squad_id: String = _formation.create_squad(units)
		if not squad_id.is_empty():
			_show_notify("编队成功: %s" % squad_id)


## 任命排长：将第一个选中单位任命为其所在小队的排长
func _on_assign_leader_pressed() -> void:
	if _selection == null or _formation == null:
		return
	var units: Array = _selection.get_selected_units() if _selection.has_method("get_selected_units") else []
	if units.is_empty():
		return
	var unit: Node = units[0]
	if not is_instance_valid(unit):
		return
	if not _formation.has_method("get_unit_squad") or not _formation.has_method("assign_leader"):
		return
	var squad_id: String = _formation.get_unit_squad(unit)
	if squad_id.is_empty():
		return
	if _formation.assign_leader(squad_id, unit):
		_show_notify("任命排长: #%d" % unit.get_instance_id())


## 号令按钮：对选中单位所在小队下达号令
func _on_order_pressed(order_type: int) -> void:
	if _selection == null or _formation == null or _tactical == null:
		return
	var units: Array = _selection.get_selected_units() if _selection.has_method("get_selected_units") else []
	if units.is_empty():
		return
	var unit: Node = units[0]
	if not is_instance_valid(unit):
		return
	if not _formation.has_method("get_unit_squad"):
		return
	var squad_id: String = _formation.get_unit_squad(unit)
	if squad_id.is_empty():
		_show_notify("单位不在任何小队中")
		return
	# 前进号令需要目标位置：选中单位平均位置 + 右偏移
	var target: Vector2 = Vector2.ZERO
	if order_type == 0:  # ADVANCE_ALL
		target = _compute_advance_target(units)
	if _tactical.has_method("issue"):
		var ok: bool = _tactical.issue(order_type, squad_id, target)
		if ok:
			var name_str: String = _tactical.get_order_name(order_type) if _tactical.has_method("get_order_name") else str(order_type)
			_show_notify("号令已下达: %s" % name_str)


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算前进号令目标位置：选中单位平均 X + 偏移
func _compute_advance_target(units: Array) -> Vector2:
	var avg_x: float = 0.0
	var avg_y: float = 0.0
	var count: int = 0
	for u in units:
		if is_instance_valid(u) and u is Node2D:
			avg_x += (u as Node2D).global_position.x
			avg_y += (u as Node2D).global_position.y
			count += 1
	if count == 0:
		return Vector2.ZERO
	avg_x /= count
	avg_y /= count
	return Vector2(avg_x + ADVANCE_OFFSET_X, avg_y)


## 附身选中单位：切换到 POSSESS 模式
func _on_possess_pressed() -> void:
	if _selection == null:
		return
	var units: Array = _selection.get_selected_units() if _selection.has_method("get_selected_units") else []
	if units.is_empty():
		_show_notify("请先选中一个单位")
		return
	var unit: Node = units[0]
	if not is_instance_valid(unit):
		return
	if unit.has_method("is_dead") and unit.is_dead():
		_show_notify("不能附身已死亡的单位")
		return
	# 切换到 POSSESS 模式
	if _game_root != null and _game_root.has_method("get") and _game_root.get("input_dispatcher") != null:
		var dispatcher: Node = _game_root.input_dispatcher
		# 先设置 pending entity（SelectionSystem 在模式切换时会清空选择）
		var pi: Node = _game_root.get_possession_interface() if _game_root.has_method("get_possession_interface") else null
		if pi != null and pi.has_method("set_pending_entity"):
			pi.set_pending_entity(unit)
		if dispatcher.has_method("enter_possess_mode"):
			dispatcher.enter_possess_mode()


func _show_notify(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("战斗", msg, "info")
