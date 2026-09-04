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

## 菜单项数据：id / 文案 / 视觉档位
const MENU_ITEMS: Array[Dictionary] = [
	{"id": "continue", "label": "继续游戏", "kind": StickKit.ButtonKind.ACCENT},
	{"id": "new_game", "label": "新游戏", "kind": StickKit.ButtonKind.ACCENT},
	{"id": "load", "label": "读取存档", "kind": StickKit.ButtonKind.NORMAL},
	{"id": "settings", "label": "设置", "kind": StickKit.ButtonKind.NORMAL},
	# 测试场景入口：仅开发构建显示（正式发布隐藏），字段 debug_only 过滤于 _build_menu
	{"id": "arena", "label": "测试场景", "kind": StickKit.ButtonKind.NORMAL, "debug_only": true},
	{"id": "quit", "label": "退出游戏", "kind": StickKit.ButtonKind.NORMAL},
]

@onready var _menu_column: VBoxContainer = $MenuColumn
@onready var _version_label: Label = $VersionLabel

var _settings_panel: Control = null
var _load_panel: Control = null


func _ready() -> void:
	theme = StickTheme.create()
	_build_title()
	_build_menu()
	_version_label.text = "v0.1.0-p0 原型 · stick-world"
	_version_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_version_label.modulate = StickTokens.TEXT_FAINT


func _build_title() -> void:
	var title := StickKit.label(_menu_column, "火柴人帝国模拟", StickKit.LabelKind.TITLE)
	title.add_theme_font_size_override("font_size", StickTokens.FONT_DISPLAY)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var subtitle := StickKit.label(_menu_column, "从部落到大帝国 · 亲手设计，看它自转", StickKit.LabelKind.HINT)
	subtitle.add_theme_color_override("font_color", StickTokens.TEXT_DIM)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Demo 版标识：让首次打开的人 3 秒内知道这是什么、玩什么
	var demo_tag := StickKit.label(_menu_column,
		"求职 Demo · 新游戏含阶段目标引导（采集 → 建造 → 编队 → 战斗）",
		StickKit.LabelKind.HINT)
	demo_tag.add_theme_color_override("font_color", Color(1.0, 0.84, 0.45))
	demo_tag.add_theme_font_size_override("font_size", 13)
	demo_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	_menu_column.add_child(spacer)


func _build_menu() -> void:
	for item in MENU_ITEMS:
		# 开发专用入口（测试场景等）在非 debug 构建下不显示
		if item.get("debug_only", false) and not OS.is_debug_build():
			continue
		var btn := StickKit.button(_menu_column, item["label"],
				_on_menu_pressed.bind(item), item["kind"], StickTokens.BTN_H_LG)
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
	var panel := PanelContainer.new()
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
		StickKit.button(vbox, scene_info["name"],
				func(): get_tree().change_scene_to_file(scene_info["path"]),
				StickKit.ButtonKind.ACCENT, StickTokens.BTN_H)
	StickKit.button(vbox, "返回", _close_arena_panel,
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