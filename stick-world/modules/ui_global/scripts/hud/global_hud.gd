class_name GlobalHUD
extends Control
## 全局 HUD —— 顶层常驻 UI（统一顶栏通栏）。
##
## 顶栏一段式通栏（黑玻璃背景）：左=速度/时间，中=系统按钮；材料条（ResourceBar）
## 作为**顶栏下方独立横条**（ResourceBarHost，y=64 起，不重叠按钮行，见 global_hud.tscn）。
## 资源条由 attach_resources 注入（SystemSetup 在资源系统装配后调用）。

const _ResourceBarScript: GDScript = preload("res://modules/ui_global/scripts/hud/resource_bar.gd")

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var speed_label: Label = get_node_or_null("MarginContainer/HBoxContainer/SpeedLabel")
@onready var time_label: Label = get_node_or_null("MarginContainer/HBoxContainer/TimeLabel")
@onready var notification_label: Label = get_node_or_null("NotificationLabel")
@onready var centered_button: Button = get_node_or_null("MarginContainer/HBoxContainer/CenteredButton")
@onready var stuck_button: Button = get_node_or_null("MarginContainer/HBoxContainer/StuckButton")
@onready var formation_button: Button = get_node_or_null("MarginContainer/HBoxContainer/FormationButton")
@onready var settings_button: Button = get_node_or_null("MarginContainer/HBoxContainer/SettingsButton")
## 材料面板（顶栏下方横条，ResourceBar 挂这里）
@onready var _resource_host: PanelContainer = get_node_or_null("ResourceBarHost")


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 由 SystemSetup 装配时调用，注入 CameraRig / GameRoot（不自行向上遍历查找）。
func setup(camera_rig: Node, game_root: Node) -> void:
	_camera_rig = camera_rig
	_game_root = game_root


## 注入资源条（SystemSetup 在资源系统装配后调用）：材料显示挂进顶栏下方横条。
## 返回资源条实例（供装配方存引用），失败返回 null。
func attach_resources(resources_api: Node) -> Control:
	if _resource_bar != null or resources_api == null:
		return _resource_bar
	if _resource_host == null:
		return null
	_resource_host.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	_resource_bar = _ResourceBarScript.new()
	_resource_bar.name = "ResourceBar"
	_resource_host.add_child(_resource_bar)
	if _resource_bar.has_method("setup"):
		_resource_bar.setup(resources_api)
	return _resource_bar


func _ready() -> void:
	_bind_event_bus()
	_update_speed_display()
	if centered_button != null:
		centered_button.pressed.connect(_on_centered_button_pressed)
		_update_centered_button_text()
	if stuck_button != null:
		stuck_button.pressed.connect(_on_stuck_button_pressed)
	if formation_button != null:
		formation_button.pressed.connect(_on_formation_button_pressed)
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_button_pressed)


func _process(_delta: float) -> void:
	_update_speed_display()
	_update_time_display()


func _bind_event_bus() -> void:
	if not EventBus:
		return
	if EventBus.has_signal("game_paused"):
		EventBus.game_paused.connect(_on_pause_changed.bind(true))
	if EventBus.has_signal("game_resumed"):
		EventBus.game_resumed.connect(_on_pause_changed.bind(false))
	if EventBus.has_signal("battle_started"):
		EventBus.battle_started.connect(_on_battle_started)
	if EventBus.has_signal("battle_ended"):
		EventBus.battle_ended.connect(_on_battle_ended)


func _on_battle_started(_battle_id: String) -> void:
	show_notification("战斗", "一场战斗开始了", "info")


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	var result: String = "进攻方获胜" if victory else "防守方获胜"
	show_notification("战斗", "战斗结束：%s" % result, "info")


# ─────────────────────────────── 更新显示 ────────────────────────────────

func _update_speed_display() -> void:
	if speed_label == null or TimeManager == null:
		return
	var text: String = "速度: "
	match TimeManager.current_speed:
		TimeManager.Speed.PAUSED:
			text += "暂停"
		TimeManager.Speed.X1:
			text += "1x"
		TimeManager.Speed.X2:
			text += "2x"
		TimeManager.Speed.X4:
			text += "4x"
	speed_label.text = text


func _update_time_display() -> void:
	if time_label == null:
		return
	# 优先从 WorldState 读取
	if WorldState:
		var t: float = WorldState.game_time
		var hour: int = int(t) % 24
		var minute: int = int((t - int(t)) * 60.0)
		time_label.text = "时间: %02d:%02d" % [hour, minute]


func _on_pause_changed(_paused: bool) -> void:
	_update_speed_display()


# ─────────────────────────────── 通知 ────────────────────────────────

## 显示通知（P0 阶段简单文本显示，5 秒后清空）
func show_notification(title: String, body: String, level: String) -> void:
	if notification_label == null:
		return
	var prefix: String = ""
	match level:
		"info":
			prefix = "[i]"
		"warn":
			prefix = "[!]"
		"error":
			prefix = "[X]"
	notification_label.text = "%s %s — %s" % [prefix, title, body]
	var tree := get_tree()
	if tree:
		tree.create_timer(5.0).timeout.connect(func():
			# 自身已释放时不再访问成员（防 freed 实例访问）
			if is_instance_valid(self) and notification_label != null and is_instance_valid(notification_label):
				notification_label.text = ""
		)


# ─────────────────────────────── 居中模式 ────────────────────────────────

var _camera_rig: Node = null
var _game_root: Node = null
## 顶栏内嵌资源条（attach_resources 注入）
var _resource_bar: Control = null


func _on_centered_button_pressed() -> void:
	var cam := _camera_rig
	if cam == null or not cam.has_method("set_centered_mode") or not cam.has_method("is_centered_mode"):
		return
	cam.set_centered_mode(not cam.is_centered_mode())
	_update_centered_button_text()


func _update_centered_button_text() -> void:
	if centered_button == null:
		return
	var cam := _camera_rig
	if cam == null or not cam.has_method("is_centered_mode"):
		return
	centered_button.text = "居中: 开" if cam.is_centered_mode() else "居中: 关"


# ─────────────────────────────── 脱离卡死（H 键 / 按钮）────────────────────────────────


func _on_stuck_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		show_notification("脱困", "未找到游戏根节点", "error")
		return
	var e: Node2D = gr.get_player_entity() if gr.has_method("get_player_entity") else null
	if e == null or not is_instance_valid(e) or not e.has_method("escape_stuck"):
		show_notification("脱困", "未找到玩家实体", "error")
		return
	e.escape_stuck()
	show_notification("脱困", "已随机传送到附近空旷地带", "info")


# ─────────────────────────────── 编制管理窗口 ────────────────────────────────

## 打开/关闭编制管理窗口（队伍类型编制：创建/配置编队）
func _on_formation_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		show_notification("编制", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_formation_panel"):
		gr.toggle_formation_panel()


# ─────────────────────────────── 设置菜单（齿轮按钮）────────────────────────────────

## 打开/关闭设置菜单（调试地图选择/速度控制）
func _on_settings_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		show_notification("设置", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_settings_menu"):
		gr.toggle_settings_menu()
