class_name SettingsMenuPanel
extends Control
## 设置菜单 -- 左上角齿轮按钮 / ESC 开关，Minecraft 式居中布局。
##
## 结构（参照 Minecraft 设置界面）：
##   居中面板 + 标题"设置" + 按钮列表（等宽大按钮）
##   常规区：时间速度（暂停/1x/2x/4x）
##   调试区（仅 debug 构建显示，OS.is_debug_build()）：
##     测试地图选择（村落/战场/道路/森林/村落B）——替代原主页菜单的测试场景入口
##
## 由 SystemSetup 装配到 UIRoot；GlobalHUD 齿轮按钮与 ESC 键调 game_root.toggle_settings_menu()。

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _buttons: VBoxContainer = null
var _debug_section: VBoxContainer = null
## 背景与主面板引用（打开时按 viewport 手动定位，不依赖 anchors 布局时序）
var _bg: ColorRect = null
var _panel: Panel = null

## 面板尺寸
const PANEL_SIZE: Vector2 = Vector2(480, 460)

## 地图显示名（map_id -> 中文名）
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
	_build_ui()


func _ready() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	# 手动定位：按 viewport 尺寸居中（ModalOverlay 布局时序不可靠，锚点方案弃用）
	var vp_rect: Rect2 = get_viewport().get_visible_rect() if get_viewport() != null else Rect2(0, 0, 1920, 1080)
	if _bg != null:
		_bg.size = vp_rect.size
	if _panel != null:
		_panel.size = PANEL_SIZE
		_panel.position = (vp_rect.size - PANEL_SIZE) * 0.5
	visible = true


func close_menu() -> void:
	visible = false


func is_open() -> bool:
	return visible


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

func _build_ui() -> void:
	# 半透明背景（点击不穿透，打开时手动全屏）
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.55)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bg)
	# 居中面板（打开时手动定位）
	_panel = Panel.new()
	add_child(_panel)
	# 标题
	var title := Label.new()
	title.text = "设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
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
	# ── 调试区（仅 debug 构建）──
	if OS.is_debug_build():
		_add_section_title("调试 · 测试地图")
		for map_id in MAP_DISPLAY_NAMES.keys():
			_add_map_button(map_id)
		var tip := Label.new()
		tip.text = "提示：Tab 打开大世界导航 · Q 切换战斗模式 · 顶栏「编制」编队"
		tip.add_theme_font_size_override("font_size", 11)
		tip.modulate = Color(0.65, 0.65, 0.65)
		_buttons.add_child(tip)


func _add_section_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = Color(0.7, 0.85, 1.0)
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
	btn.pressed.connect(close_menu)
	_buttons.add_child(btn)


## 调试地图选择按钮：travel 到目标地图（等效原主页菜单测试场景入口）
func _add_map_button(map_id: String) -> void:
	var btn := Button.new()
	btn.text = "前往 %s" % MAP_DISPLAY_NAMES.get(map_id, map_id)
	btn.custom_minimum_size = Vector2(0, 36)
	btn.pressed.connect(_on_map_selected.bind(map_id))
	_buttons.add_child(btn)


func _on_map_selected(map_id: String) -> void:
	close_menu()
	if _game_root == null or _game_root.scene_loader == null:
		return
	var current: String = _game_root.scene_loader.get_current_map_id() if _game_root.scene_loader.has_method("get_current_map_id") else ""
	if map_id == current:
		return
	_game_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
