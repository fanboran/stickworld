class_name PossessPanel
extends Control
## 附身面板 -- POSSESS 模式下的底部 HUD。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.1、§7.5。
## 显示附身单位的状态信息：
##   - HP / 士气
##   - 武器冷却 / 情绪标签
##   - 当前行为 / 朝向
##   - 坐标
## 提供"退出附身"按钮（ESC 同效）。
##
## 由 GameRoot 在 _ready 中 set_script 装配，随后调用 setup(game_root)。

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _possession: Node = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _info_label: Label = null
var _release_btn: Button = null


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入系统引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_possession = game_root.get_possession_interface() if game_root.has_method("get_possession_interface") else null
	_build_ui()
	_connect_signals()


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 清空占位子节点
	for child in get_children():
		child.queue_free()
	# 根容器：水平布局
	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 16)
	hbox.offset_left = 8
	hbox.offset_top = 4
	hbox.offset_right = -8
	hbox.offset_bottom = -4
	add_child(hbox)

	# ── 单位信息 ──
	var info_section := _create_section(hbox, "附身单位")
	_info_label = Label.new()
	_info_label.text = "未附身"
	info_section.add_child(_info_label)

	# 分隔线
	_add_separator(hbox)

	# ── 操作 ──
	var action_section := _create_section(hbox, "操作")
	var action_hbox := HBoxContainer.new()
	action_hbox.add_theme_constant_override("separation", 6)
	action_section.add_child(action_hbox)
	_release_btn = _create_button(action_hbox, "退出附身 (ESC)", _on_release_pressed)


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


# ─────────────────────────────── 信号连接 ────────────────────────────────

func _connect_signals() -> void:
	if EventBus != null:
		if EventBus.has_signal("possession_started"):
			EventBus.possession_started.connect(_on_possession_started)
		if EventBus.has_signal("possession_ended"):
			EventBus.possession_ended.connect(_on_possession_ended)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_possession_started(_entity) -> void:
	_refresh_info()


func _on_possession_ended(_entity) -> void:
	_info_label.text = "未附身"


# ─────────────────────────────── 刷新 ────────────────────────────────

func _process(_delta: float) -> void:
	_refresh_info()


func _refresh_info() -> void:
	if _info_label == null:
		return
	if _possession == null:
		_info_label.text = "未附身"
		return
	var entity: Node2D = _possession.get_possessed_entity()
	if entity == null or not is_instance_valid(entity):
		_info_label.text = "未附身"
		return
	# 收集单位信息
	var parts: Array = []
	# HP
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null:
		var hp: float = health.hp
		var max_hp: float = health.max_hp
		var morale: float = health.morale
		var max_morale: float = health.max_morale
		parts.append("HP: %d/%d" % [int(hp), int(max_hp)])
		parts.append("士气: %d/%d" % [int(morale), int(max_morale)])
	# 武器
	var weapon: Node2D = entity.get_weapon() if entity.has_method("get_weapon") else null
	if weapon != null:
		var cd: float = weapon.get_cooldown_remaining() if weapon.has_method("get_cooldown_remaining") else 0.0
		var mood: int = weapon.get_mood() if weapon.has_method("get_mood") else 0
		var mood_str: String = _mood_to_string(mood)
		parts.append("冷却: %.1fs" % cd)
		parts.append("情绪: %s" % mood_str)
	# 行为
	var ai: Node = entity.get_ai_controller() if entity.has_method("get_ai_controller") else null
	if ai != null and ai.has_method("get_current_behavior"):
		parts.append("行为: %s" % ai.get_current_behavior())
	# 朝向
	var facing: int = entity.get_facing() if entity.has_method("get_facing") else 0
	parts.append("朝向: %s" % ("右" if facing >= 0 else "左"))
	# 坐标
	parts.append("pos: (%d, %d)" % [int(entity.global_position.x), int(entity.global_position.y)])
	_info_label.text = "  |  ".join(parts)


func _mood_to_string(mood: int) -> String:
	match mood:
		0: return "稳定"
		1: return "犹豫"
		2: return "亢奋"
		3: return "恐慌"
		_: return "未知"


# ─────────────────────────────── 按钮回调 ────────────────────────────────

func _on_release_pressed() -> void:
	if _possession != null and _possession.has_method("release"):
		_possession.release()
