class_name HudTemplate
extends Control
## 游戏内 HUD 模板 —— 顶栏（速度/时间/资源/系统键）+ 小地图框 + 底部快捷栏 + 通知流。
##
## 设计要点（详见 docs/设计/UI/04-游戏内HUD.md）：
## - 三段式顶栏：左=时间控制，中=资源（数据驱动），右=系统入口
## - 快捷栏密集堆叠（博德之门3 式满足感）：格子由 QUICK_SLOTS 数据生成
## - HUD 根节点 mouse_filter=IGNORE（不挡游戏操作），控件子节点自收事件
## - 落地时数据接 TimeManager / resources_api / EventBus.ui_notification；
##   本模板用演示数据自转（定时器模拟资源增减/通知流入）
##
## F6 直接运行可预览。

const INDEX_SCENE := "res://modules/ui_global/scenes/templates/template_index.tscn"

## 时间速度档（落地接 TimeManager.Speed）
const SPEEDS: Array[Dictionary] = [
	{"id": "pause", "label": "‖", "tip": "暂停（空格）"},
	{"id": "x1", "label": "1x", "tip": "常速（1）"},
	{"id": "x2", "label": "2x", "tip": "双倍（2）"},
	{"id": "x4", "label": "4x", "tip": "四倍（3）"},
]

## 资源槽（落地接 resources_api；icon 暂用单字占位，资产到位后换 TextureRect）
const RESOURCES: Array[Dictionary] = [
	{"id": "res_wood", "icon": "木", "name": "木材", "amount": 150},
	{"id": "res_stone", "icon": "石", "name": "石料", "amount": 90},
	{"id": "res_metal", "icon": "铁", "name": "金属矿", "amount": 34},
	{"id": "res_asphalt", "icon": "沥", "name": "黑色沥青", "amount": 12},
]

## 快捷栏格子（堆叠满足感：icon 占位 + 角标热键 + 数量徽标）
const QUICK_SLOTS: Array[Dictionary] = [
	{"icon": "剑", "key": "1", "count": 0, "tip": "攻击指令"},
	{"icon": "盾", "key": "2", "count": 0, "tip": "防御指令"},
	{"icon": "旗", "key": "3", "count": 2, "tip": "集结点"},
	{"icon": "镐", "key": "4", "count": 0, "tip": "建造"},
	{"icon": "包", "key": "5", "count": 8, "tip": "搬运"},
	{"icon": "研", "key": "6", "count": 0, "tip": "科研"},
	{"icon": "仓", "key": "7", "count": 1, "tip": "仓库"},
	{"icon": "医", "key": "8", "count": 3, "tip": "医疗"},
	{"icon": "马", "key": "9", "count": 0, "tip": "行军"},
	{"icon": "书", "key": "0", "count": 0, "tip": "法令"},
]

## 通知演示流
const DEMO_NOTICES: Array[Dictionary] = [
	{"text": "搬运完成：木材 +20", "kind": "info"},
	{"text": "石料储备不足", "kind": "warn"},
	{"text": "敌军出现在东侧道路", "kind": "error"},
	{"text": "研究完成：燧石打磨", "kind": "info"},
]

@onready var _top_row: HBoxContainer = $TopBar/TopRow
@onready var _slots_row: HBoxContainer = $Quickbar/SlotsRow
@onready var _feed: VBoxContainer = $NotificationFeed
@onready var _minimap_label: Label = $MinimapFrame/MinimapLabel
@onready var _zoom_widget: VBoxContainer = $ZoomWidget

var _speed_buttons: Dictionary = {}
var _resource_labels: Dictionary = {}
var _amounts: Dictionary = {}
var _time_label: Label = null
var _game_minutes: float = 8 * 60.0
var _notice_idx: int = 0
var _active_speed: String = "x1"


func _ready() -> void:
	theme = StickTheme.create()
	_build_top_bar()
	_build_quickbar()
	_build_zoom_widget()
	_minimap_label.modulate = StickTokens.TEXT_FAINT
	# 演示驱动：游戏时间走字 + 资源波动 + 通知流入（落地时换信号驱动）
	var ticker := Timer.new()
	ticker.wait_time = 1.0
	ticker.autostart = true
	ticker.timeout.connect(_on_demo_tick)
	add_child(ticker)


# ─────────────────────────────── 顶栏 ────────────────────────────────

func _build_top_bar() -> void:
	# 左：速度控制组
	for s in SPEEDS:
		var btn := StickKit.button(_top_row, s["label"],
				_on_speed_pressed.bind(s["id"]), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		btn.custom_minimum_size = Vector2(44, StickTokens.BTN_H_SM)
		btn.tooltip_text = s["tip"]
		_speed_buttons[s["id"]] = btn
	_refresh_speed_highlight()
	_time_label = StickKit.label(_top_row, "第1天 08:00", StickKit.LabelKind.BODY)
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 中：弹簧 + 资源槽
	var spring := Control.new()
	spring.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_row.add_child(spring)
	for res in RESOURCES:
		_amounts[res["id"]] = res["amount"]
		_build_resource_slot(res)
	var spring2 := Control.new()
	spring2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_row.add_child(spring2)
	# 右：系统入口（编制/地图/设置 + 模板导航）
	for entry in ["编制", "地图", "设置"]:
		var btn := StickKit.button(_top_row, entry, func():
			_push_notice("打开「%s」面板（演示桩）" % entry, "info")
		, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		btn.tooltip_text = "打开%s面板" % entry
	StickKit.button(_top_row, "总览", func():
		get_tree().change_scene_to_file(INDEX_SCENE)
	, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)


func _build_resource_slot(res: Dictionary) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_top_row.add_child(box)
	var icon := StickKit.label(box, res["icon"], StickKit.LabelKind.BODY)
	icon.modulate = StickTokens.ACCENT
	icon.tooltip_text = res["name"]
	var amount := StickKit.label(box, str(_amounts[res["id"]]), StickKit.LabelKind.BODY)
	amount.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_resource_labels[res["id"]] = amount


# ─────────────────────────────── 快捷栏 ────────────────────────────────

func _build_quickbar() -> void:
	for slot in QUICK_SLOTS:
		_slots_row.add_child(_make_slot(slot))


func _make_slot(slot: Dictionary) -> PanelContainer:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(52, 48)
	cell.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	cell.tooltip_text = slot["tip"]
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	cell.add_child(stack)
	var top := HBoxContainer.new()
	stack.add_child(top)
	var key := StickKit.label(top, slot["key"], StickKit.LabelKind.TINY)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 数量徽标（0 不显示）
	if slot["count"] > 0:
		var badge := StickKit.label(top, str(slot["count"]), StickKit.LabelKind.TINY, StickTokens.WARN)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var icon := StickKit.label(stack, slot["icon"], StickKit.LabelKind.BODY)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", StickTokens.FONT_SECTION + 3)
	# 点击演示：按下态闪烁 + 通知
	cell.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_push_notice("触发槽位：%s" % slot["tip"], "info")
	)
	return cell


# ─────────────────────────────── 缩放部件 ────────────────────────────────

func _build_zoom_widget() -> void:
	var zoom_out := StickKit.button(_zoom_widget, "＋", func(): _push_notice("放大（演示）", "info"),
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	zoom_out.tooltip_text = "放大（滚轮）"
	var bar := VSeparator.new()
	bar.custom_minimum_size = Vector2(0, 24)
	_zoom_widget.add_child(bar)
	var zoom_in := StickKit.button(_zoom_widget, "－", func(): _push_notice("缩小（演示）", "info"),
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	zoom_in.tooltip_text = "缩小（滚轮）"


# ─────────────────────────────── 演示驱动 ────────────────────────────────

func _on_demo_tick() -> void:
	# 时间走字（4x 演示感：每次 +10 分钟）
	_game_minutes += 10.0
	var day: int = int(_game_minutes / 1440.0) + 1
	var hour: int = int(_game_minutes / 60.0) % 24
	var minute: int = int(_game_minutes) % 60
	_time_label.text = "第%d天 %02d:%02d" % [day, hour, minute]
	# 资源波动
	for res in RESOURCES:
		var id: String = res["id"]
		_amounts[id] = max(0, _amounts[id] + randi_range(-3, 5))
		_resource_labels[id].text = str(_amounts[id])
	# 每 3 秒推一条通知
	if Engine.get_process_frames() % 3 == 0:
		var n: Dictionary = DEMO_NOTICES[_notice_idx % DEMO_NOTICES.size()]
		_notice_idx += 1
		_push_notice(n["text"], n["kind"])


func _on_speed_pressed(speed_id: String) -> void:
	_active_speed = speed_id
	_refresh_speed_highlight()
	_push_notice("时间速度 → %s" % speed_id, "info")


func _refresh_speed_highlight() -> void:
	for id in _speed_buttons:
		var btn: Button = _speed_buttons[id]
		if id == _active_speed:
			btn.add_theme_stylebox_override("normal", StickStyle.accent_normal())
			btn.add_theme_color_override("font_color", StickTokens.ACCENT)
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_color_override("font_color")


## 通知流：堆叠式 feed，最多 5 条，旧条自动淡出
func _push_notice(text: String, kind: String) -> void:
	while _feed.get_child_count() >= 5:
		_feed.get_child(0).queue_free()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	var color := StickTokens.INFO
	if kind == "warn":
		color = StickTokens.WARN
	elif kind == "error":
		color = StickTokens.DANGER
	StickKit.label(panel, text, StickKit.LabelKind.HINT, color)
	_feed.add_child(panel)
	var tween := panel.create_tween()
	tween.tween_interval(StickTokens.T_TOAST)
	tween.tween_property(panel, "modulate:a", 0.0, StickTokens.T_PANEL * 2)
	tween.tween_callback(panel.queue_free)
