class_name SettingsMenuPanel
extends BaseScreen
## 设置菜单 -- 左上角齿轮按钮 / ESC 开关，Minecraft 式居中布局。
##
## 结构（参照 Minecraft 设置界面）：
##   居中面板 + 标题"设置" + 按钮列表（等宽大按钮）
##   常规区：时间速度（暂停/1x/2x/4x）
##   调试区（仅 debug 构建显示，OS.is_debug_build()）：
##     测试地图选择（村落/战场/道路/森林/村落B）——替代原主页菜单的测试场景入口
##
## 由 SystemSetup 装配到 UIRoot；GlobalHUD 齿轮按钮与 ESC 键调 game_root.toggle_settings_menu()。
## 模态面板生命周期（遮罩/居中/open/close/toggle）继承自 BaseScreen。

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _buttons: VBoxContainer = null

## 面板尺寸
const PANEL_SIZE: Vector2 = Vector2(480, 460)

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
	_build_screen()


# ─────────────────────────────── 输入（ESC 开关）────────────────────────────────

## ESC 打开/关闭设置菜单。附身模式（POSSESS）下 ESC 保留给"退出附身"。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _game_root != null and _game_root.input_dispatcher != null:
			if _game_root.input_dispatcher.get_mode() == PlayerControlAPI.Mode.POSSESS:
				return
		toggle()
		get_viewport().set_input_as_handled()


# ─────────────────────────────── UI 构建（Minecraft 式）────────────────────────────────

## 构建面板内容（遮罩/居中面板由 BaseScreen 提供）
func _build_content() -> void:
	# 标题
	var title := Label.new()
	title.text = "设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 20
	title.offset_bottom = 56
	_panel.add_child(title)
	# 按钮列
	_buttons = VBoxContainer.new()
	_buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	_buttons.offset_top = 64
	_buttons.offset_bottom = -16
	_buttons.offset_left = 40
	_buttons.offset_right = -40
	_buttons.add_theme_constant_override("separation", 8)
	_panel.add_child(_buttons)
	# ── 常规区 ──
	_add_section_title("游戏")
	_add_speed_buttons()
	_add_close_button()
	# ── 调试区（仅 debug 构建 + 游戏内显示；主菜单无 game_root，跳过测试地图入口）──
	if OS.is_debug_build() and _game_root != null:
		_add_section_title("调试 · 测试地图")
		for map_id in _get_registered_map_ids():
			_add_map_button(map_id)
		var tip := Label.new()
		tip.text = "提示：Tab 打开大世界导航 · Q 切换战斗模式 · 顶栏「编制」编队"
		tip.add_theme_font_size_override("font_size", UITheme.FONT_HINT)
		tip.modulate = UITheme.COLOR_DIM_TEXT
		_buttons.add_child(tip)


## 地图列表从 SceneLoader 注册表动态获取（不硬编码，避免与地图注册重复维护）
func _get_registered_map_ids() -> Array:
	if _game_root == null or _game_root.scene_loader == null:
		return MAP_DISPLAY_NAMES.keys()
	if _game_root.scene_loader.has_method("get_registered_map_ids"):
		var ids: Array = _game_root.scene_loader.get_registered_map_ids()
		if not ids.is_empty():
			return ids
	return MAP_DISPLAY_NAMES.keys()


func _add_section_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", UITheme.FONT_SECTION)
	label.modulate = UITheme.COLOR_SECTION_TITLE
	_buttons.add_child(label)


## 时间速度控制（暂停/1x/2x/4x）
func _add_speed_buttons() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_buttons.add_child(row)
	var speed_map := {
		"暂停": TimeManager.Speed.PAUSED,
		"1x": TimeManager.Speed.X1,
		"2x": TimeManager.Speed.X2,
		"4x": TimeManager.Speed.X4,
	}
	for label: String in speed_map.keys():
		var btn := Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(0, 34)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var speed: int = speed_map[label]
		btn.pressed.connect(func():
			if TimeManager != null:
				TimeManager.set_speed(speed)
		)
		row.add_child(btn)


## 关闭按钮（返回游戏）
func _add_close_button() -> void:
	var btn := Button.new()
	btn.text = "关闭（ESC / 齿轮）"
	btn.custom_minimum_size = Vector2(0, 36)
	btn.pressed.connect(close)
	_buttons.add_child(btn)


## 调试地图选择按钮：travel 到目标地图（等效原主页菜单测试场景入口）
func _add_map_button(map_id: String) -> void:
	var btn := Button.new()
	btn.text = "前往 %s" % MAP_DISPLAY_NAMES.get(map_id, map_id)
	btn.custom_minimum_size = Vector2(0, 36)
	btn.pressed.connect(_on_map_selected.bind(map_id))
	_buttons.add_child(btn)


func _on_map_selected(map_id: String) -> void:
	close()
	if _game_root == null or _game_root.scene_loader == null:
		return
	var current: String = _game_root.scene_loader.get_current_map_id() if _game_root.scene_loader.has_method("get_current_map_id") else ""
	if map_id == current:
		return
	_game_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
