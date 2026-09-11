class_name MainMenu
extends Control
## 主菜单（正式版）—— 启动流程第一屏，进入游戏的中枢。
##
## 设计见 docs/设计/UI/03-主菜单与流程.md；视觉走 StickTheme 手绘皮肤 +
## 黄金时刻天空场景（手绘云/暮色山/闲逛火柴人），主行动点实底琥珀。
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

## 菜单项数据：id / 文案 / 视觉档位 / 母题图标（icon = 管线母题中文名，无则不挂）
## 新游戏 = PRIMARY（实底琥珀主行动点，§1.2）；继续游戏 = ACCENT（琥珀描边档）
const MENU_ITEMS: Array[Dictionary] = [
	{"id": "continue", "label": "继续游戏", "kind": StickKit.ButtonKind.ACCENT, "icon": &"卷轴"},
	{"id": "new_game", "label": "新游戏", "kind": StickKit.ButtonKind.PRIMARY, "icon": &"旗帜"},
	{"id": "load", "label": "读取存档", "kind": StickKit.ButtonKind.NORMAL, "icon": &"两本书"},
	{"id": "settings", "label": "设置", "kind": StickKit.ButtonKind.NORMAL, "icon": &"齿轮"},
	# 测试场景入口：仅开发构建显示（正式发布隐藏），字段 debug_only 过滤于 _build_menu
	{"id": "arena", "label": "测试场景", "kind": StickKit.ButtonKind.NORMAL, "debug_only": true, "icon": &"立方体"},
	{"id": "quit", "label": "退出游戏", "kind": StickKit.ButtonKind.NORMAL},
]

@onready var _menu_column: VBoxContainer = $MenuColumn
@onready var _version_label: Label = $VersionLabel

var _settings_panel: Control = null
var _load_panel: Control = null
## 标题（呼吸动画用）
var _title: Label = null


func _ready() -> void:
	# 暂停原语化：游戏内「退出到主菜单」可能带着引擎总闸（SceneTree.paused=true）
	# 换场景，总闸不随场景切换复位——菜单按钮（PAUSABLE）会全部失灵，这里统一复位
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.resume()
	# 主菜单显式恢复沸腾（玩法场景置 false 后返回菜单不依赖对方清理）；
	# 并确保驱动节点存在——ensure_driver 原本只由世界场景的 ui_root 装配调用，
	# 全新启动直接进主菜单时驱动不存在，沸腾从未生效
	SketchTextures.animation_enabled = true
	SketchTextures.ensure_driver(get_tree())
	theme = StickTheme.create()
	_build_background()
	_build_title()
	_start_title_entrance()
	_build_menu()
	_version_label.text = "v0.2 Demo · stick-world"
	_version_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	# 亮天空上 TEXT_FAINT 不可见：改暖墨半透明（与描边同族）
	_version_label.modulate = Color(0.08, 0.06, 0.05, 0.55)


func _build_title() -> void:
	var title := StickKit.label(_menu_column, "火柴人帝国模拟", StickKit.LabelKind.TITLE)
	# 展示级大字（hero 感：审计指出旧 48px 灰白小字主体弱）
	title.add_theme_font_size_override("font_size", 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 暖白字 + 深墨描边（贴纸感），墨色与血条 COLOR_OUTLINE 同源
	title.add_theme_color_override("font_color", Color(0.99, 0.97, 0.92))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.92))
	title.add_theme_constant_override("outline_size", 10)
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
		# 亮天空上的按钮：次级用纸面+墨描边形态（白描边贴图在亮底不可见）；
		# PRIMARY 实底琥珀自带墨描边，不走纸面
		if item["kind"] != StickKit.ButtonKind.PRIMARY:
			btn.ink_skin = true
		# 次级入口半透明纸面（除顶部两个主行动外）：天空透出来，视觉层级
		# 落到「继续/新游戏」上；NORMAL 档=读取存档/设置/测试场景/退出
		if item["kind"] == StickKit.ButtonKind.NORMAL:
			btn.bg_alpha = 0.62
		# 按钮文字统一暖黑（墨与描边同族，亮底上黑字比白字稳）：
		# 等粗手绘体字号越大笔画间距越开，黑字更清晰
		for col_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			btn.add_theme_color_override(col_name, Color(0.1, 0.08, 0.06))
		btn.add_theme_font_size_override("font_size", 18)
		# 母题角标（左缘叠加，不占排版位）：居中文字不偏，同组有/无图标条目对齐
		var badge: TextureRect = null
		if item.has("icon"):
			badge = StickKit.motif_badge(btn, item["icon"])
		if item["id"] == "continue":
			btn.disabled = not _has_continue_save()
			if badge != null and btn.disabled:
				badge.modulate.a = 0.45


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


## 测试场景选择窗（开发构建专用；非正式玩法入口）。
## 左分类右列表结构：SCENE_GROUPS 定义分组，DirAccess 全量扫描 res://tests/dev
## 分桶收录——游戏内不可达的独立场景一枚不漏；DEV_SCENE_NAMES 给常用场景中
## 文名，未登记场景以文件名入列（下划线前缀 = 内部辅助件，不入列）。
const DEV_SCENE_NAMES: Dictionary = {
	"res://tests/dev/battle_arena.tscn": "大乱斗观察场（12v12 混编自动互殴）",
	"res://tests/dev/unit_action_gallery.tscn": "单位动作画廊（全员单位×全部动作对比）",
	"res://tests/dev/sketch_compare.tscn": "手绘皮肤全族陈列（自绘沸腾 + StickHand 字体）",
	"res://tests/dev/sketch_cloud_gallery.tscn": "手绘云候选陈列（动漫体积/油画厚涂）",
	"res://tests/dev/dev_playtest.tscn": "开发者试玩场",
	"res://tests/dev/battle_sim.tscn": "战斗模拟观测",
	"res://tests/dev/battle_perf.tscn": "战斗性能观测",
	"res://tests/dev/world_perf.tscn": "世界性能观测",
	"res://tests/dev/siege_wall_showcase.tscn": "攻城城墙陈列",
	"res://tests/dev/preview_glass_demo.tscn": "玻璃拟态预览",
	"res://tests/dev/verify_battle.tscn": "功能验证：战斗",
	"res://tests/dev/verify_build.tscn": "功能验证：建造",
	"res://tests/dev/verify_harvest.tscn": "功能验证：采集",
	"res://tests/dev/verify_quest.tscn": "功能验证：任务",
	"res://tests/dev/verify_parallax.tscn": "功能验证：视差",
}

## 界面模板陈列（modules/ui_global 场景，游戏内不可达）
const TEMPLATE_SCENES: Array[Dictionary] = [
	{"name": "模板总索引", "path": "res://modules/ui_global/scenes/templates/template_index.tscn"},
	{"name": "组件全族陈列", "path": "res://modules/ui_global/scenes/templates/component_gallery.tscn"},
	{"name": "HUD 模板", "path": "res://modules/ui_global/scenes/templates/hud_template.tscn"},
	{"name": "主菜单模板", "path": "res://modules/ui_global/scenes/templates/main_menu_template.tscn"},
	{"name": "设置模板", "path": "res://modules/ui_global/scenes/templates/settings_template.tscn"},
	{"name": "工作区模板", "path": "res://modules/ui_global/scenes/templates/workspace_template.tscn"},
]

## 场景分组（左分类栏）：names=按文件基名收编，prefix=按前缀收编，
## templates=界面模板固定组；未匹配场景进「其他」组兜底
const SCENE_GROUPS: Array[Dictionary] = [
	{"id": "play", "title": "试玩与观测", "names": ["battle_arena", "unit_action_gallery",
		"dev_playtest", "battle_sim", "battle_perf", "world_perf", "siege_wall_showcase",
		"record_demo", "record_night"]},
	{"id": "gallery", "title": "画廊陈列", "names": ["sketch_compare", "sketch_cloud_gallery",
		"preview_glass_demo"]},
	{"id": "verify", "title": "功能验证", "prefix": "verify_"},
	{"id": "diag", "title": "诊断脚本", "prefix": "diag_"},
	{"id": "templates", "title": "界面模板", "templates": true},
]

## 扫描 res://tests/dev 的全部场景，按 SCENE_GROUPS 分桶（下划线前缀 = 内部
## 辅助件跳过）；未匹配进「其他」。返回 [{title, items:[{display, path}]}]
static func _arena_buckets() -> Array[Dictionary]:
	var buckets: Array[Dictionary] = []
	var consumed: Dictionary = {}
	for g: Dictionary in SCENE_GROUPS:
		var items: Array[Dictionary] = []
		if g.get("templates", false):
			for t: Dictionary in TEMPLATE_SCENES:
				items.append({"display": t["name"], "path": t["path"]})
		else:
			var dir := DirAccess.open("res://tests/dev")
			if dir != null:
				dir.list_dir_begin()
				var f := dir.get_next()
				while f != "":
					var base := f.get_basename()
					if f.ends_with(".tscn") and not f.begins_with("_"):
						var hit: bool = (g.get("prefix", "") != "" and base.begins_with(g["prefix"])) \
								or base in g.get("names", [])
						if hit:
							var path := "res://tests/dev/" + f
							items.append({"display": DEV_SCENE_NAMES.get(path, base), "path": path})
							consumed[f] = true
					f = dir.get_next()
				dir.list_dir_end()
		if not items.is_empty():
			buckets.append({"title": g["title"], "items": items})
	# 兜底：未归组的场景收进「其他」
	var rest: Array[Dictionary] = []
	var dir2 := DirAccess.open("res://tests/dev")
	if dir2 != null:
		dir2.list_dir_begin()
		var f2 := dir2.get_next()
		while f2 != "":
			if f2.ends_with(".tscn") and not f2.begins_with("_") and not consumed.has(f2):
				rest.append({"display": f2.get_basename(), "path": "res://tests/dev/" + f2})
			f2 = dir2.get_next()
		dir2.list_dir_end()
	if not rest.is_empty():
		rest.sort_custom(func(a, b): return a["display"] < b["display"])
		buckets.append({"title": "其他", "items": rest})
	return buckets

var _arena_panel: Control = null
var _arena_group_buttons: Dictionary = {}
var _arena_list_box: VBoxContainer = null
var _arena_bucket_data: Array[Dictionary] = []

func _open_arena_panel() -> void:
	if _arena_panel != null and is_instance_valid(_arena_panel):
		_arena_panel.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 点暗幕空白处关闭
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_close_arena_panel())
	add_child(dim)
	_arena_panel = dim
	var panel := SketchPanel.new()
	panel.custom_minimum_size = Vector2(920, 620)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "测试场景"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)
	# 左分类 + 右列表（设置面板同款骨架；单列滚到底放不下 40+ 场景）
	var body := HBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	vbox.add_child(body)
	var cats := VBoxContainer.new()
	cats.custom_minimum_size = Vector2(150, 0)
	cats.add_theme_constant_override("separation", 4)
	body.add_child(cats)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	_arena_list_box = VBoxContainer.new()
	_arena_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_arena_list_box.add_theme_constant_override("separation", 5)
	scroll.add_child(_arena_list_box)
	_arena_bucket_data = _arena_buckets()
	for i in _arena_bucket_data.size():
		var btn := StickKit.sketch_button(cats, _arena_bucket_data[i]["title"],
				_select_arena_group.bind(i), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_arena_group_buttons[i] = btn
	_select_arena_group(0)
	StickKit.sketch_button(vbox, "关闭", _close_arena_panel,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)


## 切换右侧场景列表（分类按钮琥珀高亮=选中）
func _select_arena_group(idx: int) -> void:
	for i in _arena_group_buttons:
		var b: Button = _arena_group_buttons[i]
		b.kind = SketchButton.Kind.ACCENT if i == idx else SketchButton.Kind.DARK
	for child in _arena_list_box.get_children():
		child.queue_free()
	for item: Dictionary in _arena_bucket_data[idx]["items"]:
		var btn := StickKit.sketch_button(_arena_list_box, item["display"],
				func(): get_tree().change_scene_to_file(item["path"]),
				StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 15)


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

## 主菜单背景：黄金时刻天空 + 远近山剪影 + 手绘漂移云 + 闲逛火柴人
## （审计整改：旧渐变中段橙→灰过渡发闷像雾霾，色相断链；山是中饱和扁平蓝与暖天撞色；
##  云用 ANIME 光滑体积风读作 clipart——三件一起按手绘语言调谐）
func _build_background() -> void:
	# 天空垂直渐变：暖金 → 琥珀玫瑰 → 暮尘 → 深暮蓝，色相连续不断链
	var sky := TextureRect.new()
	sky.name = "SkyGradient"
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	var grad := Gradient.new()
	grad.set_color(0, Color(0.99, 0.82, 0.55))
	grad.set_color(1, Color(0.23, 0.20, 0.29))
	grad.add_point(0.42, Color(0.94, 0.67, 0.46))
	grad.add_point(0.72, Color(0.62, 0.44, 0.44))
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
	# 远山（贴屏幕底）：暮色染调（蓝贴图×暖玫瑰 = 黄金时刻大气透视的暮紫，
	# 消中饱和扁平蓝与暖天的撞色）
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
		m.modulate = Color(0.82, 0.60, 0.56)
		add_child(m)
		move_child(m, 2)
	# 近山一层（更暗更近，叠出纵深；无此贴图时静默跳过）
	if ResourceLoader.exists(SkyDecorMountainsNear):
		var mn := TextureRect.new()
		mn.name = "MountainsNear"
		_mountains_near_rect = mn
		mn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mn.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mn.stretch_mode = TextureRect.STRETCH_TILE
		mn.texture = load(SkyDecorMountainsNear)
		mn.anchor_left = 0.0
		mn.anchor_right = 1.0
		mn.anchor_top = 1.0
		mn.anchor_bottom = 1.0
		mn.offset_top = -170.0
		mn.offset_bottom = 0.0
		mn.modulate = Color(0.45, 0.36, 0.40)
		add_child(mn)
		move_child(mn, 3)
	# 漂移云（手绘简笔画系三风格混排：毛线团/笔触/鼓包，与沸腾语言同源；
	# 原 ANIME 光滑体积风读作 clipart 已弃）——山之上、菜单之下（index 4）
	_cloud_rects = []
	for i in 3:
		var c: Node2D = SketchCloudScript.new()
		c.set("style", [1, 2, 0][i % 3])
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
const SkyDecorMountainsNear := "res://assets/sky/bg_mountain_near.png"
const SkyDecorCloudA := "res://assets/sky/cloud_a.png"
const SkyDecorCloudB := "res://assets/sky/cloud_b.png"
const MenuBirdsScript := preload("res://modules/ui_global/scripts/menus/menu_birds.gd")
var _cloud_rects: Array = []


# ─────────────────────────────── 精致细节（Demo 打磨包）────────────────────────────────

## 背景视差引用
var _sky_rect: TextureRect = null
var _mountains_rect: TextureRect = null
var _mountains_near_rect: TextureRect = null
## 鼠标归一化位置（-0.5~0.5），用于背景层反向微移
var _mouse_norm: Vector2 = Vector2.ZERO
## 闲逛火柴人彩蛋
var _walker: TextureRect = null
var _walker_frame: float = 0.0
var _walker_dir: float = 1.0
var _walker_cooldown: float = 0.8
var _walker_last_frame: int = -1

## 远山暮色基调（蓝贴图×暖玫瑰=黄金时刻大气透视；视差呼吸围绕此色）
const MOUNTAIN_TINT := Color(0.82, 0.60, 0.56)

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
	# 山层贴底 anchor 不被视差破坏：远山以暮色基调做轻微明暗呼吸暗示深度，
	# 近山只做 x 向微视差（直接改 position 会破坏贴底锚点，只动 x 分量）
	if _mountains_rect != null:
		_mountains_rect.modulate = MOUNTAIN_TINT.lerp(
				MOUNTAIN_TINT.lightened(0.06), (_mouse_norm.x + 0.5))
	if _mountains_near_rect != null:
		_mountains_near_rect.position.x = -_mouse_norm.x * 12.0
	if _sky_rect != null:
		_sky_rect.position = -_mouse_norm * 6.0
	for i in _cloud_rects.size():
		_cloud_rects[i].position.y = _cloud_base_ys[i] - _mouse_norm.y * (16.0 + 8.0 * i)
	_update_walker(delta)


var _cloud_base_ys: Array = []
## 火柴人闲逛彩蛋 → 视觉主体（审计：主菜单缺火柴人视觉主体）。
## 加大加实、走完短休整即返场——山脊线上永远有火柴人在生活。
func _update_walker(delta: float) -> void:
	if _walker == null and not ResourceLoader.exists(WalkerF0):
		return
	if _walker == null:
		_walker_cooldown -= delta
		if _walker_cooldown <= 0.0:
			_walker = TextureRect.new()
			_walker.texture = load(WalkerF0)
			_walker.modulate = Color(1, 1, 1, 0.85)
			_walker.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(_walker)
			move_child(_walker, 1)
			_walker_dir = 1.0 if randf() < 0.5 else -1.0
			var start_x: float = -80.0 if _walker_dir > 0 else 1920.0 + 80.0
			_walker.position = Vector2(start_x, 640.0 + randf() * 100.0)
			_walker.scale = Vector2(2.1, 2.1)
			if _walker_dir < 0:
				_walker.scale.x = -2.1  # 面向行走方向
		return
	# 行走动画：2 帧交替 + 平移（帧号变化才 load/赋值 texture——每帧赋值
	# 触发 TextureRect 重绘 + 路径字符串构造，主菜单常驻 _process 白烧）
	_walker_frame += delta * 6.0
	var frame: int = int(_walker_frame) % 2
	if frame != _walker_last_frame:
		_walker_last_frame = frame
		_walker.texture = load(WalkerF0 if frame == 0 else WalkerF1)
	_walker.position.x += _walker_dir * 55.0 * delta
	if _walker.position.x < -120.0 or _walker.position.x > 1960.0:
		_walker.queue_free()
		_walker = null
		_walker_cooldown = randf_range(0.8, 2.2)


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
