class_name UserControlPanel
extends Control
## 附身面板 -- USER_CONTROL 模式下的底部 HUD。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §10.1、§7.5。
## 显示附身单位的状态信息：
##   - HP
##   - 武器冷却 / 情绪标签
##   - 当前行为 / 朝向
##   - 坐标
## 提供"退出附身"按钮（ESC 同效）。
##
## 由 GameRoot 在 _ready 中 set_script 装配，随后调用 setup(game_root)。
##
## 刷新机制（信号驱动，不再每帧字符串重建）：
##   - HP/士气：附身开始时订阅实体 health 组件 damaged/healed/morale_changed，
##     变化即刷新；附身结束断开。
##   - 无信号的连续值（冷却/情绪/行为/朝向/坐标）：单个 0.2s 低频 Timer 兜底
##     （仅已附身且面板可见时跑）——字符串重建从每帧降到 5Hz。

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _user_control: Node = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _info_label: Label = null
var _release_btn: Button = null

# ─────────────────────────────── 信号订阅簿记 ────────────────────────────────
## 当前订阅的 health 组件（断开/失效清理用）
var _bound_health: Node = null
## health 信号 → 本面板回调（断开时按表拆线）
var _health_binds: Array = []
## 连续值低频兜底刷新
var _refresh_timer: Timer = null

## 连续值刷新周期（秒）：冷却/坐标等连续量人眼 5Hz 足够
const CONTINUOUS_REFRESH_SEC := 0.2


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入系统引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_user_control = game_root.get_user_control_interface() if game_root.has_method("get_user_control_interface") else null
	_build_ui()
	_connect_signals()


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 清空占位子节点
	for child in get_children():
		child.queue_free()
	# 底栏质感（HUD 部件标准：条状部件 = PanelContainer + window_panel_light，
	# 与顶栏/资源条同黑玻璃质感，不用裸背景）
	var bar := PanelContainer.new()
	bar.name = "Bar"
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BOTH
	bar.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	add_child(bar)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	bar.add_child(margin)

	# 根容器：水平布局
	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.add_theme_constant_override("separation", 16)
	margin.add_child(hbox)

	# ── 单位信息 ──
	var info_section := StickKit.section(hbox, "附身单位")
	_info_label = Label.new()
	_info_label.text = "未附身"
	info_section.add_child(_info_label)

	# 分隔线
	StickKit.vseparator(hbox)

	# ── 操作 ──
	var action_section := StickKit.section(hbox, "操作")
	var action_hbox := HBoxContainer.new()
	action_hbox.add_theme_constant_override("separation", 6)
	action_section.add_child(action_hbox)
	_release_btn = StickKit.sketch_button(action_hbox, "退出附身 (ESC)", _on_release_pressed)

	# 连续值低频兜底（默认停，附身开始才起表）
	_refresh_timer = Timer.new()
	_refresh_timer.name = "ContinuousRefresh"
	_refresh_timer.wait_time = CONTINUOUS_REFRESH_SEC
	_refresh_timer.autostart = false
	_refresh_timer.timeout.connect(_refresh_info)
	add_child(_refresh_timer)


# ─────────────────────────────── 信号连接 ────────────────────────────────

func _connect_signals() -> void:
	if EventBus != null:
		if EventBus.has_signal("user_control_started"):
			EventBus.user_control_started.connect(_on_user_control_started)
		if EventBus.has_signal("user_control_ended"):
			EventBus.user_control_ended.connect(_on_user_control_ended)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_user_control_started(_entity) -> void:
	_bind_entity_signals()
	_refresh_info()
	_refresh_timer.start()


func _on_user_control_ended(_entity) -> void:
	_unbind_entity_signals()
	_refresh_timer.stop()
	_info_label.text = "未附身"


## 订阅当前附身实体的离散属性信号（HP/士气变化即刷，不等兜底节拍）
func _bind_entity_signals() -> void:
	_unbind_entity_signals()
	var entity: Node2D = _current_entity()
	if entity == null:
		return
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health == null:
		return
	_bound_health = health
	for sig_name in ["damaged", "healed", "morale_changed"]:
		if health.has_signal(sig_name):
			var cb := Callable(self, "_on_health_changed")
			if health.connect(sig_name, cb) == OK:
				_health_binds.append([sig_name, cb])


func _unbind_entity_signals() -> void:
	if _bound_health != null and is_instance_valid(_bound_health):
		for entry in _health_binds:
			var sig_name: String = entry[0]
			var cb: Callable = entry[1]
			if _bound_health.has_signal(sig_name) and _bound_health.is_connected(sig_name, cb):
				_bound_health.disconnect(sig_name, cb)
	_health_binds.clear()
	_bound_health = null


func _on_health_changed(_a = null, _b = null, _c = null) -> void:
	_refresh_info()


## 当前附身实体（含失效防护；不在附身态返回 null）
func _current_entity() -> Node2D:
	if _user_control == null or not _user_control.has_method("get_user_controlled_entity"):
		return null
	var entity: Node2D = _user_control.get_user_controlled_entity()
	if entity == null or not is_instance_valid(entity):
		return null
	return entity


# ─────────────────────────────── 刷新 ────────────────────────────────

## 隐藏期跳过刷新（不可见刷了也看不见）；补「显示即刷」：user_control_started
## 信号先于 ModePanel 面板切换到达时，信号当拍的刷新会被隐藏守卫吞掉——
## 不补这一笔，首屏信息停在"未附身"直到 0.2s 兜底节拍。
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree():
		_refresh_info()


func _refresh_info() -> void:
	if _info_label == null or not is_visible_in_tree():
		return
	var entity: Node2D = _current_entity()
	if entity == null:
		_info_label.text = "未附身"
		return
	# 收集单位信息
	var parts: Array = []
	# HP
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null:
		var hp: float = health.hp
		var max_hp: float = health.max_hp
		parts.append("HP: %d/%d" % [int(hp), int(max_hp)])
	# 武器
	var weapon: Node2D = entity.get_weapon() if entity.has_method("get_weapon") else null
	if weapon != null:
		var cd: float = weapon.get_cooldown_remaining() if weapon.has_method("get_cooldown_remaining") else 0.0
		parts.append("冷却: %.1fs" % cd)
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


# ─────────────────────────────── 按钮回调 ────────────────────────────────

func _on_release_pressed() -> void:
	if _user_control != null and _user_control.has_method("release"):
		_user_control.release()
