class_name SettingsMenuPanel
extends StickScreen
## 设置菜单 -- 统一弹窗骨架：左分类列 + 右内容区（schema 驱动，分类切换真实生效）。
##
## 由 SystemSetup 装配到 UIRoot；GlobalHUD 齿轮按钮 / 暂停菜单「设置」打开。
## 主菜单场景 setup(null) 复用（隐藏调试区与「回到主菜单」）。
## 模态面板生命周期继承自 StickScreen。

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _category_column: VBoxContainer = null
var _content_vbox: VBoxContainer = null
## 当前分类 id
var _active_category: String = "game"
## 分类按钮 id -> Button（高亮选中态）
var _category_buttons: Dictionary = {}
## 当前设置值：key -> value（应用时写 ConfigManager）
var _values: Dictionary = {}

## 面板尺寸（充分容纳分类 + 字段，不做小面板）
const PANEL_SIZE: Vector2 = Vector2(880, 620)

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


# ─────────────────────────────── UI 构建 ────────────────────────────────

## 构建面板内容：左分类列 + 右内容区 + 底栏（Container 布局）
func _build_content() -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(body)
	# 左：分类列
	_category_column = VBoxContainer.new()
	_category_column.custom_minimum_size = Vector2(150, 0)
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
	# 分类列按钮
	for cat in SETTINGS_SCHEMA:
		var btn := StickKit.auto_button(_category_column, cat["title"],
				_select_category.bind(cat["id"]), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_category_buttons[cat["id"]] = btn
	# 初始值 + 内容
	_init_values()
	_select_category("game")
	# 底栏：应用 / 恢复默认 / 回主菜单（仅游戏内）/ 关闭
	StickKit.auto_button(_footer, "恢复默认", _on_reset_defaults)
	StickKit.auto_button(_footer, "应用", _on_apply, StickKit.ButtonKind.ACCENT)
	if _game_root != null:
		StickKit.auto_button(_footer, "保存并回到主菜单", _on_return_to_menu_pressed)
	StickKit.auto_button(_footer, "关闭（ESC）", close)


## 初始值：schema 默认（可被 ConfigManager 已存值覆盖）
func _init_values() -> void:
	_values = {}
	for cat in SETTINGS_SCHEMA:
		for field in cat["fields"]:
			var def_val: Variant = field["default"]
			var key: String = field["key"]
			if ConfigManager and ConfigManager.has_method("get_value") \
					and ConfigManager.get_value(key) != null:
				_values[key] = _normalize_stored_value(key, ConfigManager.get_value(key))
			else:
				_values[key] = def_val


## 存量值归一化：音量键历史上存 0~1 线性（ConfigManager/AudioManager 域），
## 设置面板域用 0~100 百分比；读到 ≤1 的旧线性值时换算成百分比显示。
func _normalize_stored_value(key: String, raw: Variant) -> Variant:
	if key in _VOLUME_KEYS and typeof(raw) in [TYPE_FLOAT, TYPE_INT] and float(raw) <= 1.0:
		return int(round(float(raw) * 100.0))
	return raw


# ─────────────────────────────── 分类切换（真实生效）────────────────────────────────

func _select_category(cat_id: String) -> void:
	_active_category = cat_id
	# 分类按钮高亮：游戏内 SketchButton 切 kind（手绘琥珀描边）；
	# 主菜单原生 Button 走 override（玻璃琥珀底）
	for id in _category_buttons:
		var btn: Button = _category_buttons[id]
		var selected: bool = id == cat_id
		if btn is SketchButton:
			btn.kind = SketchButton.Kind.ACCENT if selected else SketchButton.Kind.NORMAL
		elif selected:
			btn.add_theme_stylebox_override("normal", GlassStyle.accent_normal())
			btn.add_theme_color_override("font_color", StickTokens.ACCENT)
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_color_override("font_color")
	_rebuild_content()


## 按当前分类重建右侧内容区
func _rebuild_content() -> void:
	for child in _content_vbox.get_children():
		child.queue_free()
	var cat := _find_category(_active_category)
	if cat.is_empty():
		return
	_add_section_title(cat["title"])
	# 游戏分类：速度控制是特例（操作类，非持久化设置项）
	if _active_category == "game":
		_add_speed_buttons()
	for field in cat["fields"]:
		_add_field_row(field)
	# 调试分类：调试构建 + 游戏内时追加测试地图入口
	if _active_category == "debug" and OS.is_debug_build() and _game_root != null:
		_add_section_title("测试地图")
		for map_id in _get_registered_map_ids():
			_add_map_button(map_id)
		var tip := Label.new()
		tip.text = "提示：Tab 打开大世界导航 · Q 切换战斗模式 · 顶栏「编制」编队"
		tip.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		tip.modulate = StickTokens.TEXT_DIM
		_content_vbox.add_child(tip)


func _find_category(cat_id: String) -> Dictionary:
	for cat in SETTINGS_SCHEMA:
		if cat["id"] == cat_id:
			return cat
	return {}


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
		var btn := StickKit.auto_button(row, label_text, func():
			if TimeManager != null:
				TimeManager.set_speed(speed_map[label_text])
		, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 设置项字段行（slider / option / toggle），值变化写入 _values。
## 未实装字段（field.implemented == false）：整体降透明度 + 控件禁用 + 「未实装」标注。
func _add_field_row(field: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, StickTokens.ROW_H)
	_content_vbox.add_child(row)
	var key: String = field["key"]
	var implemented: bool = bool(field.get("implemented", true))
	var name_l := Label.new()
	name_l.text = field["label"] + ("" if implemented else "（未实装）")
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)
	if not implemented:
		name_l.modulate = StickTokens.TEXT_DIM
		row.tooltip_text = "该选项尚未实装"
	var widget: Control = null
	match field["type"]:
		"slider":
			var s := HSlider.new()
			s.min_value = field["min"]
			s.max_value = field["max"]
			s.step = field["step"]
			s.value = _values[key]
			s.custom_minimum_size = Vector2(240, 0)
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(s)
			s.value_changed.connect(func(v: float): _values[key] = v)
			widget = s
		"option":
			var o := OptionButton.new()
			for i in field["options"].size():
				o.add_item(field["options"][i], i)
			o.selected = _values[key]
			o.custom_minimum_size = Vector2(220, StickTokens.BTN_H)
			row.add_child(o)
			o.item_selected.connect(func(idx: int): _values[key] = idx)
			widget = o
		"toggle":
			var c := CheckButton.new()
			c.button_pressed = _values[key]
			row.add_child(c)
			c.toggled.connect(func(on: bool): _values[key] = on)
			widget = c
	if not implemented and widget != null:
		row.modulate = Color(1.0, 1.0, 1.0, 0.5)
		widget.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if widget is OptionButton or widget is CheckButton:
			widget.disabled = true


# ─────────────────────────────── 应用 / 恢复 ────────────────────────────────

## 应用：把 _values 写入 ConfigManager 并落盘，同时把已实装项立即接线到真实系统。
func _on_apply() -> void:
	var written: int = 0
	if ConfigManager and ConfigManager.has_method("set_value"):
		for key in _values:
			# 音量键：面板域 0~100 百分比 -> 存储域 0~1 线性（AudioManager/ConfigManager 约定）
			var stored: Variant = _values[key]
			if key in _VOLUME_KEYS and typeof(stored) in [TYPE_FLOAT, TYPE_INT]:
				stored = clampf(float(stored) / 100.0, 0.0, 1.0)
			ConfigManager.set_value(key, stored)
			written += 1
			_apply_live_setting(key, _values[key])
	if ConfigManager and ConfigManager.has_method("save_to_disk"):
		ConfigManager.save_to_disk()
	StickKit.toast(self, "已应用 %d 项设置" % written, "info")


## 已实装设置项的即时生效（不改 ConfigManager，只调真实系统）。
## 未实装项（schema implemented=false）不在此列。
func _apply_live_setting(key: String, value: Variant) -> void:
	match key:
		"game/auto_save_interval_sec", "game/auto_pause_battle":
			pass  # 消费方（SaveManager / TimeManager）实时读 ConfigManager
		"game/slow_on_possess":
			if TimeManager:
				TimeManager.auto_slow_on_possess = bool(value)
		"video/window_mode":
			if ConfigManager and ConfigManager.has_method("apply_window_mode"):
				ConfigManager.apply_window_mode(int(value))
		"video/ui_scale":
			get_window().content_scale_factor = float(value) / 100.0
		"video/show_fps":
			_set_fps_counter_visible(bool(value))
		"audio/master_volume":
			if AudioManager and AudioManager.has_method("set_volume"):
				AudioManager.set_volume("master", float(value) / 100.0)
		"audio/bgm_volume":
			if AudioManager and AudioManager.has_method("set_volume"):
				AudioManager.set_volume("bgm", float(value) / 100.0)
		"audio/sfx_volume":
			if AudioManager and AudioManager.has_method("set_volume"):
				AudioManager.set_volume("sfx", float(value) / 100.0)
		"audio/mute_when_unfocused":
			if AudioManager and AudioManager.has_method("set_mute_on_unfocus"):
				AudioManager.set_mute_on_unfocus(bool(value))
		"control/edge_scroll":
			var cam := _camera()
			if cam != null and cam.has_method("set_user_edge_scroll"):
				cam.set_user_edge_scroll(bool(value))
		"control/edge_scroll_speed":
			var cam2 := _camera()
			if cam2 != null and cam2.has_method("set_edge_scroll_speed"):
				cam2.set_edge_scroll_speed(float(value))
		"control/zoom_speed":
			var cam3 := _camera()
			if cam3 != null and cam3.has_method("set_zoom_speed"):
				cam3.set_zoom_speed(float(value))
		"control/middle_drag":
			var cam4 := _camera()
			if cam4 != null and cam4.has_method("set_middle_drag_enabled"):
				cam4.set_middle_drag_enabled(bool(value))
		"debug/overlay":
			if DebugApi and DebugApi.has_method("set_overlay_visible"):
				DebugApi.set_overlay_visible(bool(value))
		"debug/legend":
			if DebugApi:
				if bool(value):
					DebugApi.show_legend()
				else:
					DebugApi.hide_legend()


func _camera() -> Node:
	if _game_root == null:
		return null
	return _game_root.get("camera_rig") if "camera_rig" in _game_root else null


## 显示/隐藏 FPS 计数器（经 UIRoot 槽；无 UIRoot（主菜单）时静默跳过）
func _set_fps_counter_visible(v: bool) -> void:
	if _game_root == null or _game_root.ui_root == null:
		return
	if _game_root.ui_root.has_method("set_fps_counter_visible"):
		_game_root.ui_root.set_fps_counter_visible(v)


## 恢复默认：_values 重置 + 重建内容
func _on_reset_defaults() -> void:
	StickKit.confirm(self, "恢复默认", "将把全部设置重置为默认值。确定吗？",
			_confirm_reset, "重置")


func _confirm_reset() -> void:
	_init_values()
	_rebuild_content()
	if ConfigManager and ConfigManager.has_method("reset_to_defaults"):
		ConfigManager.reset_to_defaults()
		ConfigManager.save_to_disk()
	StickKit.toast(self, "已恢复默认值", "info")


# ─────────────────────────────── 调试地图 ────────────────────────────────

func _get_registered_map_ids() -> Array:
	if _game_root == null or _game_root.scene_loader == null:
		return MAP_DISPLAY_NAMES.keys()
	if _game_root.scene_loader.has_method("get_registered_map_ids"):
		var ids: Array = _game_root.scene_loader.get_registered_map_ids()
		if not ids.is_empty():
			return ids
	return MAP_DISPLAY_NAMES.keys()


func _add_map_button(map_id: String) -> void:
	var btn := StickKit.auto_button(_content_vbox, "前往 %s" % MAP_DISPLAY_NAMES.get(map_id, map_id),
			_on_map_selected.bind(map_id), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT


func _on_map_selected(map_id: String) -> void:
	close()
	if _game_root == null or _game_root.scene_loader == null:
		return
	var current: String = _game_root.scene_loader.get_current_map_id() if _game_root.scene_loader.has_method("get_current_map_id") else ""
	if map_id == current:
		return
	# 步行旅行、左侧进入（scene_loader 默认值）；不 import WorldAPI，避免 ui_global↔world 依赖环
	_game_root.scene_loader.travel_to_map(map_id)


# ─────────────────────────────── 回到主菜单 ────────────────────────────────

func _on_return_to_menu_pressed() -> void:
	StickKit.confirm(self, "回到主菜单", "将保存当前进度（槽位 0）并回到主菜单。",
			_on_return_to_menu_confirmed, "保存并退出")


func _on_return_to_menu_confirmed() -> void:
	close()
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(0)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ─────────────────────────────── 设置项 schema ────────────────────────────────

## 音量键（面板域 0~100 百分比；存储域 0~1 线性，通道与 ConfigManager.VOLUME_CHANNELS
## 一致：master/bgm/sfx，见 _on_apply 换算）
const _VOLUME_KEYS: Array[String] = ["audio/master_volume", "audio/bgm_volume", "audio/sfx_volume"]

const SETTINGS_SCHEMA: Array[Dictionary] = [
	{
		"id": "game", "title": "游戏",
		"fields": [
			{"key": "game/auto_save_interval_sec", "label": "自动存档间隔（秒）", "type": "slider", "min": 30, "max": 600, "step": 30, "default": 60},
			{"key": "game/auto_pause_battle", "label": "战斗开始时自动暂停", "type": "toggle", "default": true},
			{"key": "game/slow_on_possess", "label": "附身微操时自动减速", "type": "toggle", "default": true},
			{"key": "game/ui_fade_zoom", "label": "缩放时 UI 渐隐渐显", "type": "toggle", "default": true, "implemented": false},
		],
	},
	{
		"id": "video", "title": "画面",
		"fields": [
			{"key": "video/window_mode", "label": "窗口模式", "type": "option", "options": ["窗口化", "无边框全屏", "独占全屏"], "default": 0},
			{"key": "video/ui_scale", "label": "界面缩放", "type": "slider", "min": 75, "max": 150, "step": 5, "default": 100},
			{"key": "video/show_fps", "label": "显示 FPS", "type": "toggle", "default": false},
		],
	},
	{
		"id": "audio", "title": "音频",
		"fields": [
			{"key": "audio/master_volume", "label": "主音量", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 80},
			{"key": "audio/bgm_volume", "label": "音乐", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 70},
			{"key": "audio/sfx_volume", "label": "音效", "type": "slider", "min": 0, "max": 100, "step": 1, "default": 90},
			{"key": "audio/mute_when_unfocused", "label": "失焦时静音", "type": "toggle", "default": true},
		],
	},
	{
		"id": "control", "title": "控制",
		"fields": [
			{"key": "control/edge_scroll", "label": "屏幕边缘滚动镜头", "type": "toggle", "default": true},
			{"key": "control/edge_scroll_speed", "label": "边缘滚动速度", "type": "slider", "min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "control/zoom_speed", "label": "缩放速度", "type": "slider", "min": 1, "max": 10, "step": 1, "default": 5},
			{"key": "control/middle_drag", "label": "中键拖拽平移", "type": "toggle", "default": true},
		],
	},
	{
		"id": "debug", "title": "调试",
		"fields": [
			{"key": "debug/overlay", "label": "调试覆盖层（F3）", "type": "toggle", "default": false},
			{"key": "debug/legend", "label": "常驻调试图例", "type": "toggle", "default": true},
			{"key": "debug/log_level", "label": "日志级别", "type": "option", "options": ["ERROR", "WARN", "INFO", "DEBUG"], "default": 2, "implemented": false},
		],
	},
]
