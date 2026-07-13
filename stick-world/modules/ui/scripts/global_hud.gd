class_name GlobalHUD
extends Control
## 全局 HUD —— 顶层常驻 UI。
##
## P0 阶段显示：时间速度、暂停状态、通知文本。
## 后续扩展：资源数、人口、坐标、调试信息。

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var speed_label: Label = get_node_or_null("MarginContainer/SpeedLabel")
@onready var time_label: Label = get_node_or_null("MarginContainer/TimeLabel")
@onready var notification_label: Label = get_node_or_null("NotificationLabel")
@onready var centered_button: Button = get_node_or_null("MarginContainer/HBoxContainer/CenteredButton")


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_bind_event_bus()
	_update_speed_display()
	if centered_button != null:
		centered_button.pressed.connect(_on_centered_button_pressed)
		_update_centered_button_text()


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

## 显示通知（P0 阶段简单文本显示，2 秒后淡出）
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
	# 简化：5 秒后清空
	var tree := get_tree()
	if tree:
		tree.create_timer(5.0).timeout.connect(func():
			if notification_label:
				notification_label.text = ""
		)


# ─────────────────────────────── 居中模式 ────────────────────────────────

## 获取 CameraRig（通过场景 owner，即 GameRoot）
func _get_camera_rig() -> Node:
	var root := owner
	if root == null:
		return null
	return root.get_node_or_null("CameraRig")


func _on_centered_button_pressed() -> void:
	var cam := _get_camera_rig()
	if cam == null or not cam.has_method("set_centered_mode") or not cam.has_method("is_centered_mode"):
		return
	cam.set_centered_mode(not cam.is_centered_mode())
	_update_centered_button_text()


func _update_centered_button_text() -> void:
	if centered_button == null:
		return
	var cam := _get_camera_rig()
	if cam == null or not cam.has_method("is_centered_mode"):
		return
	centered_button.text = "居中: 开" if cam.is_centered_mode() else "居中: 关"
