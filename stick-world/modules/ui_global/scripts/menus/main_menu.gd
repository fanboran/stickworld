class_name MainMenu
extends Control
## 主菜单（正式版）—— 启动流程第一屏，进入游戏的中枢。
##
## 设计见 docs/设计/UI/03-主菜单与流程.md；视觉走 StickTheme 手绘皮肤 +
## 黄金时刻天空场景（手绘云/暮色山/飞鸟），主行动点实底琥珀。
##
## 流程：
##   ├ 继续游戏 → 读最近存档（槽位 0，无档禁用）
##   ├ 新游戏   → 确认框 → 进 game_root（新开局）
##   ├ 读取存档 → SavePanel 只读模式 → 选槽进 game_root（boot_load_slot 指定）
##   ├ 设置     → SettingsMenuPanel（与游戏内同一份，game_root 为空时跳过调试区）
##   ├ 制作人员 → 名单面板（CC-BY 署名合规出口）；同行方钮 → 原声带页
##   └ 退出游戏 → 危险确认框
##
## 场景切换用 change_scene_to_file；读档意图经 SaveManager.boot_load_slot
## 传递给 GameRoot（GameRoot 启动时消费并复位）。

## 载入屏（主菜单 → 游戏 的过渡画面）
const LOADING_SCENE := "res://modules/ui_global/scenes/menus/loading_screen.tscn"
## 原声带页（制作人员同行的方钮入口）
const SOUNDTRACK_SCENE := "res://modules/ui_global/scenes/menus/soundtrack_player.tscn"
const _SettingsMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/settings_menu_panel.gd")

## 菜单项数据：id / 文案 / 变体档位 / 母题图标（icon = 管线母题中文名，无则不挂）
## / companion = 同行方钮（方钮与主条目挤一行，右侧贴邻；见 _build_menu）
## 亮天空上的次级入口一律 PAPER 纸面档（白描边贴图在亮底不可见）；
## 新游戏 = PRIMARY（实底琥珀主行动点，§1.2）；
## alpha = 半透明纸面（除顶部两个主行动外天空透出来，视觉层级落到主行动上）
const MENU_ITEMS: Array[Dictionary] = [
	{"id": "continue", "label": "继续游戏", "kind": StickKit.ButtonKind.PAPER, "icon": &"卷轴"},
	{"id": "new_game", "label": "新游戏", "kind": StickKit.ButtonKind.PRIMARY, "icon": &"旗帜"},
	{"id": "load", "label": "读取存档", "kind": StickKit.ButtonKind.PAPER, "icon": &"两本书", "alpha": 0.62},
	{"id": "settings", "label": "设置", "kind": StickKit.ButtonKind.PAPER, "icon": &"齿轮", "alpha": 0.62},
	# 制作人员 + 原声带：都是"关于这部作品的"内容，挤一行（署名页左、音乐页右方钮）。
	# 制作人员是 CC-BY 署名的合规出口（钢琴采样/环境音素材，见 docs/技术/音频/音乐资产登记与来源.md）
	{"id": "credits", "label": "制作人员", "kind": StickKit.ButtonKind.PAPER, "icon": &"奖章", "alpha": 0.62,
		"companion": {"id": "soundtrack", "tip": "游戏原声带（曲目播放器）",
			"glyph": SketchDraw.Glyph.NOTE}},
	# 测试场景入口：仅开发构建显示（正式发布隐藏），字段 debug_only 过滤于 _build_menu
	{"id": "arena", "label": "测试场景", "kind": StickKit.ButtonKind.PAPER, "debug_only": true, "icon": &"立方体", "alpha": 0.62},
	{"id": "quit", "label": "退出游戏", "kind": StickKit.ButtonKind.PAPER, "icon": &"木门", "alpha": 0.62},
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
	_build_backdrop()
	_build_title()
	_start_title_entrance()
	_build_menu()
	_build_dev_shortcuts()
	_version_label.text = "v0.6.0 Demo · stick-world"
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
		# 带同行方钮的条目：主条目 + 方钮挤一行（方钮贴右缘，行高等于主按钮高）
		var row: Control = _menu_column
		if item.has("companion"):
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", 10)
			_menu_column.add_child(line)
			row = line
		var btn := StickKit.sketch_button(row, item["label"],
				_on_menu_pressed.bind(item), item["kind"], StickTokens.BTN_H_LG)
		if row != _menu_column:
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 视觉全归变体（PAPER 纸面 / PRIMARY 实底琥珀）；字号是排版参数走实例属性
		btn.font_size = 18
		if item.has("alpha"):
			btn.bg_alpha = item["alpha"]
		# 母题角标（左缘叠加，不占排版位）：居中文字不偏，同组有/无图标条目对齐
		var badge: TextureRect = null
		if item.has("icon"):
			badge = StickKit.motif_badge(btn, item["icon"])
		if item["id"] == "continue":
			btn.disabled = not _has_continue_save()
			if badge != null and btn.disabled:
				badge.modulate.a = 0.45
		if item.has("companion"):
			_build_companion_square(row, item["companion"])


## 同行方钮（条目 companion 字段）：正方形、与主按钮等高，图形走 SketchDraw 自绘
## （字体与图标管线都没有音乐符号，见 SketchGlyphButton 头注）。
## 亮天空上沿用主条目的纸面观感：PAPER 变体 + 同档半透明底。
func _build_companion_square(row: Control, spec: Dictionary) -> void:
	var sq := SketchGlyphButton.new()
	sq.name = "SoundtrackButton"
	sq.glyph = spec.get("glyph", SketchDraw.Glyph.NOTE)
	sq.square_size = StickTokens.BTN_H_LG
	sq.kind = SketchButton.Kind.PAPER
	sq.bg_alpha = 0.62
	sq.icon_mode = SketchStyle.IconMode.NONE
	sq.tooltip_text = spec.get("tip", "")
	sq.pressed.connect(func() -> void:
		if AudioManager and AudioManager.has_method("play_event"):
			AudioManager.play_event("ui_click"))
	# 动作走同一张分发表（_on_menu_pressed），方钮也只是一个菜单条目
	sq.pressed.connect(_on_menu_pressed.bind(spec))
	# 亮底描边走深墨（SketchGearButton 的 ink_skin 分支）
	sq.ink_skin = true
	row.add_child(sq)


## 原声带页（曲目播放器）
func _open_soundtrack() -> void:
	get_tree().change_scene_to_file(SOUNDTRACK_SCENE)


func _has_continue_save() -> bool:
	# 继续游戏 = 最近存档 = 自动存档槽位 0
	if SaveManager and SaveManager.has_method("slot_exists"):
		return SaveManager.slot_exists(0)
	return false


# ─────────────────────── 右侧临时演示入口（刻意显式临时）───────────────────────

## 钉在菜单列右侧、最能展示工作量的几个场景（开发构建限定，发布构建整组不建）。
## 刻意做成临时便签观感：组头自述「随时撤」，样式降档（纸面半透明），
## 甄选口径 = 一屏看懂项目家底：组件全族 / 12v12 大乱斗 / 全员动作 / 可玩试玩场。
## 与「测试场景」面板的区别：那是全量索引，这里是精选橱窗，随时可整组撤掉。
const DEV_SHORTCUTS: Array[Dictionary] = [
	{"label": "组件一览（组件全族陈列）", "path": "res://modules/ui_global/scenes/templates/component_gallery.tscn"},
	{"label": "12v12 大乱斗战场", "path": "res://tests/dev/battle_arena.tscn"},
	{"label": "单位动作画廊", "path": "res://tests/dev/unit_action_gallery.tscn"},
	{"label": "开发者试玩场", "path": "res://tests/dev/dev_playtest.tscn"},
]

func _build_dev_shortcuts() -> void:
	if not OS.is_debug_build():
		return
	var box := VBoxContainer.new()
	box.name = "DevShortcuts"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	# 菜单列（锚点居中 ±160）右侧贴邻：+180 起步，留 20px 呼吸
	box.anchor_left = 0.5
	box.anchor_top = 0.5
	box.anchor_right = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = 180.0
	box.offset_right = 440.0
	box.offset_top = -120.0
	box.offset_bottom = 120.0
	add_child(box)
	# 组头/组脚：暖墨半透明（与版本角标同族，亮天空上可读），自述临时 + ESC 出口
	var head := StickKit.label(box, "—— 临时演示入口（随时撤）——", StickKit.LabelKind.HINT)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_color_override("font_color", Color(0.30, 0.20, 0.14, 0.80))
	for item in DEV_SHORTCUTS:
		var btn := StickKit.sketch_button(box, item["label"],
				func() -> void: get_tree().change_scene_to_file(item["path"]),
				StickKit.ButtonKind.PAPER, StickTokens.BTN_H)
		btn.font_size = 15
		btn.bg_alpha = 0.62
	var hint := StickKit.label(box, "场景内按 ESC 可退回主页", StickKit.LabelKind.HINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.30, 0.20, 0.14, 0.60))


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
		"credits":
			_open_credits_panel()
		"soundtrack":
			_open_soundtrack()
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
	"res://tests/dev/preview_glass_demo.tscn": "玻璃拟态预览",
	"res://tests/dev/verify_battle.tscn": "功能验证：战斗",
	"res://tests/dev/verify_build.tscn": "功能验证：建造",
	"res://tests/dev/verify_harvest.tscn": "功能验证：采集",
	"res://tests/dev/verify_quest.tscn": "功能验证：任务",
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
## 界面模板组置顶（组件展示是 UI 门面活文档，不藏末位）
const SCENE_GROUPS: Array[Dictionary] = [
	{"id": "templates", "title": "界面模板", "templates": true},
	{"id": "play", "title": "试玩与观测", "names": ["battle_arena", "unit_action_gallery",
		"dev_playtest", "battle_sim", "battle_perf", "world_perf",
		"record_demo"]},
	{"id": "gallery", "title": "画廊陈列", "names": ["sketch_compare", "sketch_cloud_gallery",
		"preview_glass_demo"]},
	{"id": "verify", "title": "功能验证", "prefix": "verify_"},
	{"id": "diag", "title": "诊断脚本", "prefix": "diag_"},
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
		btn.font_size = 15


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

# ─────────────────────────────── 制作人员面板 ────────────────────────────────

## CC-BY 署名的合规出口（发布义务，依据 docs/技术/音频/音乐资产登记与来源.md
## §三/§五 与 tools/music/docs/ambience_sources.md §五）。
## ⚠ 署名串与那两份登记文档同源——音源/素材变动时必须同步这里。
const CREDITS_TEXT := """火柴人帝国模拟 Demo

—— 音乐 ——
全部配乐为本项目原创（同一主题的场景变奏），由本地采样音源离线渲染生成。
· 钢琴采样：Salamander Grand Piano V3 by Alexander Holm（CC BY 3.0）
· 编制音源：MuseScore General SoundFont（MIT；FluidR3 by Frank Wen / FluidR3Mono by
  Michael Cowgill / MuseScore_General 适配 by S. Christian Collins）

—— 环境音 ——
cicada_summer 与 village_ambience 含改编自以下 CC BY 3.0 素材的声音：
· "Florida Cicada Song" by Gatorguy76（Wikimedia Commons）
· "Chicken Sound Effect" by imadeit（OpenGameArt）
二者均以 CC BY 3.0（creativecommons.org/licenses/by/3.0/）提供，
已作滤波、均衡、混响与混音改编。其余环境音素材为 CC0 / Public Domain。

—— 音效 ——
全部音效为本项目程序化合成，无第三方素材。

—— 引擎 ——
Made with Godot Engine（godotengine.org）"""

var _credits_panel: Control = null

func _open_credits_panel() -> void:
	if _credits_panel != null and is_instance_valid(_credits_panel):
		_credits_panel.queue_free()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 点暗幕空白处关闭
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_close_credits_panel())
	add_child(dim)
	_credits_panel = dim
	var panel := SketchPanel.new()
	panel.custom_minimum_size = Vector2(720, 620)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "制作人员"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var body := Label.new()
	body.text = CREDITS_TEXT
	# 自动换行的 Label 在 ScrollContainer 里最小宽度为 0（会塌成竖排）→ 必须给宽度
	body.custom_minimum_size = Vector2(640, 0)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 15)
	scroll.add_child(body)
	StickKit.sketch_button(vbox, "关闭", _close_credits_panel,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)


func _close_credits_panel() -> void:
	if _credits_panel != null and is_instance_valid(_credits_panel):
		_credits_panel.queue_free()

# ─────────────────────────────── 背景装饰（Demo 第一印象）────────────────────────────────

## 主菜单背景：黄金时刻天空 + 暮色远近山 + 手绘漂移云 + 飞鸟
## （视觉与视差全在 MenuBackdrop，与原声带页共用同一片天空）
func _build_backdrop() -> void:
	var backdrop := MenuBackdrop.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)
	move_child(backdrop, 1)  # 垫在 Background 之上、菜单列/版本角标之下


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
