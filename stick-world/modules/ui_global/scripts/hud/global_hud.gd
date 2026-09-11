class_name GlobalHUD
extends Control
## 全局 HUD —— 顶层常驻 UI。
##
## 顶栏左段=按钮群（编制+帝国功能常驻入口+居中/脱困/预览+设置）；速度控制
## 收进右上角时钟的 P 社式速度弧（ClockWidget 下半圆四段，点击调速），天数/
## 时间显示在时钟正下方；资源条为顶栏下方左侧横条（ResourceBarHost，
## attach_resources 注入，避开顶部中央小地图）。

const _ResourceBarScript: GDScript = preload("res://modules/ui_global/scripts/hud/resource_bar.gd")

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var day_time_label: Label = get_node_or_null("DayTimeLabel")
@onready var centered_button: Button = get_node_or_null("MarginContainer/HBoxContainer/CenteredButton")
@onready var formation_button: Button = get_node_or_null("MarginContainer/HBoxContainer/FormationButton")
@onready var org_button: Button = get_node_or_null("MarginContainer/HBoxContainer/OrgButton")
@onready var settings_button: Button = get_node_or_null("MarginContainer/HBoxContainer/SettingsButton")
## 占位界面预览入口（开发用）：打开占位预览面板（大界面空面板陈列）
@onready var placeholder_preview_button: Button = get_node_or_null("MarginContainer/HBoxContainer/PlaceholderPreviewButton")
## 帝国功能入口（顶栏常驻，占位面板先行——系统落地后换真实面板）
const EMPIRE_PRESETS: Dictionary = {
	"OverviewButton": "empire_overview", "TechButton": "tech_tree",
	"LogisticsButton": "logistics", "CollectionButton": "collection",
}
## 材料面板（顶栏下方左侧横条，ResourceBar 挂这里）
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
	if centered_button != null:
		centered_button.pressed.connect(_on_centered_button_pressed)
		_update_centered_button_text()
	if formation_button != null:
		formation_button.pressed.connect(_on_formation_button_pressed)
	if org_button != null:
		org_button.pressed.connect(_on_org_button_pressed)
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_button_pressed)
	if placeholder_preview_button != null:
		placeholder_preview_button.pressed.connect(_on_placeholder_preview_pressed)
	for node_name: String in EMPIRE_PRESETS:
		var btn: Button = get_node_or_null("MarginContainer/HBoxContainer/" + node_name)
		if btn != null:
			btn.pressed.connect(_on_empire_panel_pressed.bind(EMPIRE_PRESETS[node_name]))


func _process(_delta: float) -> void:
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
	# victory 语义 = 玩家阵营胜（C2 修正；攻方/守方双场景下按阵营报我方胜负）
	var result: String = "我方获胜" if victory else "我方战败"
	_notify("战斗", "战斗结束：%s" % result, "info")


# ─────────────────────────────── 更新显示 ────────────────────────────────

func _update_time_display() -> void:
	if day_time_label == null:
		return
	# 优先从 WorldState 读取；按"当日分钟数"脏检查，分钟没跳过不重写
	if WorldState:
		var t: float = WorldState.game_time
		var minute_of_day: int = int(t * 60.0) % 1440
		var day: int = int(t / 24.0) + 1
		if minute_of_day == _last_minute_of_day and day == _last_day:
			return
		_last_minute_of_day = minute_of_day
		_last_day = day
		day_time_label.text = "第%d天 %02d:%02d" % [day, minute_of_day / 60, minute_of_day % 60]


func _on_pause_changed(_paused: bool) -> void:
	pass  # 速度弧高亮由 ClockWidget 自行监听 TimeManager 状态驱动


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
## 时间显示脏检查缓存（-1 = 从未写过，首帧必写）
var _last_minute_of_day: int = -1
var _last_day: int = -1


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


# 脱离卡死已迁设置面板（游戏分类）——自救类功能按行业惯例收进设置/帮助页，
# 不占主界面按钮位；HUD 侧 H 键快捷通道仍在（game_root 按键处理）


# ─────────────────────────────── 编制管理窗口 ────────────────────────────────

## 帝国功能占位面板（总览/科技/物流/成就——顶栏常驻入口，系统落地前开空面板）
func _on_empire_panel_pressed(preset_id: String) -> void:
	var gr := _game_root
	if gr == null or not ("ui_root" in gr):
		return
	var overlay: Node = gr.ui_root
	var modal: Control = overlay.get_slot("ModalOverlay")
	if modal == null:
		return
	UIPlaceholderPanel.open_panel(modal, preset_id)


## 打开/关闭编制管理窗口（队伍类型编制：创建/配置编队）
func _on_formation_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		_notify("编制", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_formation_panel"):
		gr.toggle_formation_panel()


# ─────────────────────────────── 组织管理窗口 ────────────────────────────────

## 打开/关闭组织管理窗口（通用组织树：任命统辖/层级/人事/预设）
func _on_org_button_pressed() -> void:
	var gr := _game_root
	if gr == null:
		_notify("组织", "未找到游戏根节点", "error")
		return
	if gr.has_method("toggle_org_panel"):
		gr.toggle_org_panel()


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
	# 复用暂停菜单的功能面板陈列入口（同款模态栈管理，ESC 逐层退）
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
