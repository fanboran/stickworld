class_name SettingsTemplate
extends Control
## 设置界面模板 —— 左分类列 + 右内容区，整页由 SETTINGS_SCHEMA 数据驱动。
##
## 设计要点（详见 docs/设计/UI/07-设置界面.md）：
## - 加一项设置 = 在 SETTINGS_SCHEMA 里加一行 Dictionary，不写 UI 代码
## - 字段类型：slider（数值滑条）/ option（下拉）/ toggle（开关）
## - 落地时"应用"回调写 ConfigManager；演示桩只收进 _values 并 toast
##
## F6 直接运行可预览。

const INDEX_SCENE := "res://modules/ui_global/scenes/templates/template_index.tscn"

## 设置项 schema：分类 → 字段列表。type: slider / option / toggle
const SETTINGS_SCHEMA: Array[Dictionary] = [
	{
		"id": "game", "title": "游戏",
		"fields": [
			{"key": "autosave_min", "label": "自动存档间隔（分钟）", "type": "slider",
				"min": 1, "max": 30, "step": 1, "default": 5},
			{"key": "auto_pause_battle", "label": "战斗开始时自动暂停", "type": "toggle", "default": true},
			{"key": "slow_on_possess", "label": "附身微操时自动减速", "type": "toggle", "default": true},
			{"key": "ui_fade_zoom", "label": "缩放时 UI 渐隐渐显", "type": "toggle", "default": true},
		],
	},
	{
		"id": "video", "title": "画面",
		"fields": [
			{"key": "window_mode", "label": "窗口模式", "type": "option",
				"options": ["窗口化", "无边框全屏", "独占全屏"], "default": 1},
			{"key": "ui_scale", "label": "界面缩放", "type": "slider",
				"min": 75, "max": 150, "step": 5, "default": 100},
			{"key": "show_fps", "label": "显示 FPS", "type": "toggle", "default": false},
		],
	},
	{
		"id": "audio", "title": "音频",
		"fields": [
			{"key": "vol_master", "label": "主音量", "type": "slider",
				"min": 0, "max": 100, "step": 1, "default": 80},
			{"key": "vol_music", "label": "音乐", "type": "slider",
				"min": 0, "max": 100, "step": 1, "default": 60},
			{"key": "vol_sfx", "label": "音效", "type": "slider",
				"min": 0, "max": 100, "step": 1, "default": 80},
			{"key": "mute_when_unfocused", "label": "失焦时静音", "type": "toggle", "default": true},
		],
	},
	{
		"id": "control", "title": "控制",
		"fields": [
			{"key": "edge_scroll", "label": "屏幕边缘滚动镜头", "type": "toggle", "default": true},
			{"key": "edge_scroll_speed", "label": "边缘滚动速度", "type": "slider",
				"min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "zoom_speed", "label": "缩放速度", "type": "slider",
				"min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "middle_drag", "label": "中键拖拽平移", "type": "toggle", "default": true},
		],
	},
	{
		"id": "debug", "title": "调试",
		"fields": [
			{"key": "debug_overlay", "label": "调试覆盖层（F3）", "type": "toggle", "default": false},
			{"key": "debug_legend", "label": "常驻调试图例", "type": "toggle", "default": true},
			{"key": "log_level", "label": "日志级别", "type": "option",
				"options": ["ERROR", "WARN", "INFO", "DEBUG"], "default": 2},
		],
	},
]

@onready var _category_column: VBoxContainer = $Window/MainVBox/Body/CategoryColumn
@onready var _content_vbox: VBoxContainer = $Window/MainVBox/Body/ContentScroll/ContentVBox
@onready var _title_label: Label = $Window/MainVBox/Header/TitleLabel
@onready var _close_button: Button = $Window/MainVBox/Header/CloseButton
@onready var _footer: HBoxContainer = $Window/MainVBox/Footer

## 当前值表：key -> 值（落地时与 ConfigManager 双向同步）
var _values: Dictionary = {}
var _active_category: String = ""
var _category_buttons: Dictionary = {}


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_close_button.pressed.connect(func(): get_tree().change_scene_to_file(INDEX_SCENE))
	_init_defaults()
	_build_categories()
	_build_footer()
	_select_category(SETTINGS_SCHEMA[0]["id"])


func _init_defaults() -> void:
	for cat in SETTINGS_SCHEMA:
		for field in cat["fields"]:
			_values[field["key"]] = field["default"]


# ─────────────────────────────── 左列分类 ────────────────────────────────

func _build_categories() -> void:
	for cat in SETTINGS_SCHEMA:
		var btn := StickKit.button(_category_column, cat["title"],
				_select_category.bind(cat["id"]), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_category_buttons[cat["id"]] = btn


func _select_category(cat_id: String) -> void:
	_active_category = cat_id
	for id in _category_buttons:
		var btn: Button = _category_buttons[id]
		# 选中态：琥珀描边 + 琥珀字
		if id == cat_id:
			btn.add_theme_stylebox_override("normal", StickStyle.accent_normal())
			btn.add_theme_color_override("font_color", StickTokens.ACCENT)
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_color_override("font_color")
	_rebuild_content()


# ─────────────────────────────── 右侧内容（schema → 控件）────────────────────────────────

func _rebuild_content() -> void:
	for child in _content_vbox.get_children():
		child.queue_free()
	var cat: Dictionary = _find_category(_active_category)
	if cat.is_empty():
		return
	for field in cat["fields"]:
		_build_field(field)


func _build_field(field: Dictionary) -> void:
	var row := StickKit.field_row(_content_vbox, field["label"])
	var key: String = field["key"]
	match field["type"]:
		"slider":
			var value_label := StickKit.label(row, "", StickKit.LabelKind.BODY)
			value_label.custom_minimum_size = Vector2(44, 0)
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			var slider := HSlider.new()
			slider.min_value = field["min"]
			slider.max_value = field["max"]
			slider.step = field["step"]
			slider.value = _values[key]
			slider.custom_minimum_size = Vector2(220, 0)
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(slider)
			value_label.text = str(int(slider.value))
			slider.value_changed.connect(func(v: float):
				_values[key] = v
				value_label.text = str(int(v))
			)
		"option":
			var opt := OptionButton.new()
			for i in field["options"].size():
				opt.add_item(field["options"][i], i)
			opt.selected = _values[key]
			opt.custom_minimum_size = Vector2(200, StickTokens.BTN_H)
			row.add_child(opt)
			opt.item_selected.connect(func(idx: int): _values[key] = idx)
		"toggle":
			var chk := CheckButton.new()
			chk.button_pressed = _values[key]
			row.add_child(chk)
			chk.toggled.connect(func(on: bool): _values[key] = on)


func _find_category(cat_id: String) -> Dictionary:
	for cat in SETTINGS_SCHEMA:
		if cat["id"] == cat_id:
			return cat
	return {}


# ─────────────────────────────── 底栏 ────────────────────────────────

func _build_footer() -> void:
	StickKit.button(_footer, "恢复默认", func():
		_init_defaults()
		_rebuild_content()
		StickKit.toast(self, "已恢复默认值", "info")
	)
	StickKit.button(_footer, "应用", func():
		# 落地：for key in _values: ConfigManager.set_value(...)；再 write_to_disk
		StickKit.toast(self, "已应用 %d 项设置（演示桩）" % _values.size(), "info")
	, StickKit.ButtonKind.ACCENT)
