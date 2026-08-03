class_name FormationPanel
extends Control
## 编制管理窗口 —— 队伍类型编制系统的配置界面（挂 UIRoot.ModalOverlay 的模态面板）。
##
## 功能：
##   1. 编队列表（类型/人数/队长），点选查看详情
##   2. 创建编队：选预设（战斗班/建造队/工人队）+ 命名
##   3. 空闲火柴人列表：一键加入选中编队
##   4. 编队详情：职责范围勾选调整 / 成员管理（任命排长/移出）/ 解散
##
## 由 SystemSetup 装配到 UIRoot.ModalOverlay，open() 显示、close() 隐藏。
## 不依赖 BATTLE 模式（村庄/战场都可打开），符合"建造→编队→下令"原型循环。

# ─────────────────────────────── 常量 ────────────────────────────────
## 工作类型选项（与 FormationSystem.WorkType 对齐）
const WORK_OPTIONS: Array = [
	{"label": "战斗", "id": "WORK_COMBAT"},
	{"label": "建造", "id": "WORK_BUILD"},
	{"label": "搬运", "id": "WORK_HAUL"},
	{"label": "采集", "id": "WORK_FORAGE"},
]

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _formation: Node = null
## 当前选中的小队 id（空 = 未选中）
var _selected_squad: String = ""

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _squad_list: VBoxContainer = null
var _detail_box: VBoxContainer = null
var _idle_list: VBoxContainer = null
var _preset_option: OptionButton = null
var _name_edit: LineEdit = null
var _work_checks: Dictionary = {}  # work_type(String) -> CheckBox
## 空闲单位勾选状态：unit instance_id -> CheckBox
var _idle_checks: Dictionary = {}


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_formation = game_root.get_formation_system() if game_root != null and game_root.has_method("get_formation_system") else null
	_build_ui()
	_connect_signals()
	_refresh_all()


func _ready() -> void:
	visible = false


func _connect_signals() -> void:
	if _formation == null:
		return
	if _formation.has_signal("squad_created"):
		_formation.squad_created.connect(_on_squads_changed)
	if _formation.has_signal("squad_disbanded"):
		_formation.squad_disbanded.connect(_on_squads_changed)


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 半透明背景（点击不穿透）
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	# 主面板。注意顺序：先 add_child 再 set_anchors_and_offsets_preset
	# （节点须已入树、父尺寸已知，才能正确计算居中偏移）。
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(760, 500)
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	# 标题
	var title := Label.new()
	title.text = "编制管理"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 6
	title.offset_bottom = 30
	panel.add_child(title)
	# 左右分栏
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_top = 34
	hbox.offset_bottom = -44
	hbox.offset_left = 12
	hbox.offset_right = -12
	panel.add_child(hbox)
	# ── 左栏：编队列表 + 创建区 ──
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	hbox.add_child(left)
	var left_title := Label.new()
	left_title.text = "编队列表"
	left.add_child(left_title)
	_squad_list = VBoxContainer.new()
	_squad_list.add_theme_constant_override("separation", 2)
	left.add_child(_squad_list)
	var create_label := Label.new()
	create_label.text = "创建编队"
	left.add_child(create_label)
	_preset_option = OptionButton.new()
	left.add_child(_preset_option)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "编队名（可选）"
	left.add_child(_name_edit)
	var create_btn := Button.new()
	create_btn.text = "创建编队（用勾选的空闲火柴人）"
	create_btn.pressed.connect(_on_create_pressed)
	left.add_child(create_btn)
	var join_btn := Button.new()
	join_btn.text = "加入选中编队"
	join_btn.pressed.connect(_on_join_selected_pressed)
	left.add_child(join_btn)
	# ── 右栏：详情 + 空闲火柴人 ──
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(right)
	_detail_box = VBoxContainer.new()
	_detail_box.add_theme_constant_override("separation", 4)
	right.add_child(_detail_box)
	var idle_title := Label.new()
	idle_title.text = "空闲火柴人（勾选后创建/入队）"
	right.add_child(idle_title)
	_idle_list = VBoxContainer.new()
	_idle_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_idle_list.add_theme_constant_override("separation", 2)
	right.add_child(_idle_list)
	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	close_btn.offset_top = -36
	close_btn.offset_bottom = -8
	close_btn.offset_left = 20
	close_btn.offset_right = -20
	close_btn.pressed.connect(close)
	panel.add_child(close_btn)


# ─────────────────────────────── 打开/关闭 ────────────────────────────────

func open() -> void:
	_refresh_all()
	visible = true


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


# ─────────────────────────────── 刷新 ────────────────────────────────

func _refresh_all() -> void:
	_refresh_preset_options()
	_refresh_squad_list()
	_refresh_detail()
	_refresh_idle_list()


func _refresh_preset_options() -> void:
	if _preset_option == null or _formation == null:
		return
	_preset_option.clear()
	var presets: Array = _formation.get_all_presets() if _formation.has_method("get_all_presets") else []
	var idx: int = 0
	for p in presets:
		var tag_str: String = p.get("tag", "")
		_preset_option.add_item("%s（%s）" % [p.get("name", p.get("id", "?")), tag_str])
		_preset_option.set_item_metadata(idx, p.get("id", ""))
		idx += 1


func _on_squads_changed(_a = null, _b = null) -> void:
	_refresh_squad_list()
	_refresh_detail()
	_refresh_idle_list()


## 刷新编队列表
func _refresh_squad_list() -> void:
	if _squad_list == null:
		return
	for child in _squad_list.get_children():
		child.queue_free()
	if _formation == null:
		return
	var squads: Array = _formation.get_all_squads() if _formation.has_method("get_all_squads") else []
	if squads.is_empty():
		var label := Label.new()
		label.text = "（无编队）"
		_squad_list.add_child(label)
		return
	for sid in squads:
		var btn := Button.new()
		var size: int = _formation.get_squad_size(sid) if _formation.has_method("get_squad_size") else 0
		var leader: Node = _formation.get_squad_leader(sid) if _formation.has_method("get_squad_leader") else null
		var leader_str: String = "无" if leader == null else "#%d" % leader.get_instance_id()
		# 类型徽标：预设名
		var preset_name: String = sid
		if _formation.has_method("get_squad_preset"):
			var pid: String = _formation.get_squad_preset(sid)
			var preset: Dictionary = _formation.get_preset(pid) if _formation.has_method("get_preset") else {}
			preset_name = preset.get("name", pid)
		btn.text = "%s（%d人，队长:%s）" % [preset_name, size, leader_str]
		btn.toggle_mode = true
		btn.button_pressed = (sid == _selected_squad)
		btn.pressed.connect(_on_squad_selected.bind(sid))
		_squad_list.add_child(btn)


## 刷新详情区（选中编队）
func _refresh_detail() -> void:
	if _detail_box == null:
		return
	for child in _detail_box.get_children():
		child.queue_free()
	if _formation == null or _selected_squad.is_empty():
		return
	var sid: String = _selected_squad
	# 编队名 + 类型
	var info := Label.new()
	var preset: Dictionary = {}
	if _formation.has_method("get_squad_preset"):
		var pid: String = _formation.get_squad_preset(sid)
		preset = _formation.get_preset(pid) if _formation.has_method("get_preset") else {}
	info.text = "编队详情：%s（%s）" % [preset.get("name", sid), preset.get("tag", "?")]
	_detail_box.add_child(info)
	# 职责范围
	var duty_title := Label.new()
	duty_title.text = "职责范围（可调整）："
	_detail_box.add_child(duty_title)
	_work_checks.clear()
	var duty_hbox := HBoxContainer.new()
	for opt in WORK_OPTIONS:
		var cb := CheckBox.new()
		cb.text = opt["label"]
		duty_hbox.add_child(cb)
		_work_checks[opt["id"]] = cb
	_detail_box.add_child(duty_hbox)
	var apply_btn := Button.new()
	apply_btn.text = "应用职责"
	apply_btn.pressed.connect(_on_apply_work_types)
	_detail_box.add_child(apply_btn)
	# 当前职责回填
	var work_types: Array = _formation.get_squad_work_types(sid) if _formation.has_method("get_squad_work_types") else []
	for wt in work_types:
		if _work_checks.has(wt):
			_work_checks[wt].button_pressed = true
	# 成员列表
	var members: Array = _formation.get_squad_units(sid) if _formation.has_method("get_squad_units") else []
	for u in members:
		if not is_instance_valid(u):
			continue
		var row := HBoxContainer.new()
		var u_label := Label.new()
		var role_str: String = u.get_role() if u.has_method("get_role") else ""
		var is_leader: bool = (_formation.get_squad_leader(sid) == u) if _formation.has_method("get_squad_leader") else false
		u_label.text = "#%d（%s）%s" % [u.get_instance_id(), role_str, "★排长" if is_leader else ""]
		row.add_child(u_label)
		var lead_btn := Button.new()
		lead_btn.text = "任命排长"
		lead_btn.pressed.connect(_on_assign_leader.bind(sid, u))
		row.add_child(lead_btn)
		var remove_btn := Button.new()
		remove_btn.text = "移出"
		remove_btn.pressed.connect(_on_remove_member.bind(u))
		row.add_child(remove_btn)
		_detail_box.add_child(row)
	# 跟随玩家（队员尾随玩家移动，跟到战场）
	var follow_row := HBoxContainer.new()
	var follow_label := Label.new()
	follow_label.text = "跟随玩家："
	follow_row.add_child(follow_label)
	var follow_check := CheckBox.new()
	var is_following: bool = _formation.is_squad_following(sid) if _formation.has_method("is_squad_following") else false
	follow_check.button_pressed = is_following
	follow_check.pressed.connect(_on_toggle_follow.bind(sid, follow_check))
	follow_row.add_child(follow_check)
	_detail_box.add_child(follow_row)
	# 解散
	var disband_btn := Button.new()
	disband_btn.text = "解散小队"
	disband_btn.pressed.connect(_on_disband_pressed)
	_detail_box.add_child(disband_btn)


## 刷新空闲火柴人列表（CheckBox 多选）
func _refresh_idle_list() -> void:
	if _idle_list == null:
		return
	for child in _idle_list.get_children():
		child.queue_free()
	_idle_checks.clear()
	if _game_root == null:
		return
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if map == null or not map.has_method("get_entities"):
		var hint := Label.new()
		hint.text = "（无地图）"
		_idle_list.add_child(hint)
		return
	var count: int = 0
	for e in map.get_entities():
		if not is_instance_valid(e) or not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if _formation != null and _formation.has_method("is_in_squad") and _formation.is_in_squad(e):
			continue
		var cb := CheckBox.new()
		var role_str: String = e.get_role() if e.has_method("get_role") else ""
		cb.text = "#%d（%s）" % [e.get_instance_id(), role_str if not role_str.is_empty() else "未编队"]
		_idle_list.add_child(cb)
		_idle_checks[e.get_instance_id()] = cb
		count += 1
	if count == 0:
		var hint := Label.new()
		hint.text = "（无空闲火柴人）"
		_idle_list.add_child(hint)


## 获取勾选中的空闲单位列表
func _get_checked_idle_units() -> Array:
	var result: Array = []
	if _game_root == null:
		return result
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if map == null or not map.has_method("get_entities"):
		return result
	for e in map.get_entities():
		if not is_instance_valid(e):
			continue
		if _idle_checks.has(e.get_instance_id()) and _idle_checks[e.get_instance_id()].button_pressed:
			result.append(e)
	return result


# ─────────────────────────────── 回调 ────────────────────────────────

func _on_squad_selected(sid: String) -> void:
	_selected_squad = sid
	_refresh_squad_list()
	_refresh_detail()
	_refresh_idle_list()


## 创建编队：预设 + 名称 + 勾选的空闲单位
func _on_create_pressed() -> void:
	if _formation == null or _preset_option == null:
		return
	var preset_id: String = str(_preset_option.get_item_metadata(_preset_option.selected))
	if preset_id.is_empty():
		return
	var units: Array = _get_checked_idle_units()
	if units.is_empty():
		_show_notify("请先勾选要编入的火柴人")
		return
	var name_str: String = _name_edit.text.strip_edges()
	var squad_id: String = _formation.create_squad(units, name_str, preset_id) if _formation.has_method("create_squad") else ""
	if squad_id.is_empty():
		return
	_selected_squad = squad_id
	_name_edit.text = ""
	_refresh_all()
	_show_notify("编队创建成功: %s" % preset_id)


## 勾选的空闲单位加入选中编队
func _on_join_selected_pressed() -> void:
	if _formation == null or _selected_squad.is_empty():
		_show_notify("请先选中或创建一个编队")
		return
	var units: Array = _get_checked_idle_units()
	if units.is_empty():
		_show_notify("请先勾选要编入的火柴人")
		return
	var added: int = 0
	for u in units:
		if not is_instance_valid(u):
			continue
		if _formation.add_unit(_selected_squad, u) if _formation.has_method("add_unit") else false:
			added += 1
	_refresh_all()
	_show_notify("已加入 %d 人" % added)


## 应用职责范围
func _on_apply_work_types() -> void:
	if _formation == null or _selected_squad.is_empty() or not _formation.has_method("set_squad_work_types"):
		return
	var work_types: Array = []
	for wt in _work_checks.keys():
		if _work_checks[wt].button_pressed:
			work_types.append(wt)
	if _formation.set_squad_work_types(_selected_squad, work_types):
		_show_notify("职责已更新")
		_refresh_detail()
		_refresh_idle_list()


## 移出成员
func _on_remove_member(unit: Node) -> void:
	if _formation == null or not is_instance_valid(unit):
		return
	if _formation.has_method("remove_unit"):
		_formation.remove_unit(unit)
	_refresh_all()


## 任命排长
func _on_assign_leader(sid: String, unit: Node) -> void:
	if _formation == null or not is_instance_valid(unit):
		return
	var ok: bool = false
	if _formation.has_method("assign_leader"):
		ok = _formation.assign_leader(sid, unit)
	if ok:
		_refresh_all()
		_show_notify("已任命排长 #%d" % unit.get_instance_id())


## 解散小队
func _on_disband_pressed() -> void:
	if _formation == null or _selected_squad.is_empty():
		return
	if _formation.has_method("disband_squad"):
		_formation.disband_squad(_selected_squad)
	_selected_squad = ""
	_refresh_all()


## 切换小队跟随玩家模式
func _on_toggle_follow(sid: String, check: CheckBox) -> void:
	if _formation == null:
		return
	if _formation.has_method("set_squad_follow"):
		_formation.set_squad_follow(sid, check.button_pressed)
	_show_notify("跟随已%s" % ("开启" if check.button_pressed else "关闭"))


func _show_notify(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("编制", msg, "info")
