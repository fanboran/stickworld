class_name MainMenu
extends Control
## 主菜单（正式版）—— 启动流程第一屏，进入游戏的中枢。
##
## 设计见 docs/设计/UI/03-主菜单与流程.md；视觉走 StickTheme 主题层
## （黑玻璃窗 + 琥珀强调，与游戏内 UI 同一套 token）。
##
## 流程：
##   ├ 继续游戏 → 读最近存档（槽位 0，无档禁用）
##   ├ 新游戏   → 确认框 → 进 game_root（新开局）
##   ├ 读取存档 → SavePanel 只读模式 → 选槽进 game_root（boot_load_slot 指定）
##   ├ 设置     → SettingsMenuPanel（与游戏内同一份，game_root 为空时跳过调试区）
##   └ 退出游戏 → 危险确认框
##
## 场景切换用 change_scene_to_file；读档意图经 SaveManager.boot_load_slot
## 传递给 GameRoot（GameRoot 启动时消费并复位）。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
## 载入屏（主菜单 → 游戏 的过渡画面）
const LOADING_SCENE := "res://modules/ui_global/scenes/menus/loading_screen.tscn"
const _SettingsMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/settings_menu_panel.gd")
## 手绘云（背景漂移云；与世界天空同选型期四风格混排）
const SketchCloudScript: GDScript = preload("res://modules/ui_global/scripts/sketch/sketch_cloud.gd")

## 菜单项数据：id / 文案 / 视觉档位
const MENU_ITEMS: Array[Dictionary] = [
	{"id": "continue", "label": "继续游戏", "kind": StickKit.ButtonKind.ACCENT},
	{"id": "new_game", "label": "新游戏", "kind": StickKit.ButtonKind.ACCENT},
	{"id": "load", "label": "读取存档", "kind": StickKit.ButtonKind.NORMAL},
	{"id": "settings", "label": "设置", "kind": StickKit.ButtonKind.NORMAL},
	# 测试场景入口：仅开发构建显示（正式发布隐藏），字段 debug_only 过滤于 _build_menu
	{"id": "arena", "label": "测试场景", "kind": StickKit.ButtonKind.NORMAL},
	{"id": "quit", "label": "退出游戏", "kind": StickKit.ButtonKind.NORMAL},
]

@onready var _menu_column: VBoxContainer = $MenuColumn
@onready var _version_label: Label = $VersionLabel

var _settings_panel: Control = null
var _load_panel: Control = null
## 标题（呼吸动画用）
var _title: Label = null


func _ready() -> void:
	theme = StickTheme.create()
	_build_background()
	_build_title()
	_start_title_entrance()
	_build_menu()
	_version_label.text = "v0.1.0-p0 原型 · stick-world"
	_version_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_version_label.modulate = StickTokens.TEXT_FAINT


func _build_title() -> void:
	var title := StickKit.label(_menu_column, "火柴人帝国模拟", StickKit.LabelKind.TITLE)
	# 标题加大一档（用户指示；48 = FONT_DISPLAY 34 的展示级放大）
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 亮天空上的白字配黑描边（贴纸感），墨色与血条 COLOR_OUTLINE 同源
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.92))
	title.add_theme_constant_override("outline_size", 8)
	# 呼吸缩放以中心为锚
	title.resized.connect(func() -> void: title.pivot_offset = title.size * 0.5)
	_title = title
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	_menu_column.add_child(spacer)


func _build_menu() -> void:
	for item in MENU_ITEMS:
		# 开发专用入口（测试场景等）在非 debug 构建下不显示
		if item.get("debug_only", false) and not OS.is_debug_build():
			continue
		var btn := StickKit.sketch_button(_menu_column, item["label"],
				_on_menu_pressed.bind(item), item["kind"], StickTokens.BTN_H_LG)
		# 浮在暖金天空上的按钮用深墨描边（白描边在亮背景上不可见）
		btn.ink = Color(0.05, 0.04, 0.03, 1.0)
		# 按钮文字改黑（用户指示）：暖黑与 ink 描边同族，亮天空上黑字比白字稳
		# 字号加大一圈（16→18，用户指示「弄大一小圈」——上次读反成缩小已纠正：
		# 等粗手绘体字号越大笔画间距越开，黑字反而更清晰）
		for col_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			btn.add_theme_color_override(col_name, Color(0.1, 0.08, 0.06))
		btn.add_theme_font_size_override("font_size", 18)
		if item["id"] == "continue":
			btn.disabled = not _has_continue_save()


func _has_continue_save() -> bool:
	# 继续游戏 = 最近存档 = 自动存档槽位 0
	if SaveManager and SaveManager.has_method("slot_exists"):
		return SaveManager.slot_exists(0)
	return false


# ─────────────────────────────── 菜单动作 ────────────────────────────────

func _on_menu_pressed(item: Dictionary) -> void:
	match item["id"]:
		"new_game":
			StickKit.confirm(self, "新游戏", "将建立一个全新的帝国，当前进度不会自动保存。确定开始吗？",
					_start_new_game)
		"quit":
			StickKit.confirm(self, "退出游戏", "确定要退出吗？未保存的进度将丢失。",
					func(): get_tree().quit(), "退出", StickKit.ButtonKind.DANGER)
		"continue":
			_boot_load(0)
		"load":
			_open_load_panel()
		"settings":
			_open_settings_panel()
		"arena":
			_open_arena_panel()


## 测试场景选择面板（开发构建专用；非正式玩法入口）。
## 场景清单在此登记：名称 + 场景路径；新测试场景加一行即可。
const TEST_SCENES: Array[Dictionary] = [
	{"name": "大乱斗观察场（12v12 混编自动互殴）", "path": "res://tests/dev/battle_arena.tscn"},
	{"name": "单位动作画廊（全员单位×全部动作对比）", "path": "res://tests/dev/unit_action_gallery.tscn"},
	{"name": "手绘皮肤全族陈列（自绘沸腾 + StickHand 字体）", "path": "res://tests/dev/sketch_compare.tscn"},
	{"name": "手绘云候选陈列（动漫体积/油画厚涂）", "path": "res://tests/dev/sketch_cloud_gallery.tscn"},
]

var _arena_panel: Control = null

func _open_arena_panel() -> void:
	if _arena_panel != null and is_instance_valid(_arena_panel):
		_arena_panel.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_arena_panel = dim
	var panel := SketchPanel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "测试场景"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)
	for scene_info in TEST_SCENES:
		# StickKit.button 内部已挂到 vbox，不再手动 add_child（重复挂父会报错）
		StickKit.sketch_button(vbox, scene_info["name"],
				func(): get_tree().change_scene_to_file(scene_info["path"]),
				StickKit.ButtonKind.ACCENT, StickTokens.BTN_H)
	StickKit.sketch_button(vbox, "返回", _close_arena_panel,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)


func _close_arena_panel() -> void:
	if _arena_panel != null and is_instance_valid(_arena_panel):
		_arena_panel.queue_free()


## 启动新游戏：清读档意图 → 载入屏 → game_root
func _start_new_game() -> void:
	if SaveManager:
		SaveManager.boot_load_slot = -1
	get_tree().change_scene_to_file(LOADING_SCENE)


## 启动读档：设置 boot_load_slot 后经载入屏切 game_root（GameRoot 启动时消费）
func _boot_load(slot: int) -> void:
	if SaveManager:
		SaveManager.boot_load_slot = slot
	get_tree().change_scene_to_file(LOADING_SCENE)


# ─────────────────────────────── 读档面板 ────────────────────────────────

func _open_load_panel() -> void:
	if _load_panel != null and is_instance_valid(_load_panel):
		if _load_panel.has_method("open"):
			_load_panel.open()
		return
	# 复用 SavePanel（只读模式）：主菜单没有游戏世界可存
	_load_panel = UIAPI.create_save_panel()
	_load_panel.title_text = "读取存档"
	_load_panel.read_only = true
	if _load_panel.has_method("setup_load_callback"):
		_load_panel.setup_load_callback(_boot_load)
	add_child(_load_panel)
	if _load_panel.has_method("open"):
		_load_panel.open()


# ─────────────────────────────── 设置面板 ────────────────────────────────

func _open_settings_panel() -> void:
	if _settings_panel != null and is_instance_valid(_settings_panel):
		if _settings_panel.has_method("toggle"):
			_settings_panel.toggle()
		return
	_settings_panel = UIKit.full_rect(_SettingsMenuPanelScript, "SettingsMenuPanel")
	# 主菜单无 game_root：调试区（测试地图入口）自动跳过
	if _settings_panel.has_method("setup"):
		_settings_panel.setup(null)
	add_child(_settings_panel)
	if _settings_panel.has_method("open"):
		_settings_panel.open()

# ─────────────────────────────── 背景装饰（Demo 第一印象）────────────────────────────────

## 主菜单背景：天空暖色渐变 + 远山剪影 + 漂移云（复用 sky 装饰贴图，与游戏内一致）
func _build_background() -> void:
	# 天空垂直渐变（上暖金 → 下深蓝灰，黄金时刻）
	var sky := TextureRect.new()
	sky.name = "SkyGradient"
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	var grad := Gradient.new()
	grad.set_color(0, Color(0.96, 0.78, 0.55))
	grad.set_color(1, Color(0.16, 0.19, 0.27))
	grad.add_point(0.45, Color(0.66, 0.55, 0.52))
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.gradient = grad
	gt.width = 8
	gt.height = 512
	sky.texture = gt
	add_child(sky)
	move_child(sky, 1)  # 垫在 Background 之上、菜单列之下
	_sky_rect = sky
	# 远山（贴屏幕底）
	if ResourceLoader.exists(SkyDecorMountains):
		var m := TextureRect.new()
		m.name = "Mountains"
		_mountains_rect = m
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		m.stretch_mode = TextureRect.STRETCH_TILE
		m.texture = load(SkyDecorMountains)
		m.anchor_left = 0.0
		m.anchor_right = 1.0
		m.anchor_top = 1.0
		m.anchor_bottom = 1.0
		m.offset_top = -300.0
		m.offset_bottom = 0.0
		m.modulate = Color(0.9, 0.86, 0.84)
		add_child(m)
		move_child(m, 2)
	# 漂移云（手绘云三朵，四风格随机混排同世界选型期；_process 缓移）——
	# 山之上、菜单之下（index 4）
	_cloud_rects = []
	for i in 3:
		var c: Node2D = SketchCloudScript.new()
		c.set("style", [5, 5, 5, 4][i % 4])
		c.set("cloud_size", Vector2(200.0, 83.0) * randf_range(0.85, 1.2))
		c.position = Vector2(randf_range(0.1, 0.7) * 1920.0, randf_range(40.0, 300.0))
		c.modulate = Color(1, 1, 1, 0.85)
		add_child(c)
		move_child(c, 4)
		_cloud_rects.append(c)
		_cloud_base_ys.append(c.position.y)
	# 远空飞鸟（自绘剪影，与游戏内 sky_birds 同视觉语言；云上山下）
	var birds: Node2D = MenuBirdsScript.new()
	birds.name = "MenuBirds"
	add_child(birds)
	move_child(birds, 2)

const SkyDecorMountains := "res://assets/sky/bg_mountain_far.png"
const SkyDecorCloudA := "res://assets/sky/cloud_a.png"
const SkyDecorCloudB := "res://assets/sky/cloud_b.png"
const MenuBirdsScript := preload("res://modules/ui_global/scripts/menus/menu_birds.gd")
var _cloud_rects: Array = []


# ─────────────────────────────── 精致细节（Demo 打磨包）────────────────────────────────

## 背景视差引用
var _sky_rect: TextureRect = null
var _mountains_rect: TextureRect = null
## 鼠标归一化位置（-0.5~0.5），用于背景层反向微移
var _mouse_norm: Vector2 = Vector2.ZERO
## 闲逛火柴人彩蛋
var _walker: TextureRect = null
var _walker_frame: float = 0.0
var _walker_dir: float = 1.0
var _walker_cooldown: float = 3.0

const WalkerF0 := "res://assets/sky/walker_f0.png"
const WalkerF1 := "res://assets/sky/walker_f1.png"

## 鼠标视差：背景各层按深度反向微移（精致菜单标配——画面"活"）
func _process(delta: float) -> void:
	# 云缓移（原逻辑；回绕宽度按 cloud_size）
	for i in _cloud_rects.size():
		var c: Node2D = _cloud_rects[i]
		c.position.x += (6.0 + 4.0 * i) * delta
		if c.position.x > 1920.0:
			c.position.x = -float((c.get("cloud_size") as Vector2).x)
	# 鼠标视差
	var mp := get_viewport().get_mouse_position()
	var target := Vector2(mp.x / 1920.0 - 0.5, mp.y / 1080.0 - 0.5)
	_mouse_norm = _mouse_norm.lerp(target, minf(1.0, 3.0 * delta))
	# 山层贴底 anchor 不被视差破坏：仅以轻微透明度呼吸暗示深度
	if _mountains_rect != null:
		_mountains_rect.modulate = Color(1, 1, 1).lerp(Color(0.94, 0.94, 0.97), (_mouse_norm.x + 0.5))
	if _sky_rect != null:
		_sky_rect.position = -_mouse_norm * 6.0
	for i in _cloud_rects.size():
		_cloud_rects[i].position.y = _cloud_base_ys[i] - _mouse_norm.y * (16.0 + 8.0 * i)
	_update_walker(delta)


var _cloud_base_ys: Array = []
## 火柴人闲逛彩蛋：随机间隔从屏幕一侧走到另一侧（呼应"每个火柴人都在真实生活"）
func _update_walker(delta: float) -> void:
	if _walker == null and not ResourceLoader.exists(WalkerF0):
		return
	if _walker == null:
		_walker_cooldown -= delta
		if _walker_cooldown <= 0.0:
			_walker = TextureRect.new()
			_walker.texture = load(WalkerF0)
			_walker.modulate = Color(1, 1, 1, 0.55)
			_walker.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(_walker)
			move_child(_walker, 1)
			_walker_dir = 1.0 if randf() < 0.5 else -1.0
			var start_x: float = -80.0 if _walker_dir > 0 else 1920.0 + 80.0
			_walker.position = Vector2(start_x, 620.0 + randf() * 120.0)
			_walker.scale = Vector2(1.4, 1.4)
			if _walker_dir < 0:
				_walker.scale.x = -1.4  # 面向行走方向
		return
	# 行走动画：2 帧交替 + 平移
	_walker_frame += delta * 6.0
	var tex_path: String = WalkerF0 if int(_walker_frame) % 2 == 0 else WalkerF1
	_walker.texture = load(tex_path)
	_walker.position.x += _walker_dir * 55.0 * delta
	if _walker.position.x < -120.0 or _walker.position.x > 1960.0:
		_walker.queue_free()
		_walker = null
		_walker_cooldown = randf_range(4.0, 9.0)


## 标题进场：淡入 + 上浮（首印之一）
func _start_title_entrance() -> void:
	var title := _menu_column.get_child(0) if _menu_column.get_child_count() > 0 else null
	if title == null:
		return
	title.modulate.a = 0.0
	var tw := title.create_tween()
	tw.tween_property(title, "modulate:a", 1.0, 0.7)
	tw.parallel().tween_property(title, "position:y", title.position.y, 0.7).from(title.position.y + 14.0)
	# 入场完接呼吸（用户指示：标题缓慢脉动；正弦缓动无弹跳，2.6s 一个周期）
	tw.tween_callback(_start_title_breath.bind(title))


## 标题呼吸：scale 1.0 → 1.04 → 1.0 循环（中心锚点在 _build_title 的 resized 里设）
func _start_title_breath(title: Label) -> void:
	var tw := title.create_tween().set_loops()
	tw.tween_property(title, "scale", Vector2(1.04, 1.04), 1.3) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(title, "scale", Vector2.ONE, 1.3) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
