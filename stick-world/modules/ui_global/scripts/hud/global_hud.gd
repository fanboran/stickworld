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
@onready var time_label: Label = get_node_or_null("TimeLabel")  # 钟表盘正下方（宽度变化不再挤顶栏按钮）
@onready var centered_button: Button = get_node_or_null("MarginContainer/HBoxContainer/CenteredButton")
@onready var stuck_button: Button = get_node_or_null("MarginContainer/HBoxContainer/StuckButton")
@onready var formation_button: Button = get_node_or_null("MarginContainer/HBoxContainer/FormationButton")
@onready var settings_button: Button = get_node_or_null("MarginContainer/HBoxContainer/SettingsButton")
## 占位界面预览入口（开发用）：打开占位预览面板（大界面空面板陈列）
@onready var placeholder_preview_button: Button = get_node_or_null("MarginContainer/HBoxContainer/PlaceholderPreviewButton")
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
	if placeholder_preview_button != null:
		placeholder_preview_button.pressed.connect(_on_placeholder_preview_pressed)


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
	_notify("战斗开始", "已自动暂停布置战术——按 空格 恢复开打", "info")


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	var result: String = "进攻方获胜" if victory else "防守方获胜"
	_notify("战斗", "战斗结束：%s" % result, "info")


# ─────────────────────────────── 更新显示 ────────────────────────────────

func _update_speed_display() -> void:
	if speed_label == null or TimeManager == null:
		return
	var paused: bool = TimeManager.is_paused()
	var text: String = "速度: "
	match TimeManager.current_speed:
		TimeManager.Speed.PAUSED:
			text += "暂停（空格继续）"
		TimeManager.Speed.X1:
			text += "1x"
		TimeManager.Speed.X2:
			text += "2x"
		TimeManager.Speed.X4:
			text += "4x"
	# 脏检查：内容/配色没变就不碰 Label（每帧 text/color 赋值触发重排，全程白烧）
	if text != _last_speed_text:
		_last_speed_text = text
		speed_label.text = text
	if int(paused) != _last_speed_paused:
		_last_speed_paused = int(paused)
		# 暂停态醒目化（战斗自动暂停的可发现性——玩家第一眼看到"怎么继续"）
		speed_label.add_theme_color_override("font_color",
				Color(1.0, 0.55, 0.35) if paused else Color(0.9, 0.9, 0.9))


func _update_time_display() -> void:
	if time_label == null:
		return
	# 优先从 WorldState 读取；按"当日分钟数"脏检查，分钟没跳过不重写
	if WorldState:
		var t: float = WorldState.game_time
		var minute_of_day: int = int(t * 60.0) % 1440
		if minute_of_day == _last_minute_of_day:
			return
		_last_minute_of_day = minute_of_day
		time_label.text = "时间: %02d:%02d" % [minute_of_day / 60, minute_of_day % 60]


func _on_pause_changed(_paused: bool) -> void:
	_update_speed_display()


# ─────────────────────────────── 通知 ────────────────────────────────

## 发一条通知（统一走 EventBus ui_notification → UIRoot 左下堆叠 feed）
func _notify(title: String, body: String, level: String = "info") -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit(title, body, level)


# ─────────────────────────────── 居中模式 ────────────────────────────────

var _camera_rig: Node = null
var _game_root: Node = null
## 顶栏内嵌资源条（attach_resources 注入）
var _resource_bar: Control = null
## 速度/时间显示脏检查缓存（-1 = 从未写过，首帧必写）
var _last_speed_text: String = ""
var _last_speed_paused: int = -1
var _last_minute_of_day: int = -1


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
		_notify("脱困", "未找到游戏根节点", "error")
		return
	var e: Node2D = gr.get_player_entity() if gr.has_method("get_player_entity") else null
	if e == null or not is_instance_valid(e) or not e.has_method("escape_stuck"):
		_notify("脱困", "未找到玩家实体", "error")
		return
	e.escape_stuck()
	_notify("脱困", "已随机传送到附近空旷地带", "info")


# ─────────────────────────────── 编制管理窗口 ────────────────────────────────

## 打开/关闭编制管理窗口（队伍类型编制：创建/配置编队）
func _on_formation_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		_notify("编制", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_formation_panel"):
		gr.toggle_formation_panel()


# ─────────────────────────────── 设置菜单（齿轮按钮）────────────────────────────────

## 打开占位界面预览（开发用：大界面空面板陈列；经 ModalOverlay 模态展示）
func _on_placeholder_preview_pressed() -> void:
	var gr := _game_root
	if gr == null or not ("ui_root" in gr):
		return
	var overlay: Node = gr.ui_root
	var modal: Control = overlay.get_slot("ModalOverlay")
	if modal == null:
		return
	# 复用暂停菜单的帝国功能陈列入口（同款模态栈管理，ESC 逐层退）
	var pv: Control = preload("res://modules/ui_global/scenes/placeholders/ui_placeholder_preview.tscn").instantiate()
	pv.name = "PlaceholderPreviewInGame"
	modal.add_child(pv)
	var stack := UIModalStack.find(modal)
	if stack != null:
		stack.push(pv, UIModalStack.Layer.EMPIRE_PANEL)


## 打开/关闭设置菜单（调试地图选择/速度控制）
func _on_settings_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		_notify("设置", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_settings_menu"):
		gr.toggle_settings_menu()
