class_name SettingsMenuPanel
extends StickScreen
## 设置菜单 -- 统一弹窗骨架：左分类列 + 右内容区（schema 驱动）。
##
## 由 SystemSetup 装配到 UIRoot；GlobalHUD 齿轮按钮与 ESC 键调 game_root.toggle_settings_menu()。
## 主菜单场景 setup(null) 复用（隐藏调试区与「回到主菜单」）。
## 模态面板生命周期继承自 StickScreen。

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _category_column: VBoxContainer = null
var _content_vbox: VBoxContainer = null

## 面板尺寸
const PANEL_SIZE: Vector2 = Vector2(680, 520)

## 主菜单场景路径（游戏内「回到主菜单」用）
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"

## 地图显示名（map_id -> 中文名；未收录的 id 直接显示原始 id）
const MAP_DISPLAY_NAMES: Dictionary = {
	"village_a": "村落 A（初始村）",
	"village_b": "村落 B",
	"road_a_b": "道路（村落 A↔B）",
	"battlefield": "遭遇战战场",
	"forest_zone": "森林区域",
	"mega_interior": "大建筑内部",
}


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	panel_size = PANEL_SIZE
	panel_title = "设置"
	_build_screen()


# ─────────────────────────────── UI 构建（统一骨架 + schema 驱动）────────────────────────────────

## 构建面板内容：左分类列 + 右内容区（Container 布局）
func _build_content() -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(body)
	# 左：分类列
	_category_column = VBoxContainer.new()
	_category_column.custom_minimum_size = Vector2(140, 0)
	_category_column.add_theme_constant_override("separation", 4)
	body.add_child(_category_column)
	body.add_child(VSeparator.new())
	# 右：滚动内容区（撑满剩余高度）
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	_content_vbox = VBoxContainer.new()
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(_content_vbox)
	_build_sections()
	# 底栏：回主菜单（仅游戏内）+ 关闭
	if _game_root != null:
		StickKit.button(_footer, "保存并回到主菜单", _on_return_to_menu_pressed)
	StickKit.button(_footer, "关闭（ESC）", close)


## 左分类 + 右内容（首个分类=游戏，完整展示；分类切换在 schema 落盘时重建右内容）
func _build_sections() -> void:
	# 分类列按钮
	for cat in SETTINGS_SCHEMA:
		var btn := StickKit.button(_category_column, cat["title"],
				_select_category.bind(cat["id"]), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# 右侧内容：游戏分类（速度控制 + 字段）→ 调试
	_add_section_title("游戏")
	_add_speed_buttons()
	for field in SETTINGS_SCHEMA[0]["fields"]:
		_add_field_row(field)
	if OS.is_debug_build() and _game_root != null:
		_add_section_title("调试 · 测试地图")
		for map_id in _get_registered_map_ids():
			_add_map_button(map_id)
		var tip := Label.new()
		tip.text = "提示：Tab 打开大世界导航 · Q 切换战斗模式 · 顶栏「编制」编队"
		tip.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		tip.modulate = StickTokens.TEXT_DIM
		_content_vbox.add_child(tip)


func _select_category(_cat_id: String) -> void:
	# 演示桩：正式版按分类重建右内容（见 docs/设计/UI/07）
	pass


func _add_section_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", StickTokens.FONT_SECTION)
	label.modulate = StickTokens.ACCENT
	_content_vbox.add_child(label)


## 时间速度控制（暂停/1x/2x/4x）
func _add_speed_buttons() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_content_vbox.add_child(row)
	var speed_map := {
		"暂停": TimeManager.Speed.PAUSED,
		"1x": TimeManager.Speed.X1,
		"2x": TimeManager.Speed.X2,
		"4x": TimeManager.Speed.X4,
	}
	for label_text: String in speed_map.keys():
		var btn := StickKit.button(row, label_text, func():
			if TimeManager != null:
				TimeManager.set_speed(speed_map[label_text])
		, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 设置项字段行（slider / option / toggle，演示桩）
func _add_field_row(field: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, StickTokens.ROW_H)
	_content_vbox.add_child(row)
	var name_l := Label.new()
	name_l.text = field["label"]
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)
	match field["type"]:
		"slider":
			var s := HSlider.new()
			s.min_value = field["min"]
			s.max_value = field["max"]
			s.step = field["step"]
			s.value = field["default"]
			s.custom_minimum_size = Vector2(200, 0)
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(s)
		"option":
			var o := OptionButton.new()
			for i in field["options"].size():
				o.add_item(field["options"][i], i)
			o.selected = field["default"]
			o.custom_minimum_size = Vector2(180, StickTokens.BTN_H)
			row.add_child(o)
		"toggle":
			var c := CheckButton.new()
			c.button_pressed = field["default"]
			row.add_child(c)


## 地图列表从 SceneLoader 注册表动态获取（不硬编码，避免与地图注册重复维护）
func _get_registered_map_ids() -> Array:
	if _game_root == null or _game_root.scene_loader == null:
		return MAP_DISPLAY_NAMES.keys()
	if _game_root.scene_loader.has_method("get_registered_map_ids"):
		var ids: Array = _game_root.scene_loader.get_registered_map_ids()
		if not ids.is_empty():
			return ids
	return MAP_DISPLAY_NAMES.keys()


## 调试地图选择按钮：travel 到目标地图（等效原主页菜单测试场景入口）
func _add_map_button(map_id: String) -> void:
	var btn := StickKit.button(_content_vbox, "前往 %s" % MAP_DISPLAY_NAMES.get(map_id, map_id),
			_on_map_selected.bind(map_id), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT


func _on_map_selected(map_id: String) -> void:
	close()
	if _game_root == null or _game_root.scene_loader == null:
		return
	var current: String = _game_root.scene_loader.get_current_map_id() if _game_root.scene_loader.has_method("get_current_map_id") else ""
	if map_id == current:
		return
	_game_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)


# ─────────────────────────────── 回到主菜单 ────────────────────────────────

func _on_return_to_menu_pressed() -> void:
	StickKit.confirm(self, "回到主菜单", "将保存当前进度（槽位 0）并回到主菜单。",
			_on_return_to_menu_confirmed, "保存并退出")


func _on_return_to_menu_confirmed() -> void:
	close()
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(0)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ─────────────────────────────── 设置项 schema（沿用模板，正式落盘走 ConfigManager）────────────────────────────────

const SETTINGS_SCHEMA: Array[Dictionary] = [
	{
		"id": "game", "title": "游戏",
		"fields": [
			{"key": "autosave_min", "label": "自动存档间隔（分钟）", "type": "slider", "min": 1, "max": 30, "step": 1, "default": 5},
			{"key": "auto_pause_battle", "label": "战斗开始时自动暂停", "type": "toggle", "default": true},
			{"key": "slow_on_possess", "label": "附身微操时自动减速", "type": "toggle", "default": true},
			{"key": "ui_fade_zoom", "label": "缩放时 UI 渐隐渐显", "type": "toggle", "default": true},
		],
	},
	{
		"id": "video", "title": "画面",
		"fields": [
			{"key": "window_mode", "label": "窗口模式", "type": "option", "options": ["窗口化", "无边框全屏", "独占全屏"], "default": 1},
			{"key": "ui_scale", "label": "界面缩放", "type": "slider", "min": 75, "max": 150, "step": 5, "default": 100},
			{"key": "show_fps", "label": "显示 FPS", "type": "toggle", "default": false},
		],
	},
	{
		"id": "audio", "title": "音频",
		"fields": [
			{"key": "vol_master", "label": "主音量", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 80},
			{"key": "vol_music", "label": "音乐", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 60},
			{"key": "vol_sfx", "label": "音效", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 80},
			{"key": "mute_when_unfocused", "label": "失焦时静音", "type": "toggle", "default": true},
		],
	},
	{
		"id": "control", "title": "控制",
		"fields": [
			{"key": "edge_scroll", "label": "屏幕边缘滚动镜头", "type": "toggle", "default": true},
			{"key": "edge_scroll_speed", "label": "边缘滚动速度", "type": "slider", "min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "zoom_speed", "label": "缩放速度", "type": "slider", "min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "middle_drag", "label": "中键拖拽平移", "type": "toggle", "default": true},
		],
	},
	{
		"id": "debug", "title": "调试",
		"fields": [
			{"key": "debug_overlay", "label": "调试覆盖层（F3）", "type": "toggle", "default": false},
			{"key": "debug_legend", "label": "常驻调试图例", "type": "toggle", "default": true},
			{"key": "log_level", "label": "日志级别", "type": "option", "options": ["ERROR", "WARN", "INFO", "DEBUG"], "default": 2},
		],
	},
]
