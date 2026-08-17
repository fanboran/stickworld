class_name MainMenuTemplate
extends Control
## 主菜单模板 —— 标题 + 数据驱动菜单按钮列 + 版本角标。
##
## 设计要点（详见 docs/设计/UI/03-主菜单与流程.md）：
## - 菜单项是数据（MENU_ITEMS）：加一项 = 加一行
## - "窗户不是海报"：菜单直接浮在游戏画面上，无全屏海报底图
## - 落地时由启动流程切换到此场景（当前 project.godot 直进 game_root）
##
## F6 直接运行可预览；按钮动作为演示桩（toast/确认框）。

const INDEX_SCENE := "res://modules/ui_global/scenes/templates/template_index.tscn"

## 菜单项数据：id / 文案 / 视觉档位 / 是否可用（落地时接真实回调）
const MENU_ITEMS: Array[Dictionary] = [
	{"id": "continue", "label": "继续游戏", "kind": StickKit.ButtonKind.ACCENT, "enabled": false},
	{"id": "new_game", "label": "新游戏", "kind": StickKit.ButtonKind.ACCENT, "enabled": true},
	{"id": "load", "label": "读取存档", "kind": StickKit.ButtonKind.NORMAL, "enabled": true},
	{"id": "settings", "label": "设置", "kind": StickKit.ButtonKind.NORMAL, "enabled": true},
	{"id": "credits", "label": "制作名单", "kind": StickKit.ButtonKind.NORMAL, "enabled": true},
	{"id": "quit", "label": "退出游戏", "kind": StickKit.ButtonKind.NORMAL, "enabled": true},
]

@onready var _menu_column: VBoxContainer = $MenuColumn
@onready var _version_label: Label = $VersionLabel
@onready var _nav_button: Button = $NavButton


func _ready() -> void:
	theme = StickTheme.create()
	_build_menu()
	_version_label.text = "v0.1.0-p0 原型 · stick-world"
	_version_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_version_label.modulate = StickTokens.TEXT_FAINT
	_nav_button.pressed.connect(func(): get_tree().change_scene_to_file(INDEX_SCENE))


## 数据驱动装配：标题区 + 按钮列
func _build_menu() -> void:
	var title := StickKit.label(_menu_column, "火柴人帝国模拟", StickKit.LabelKind.TITLE)
	title.add_theme_font_size_override("font_size", StickTokens.FONT_DISPLAY)
	var subtitle := StickKit.label(_menu_column, "从部落到大帝国 · 亲手设计，看它自转", StickKit.LabelKind.HINT)
	subtitle.add_theme_color_override("font_color", StickTokens.TEXT_DIM)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	_menu_column.add_child(spacer)
	for item in MENU_ITEMS:
		var btn := StickKit.button(_menu_column, item["label"],
				_on_menu_pressed.bind(item), item["kind"], StickTokens.BTN_H_LG)
		btn.disabled = not item["enabled"]


## 演示桩：落地时替换为真实流程（新游戏→初始化世界；读档→SavePanel；退出→quit）
func _on_menu_pressed(item: Dictionary) -> void:
	match item["id"]:
		"new_game":
			StickKit.confirm(self, "新游戏", "将建立一个全新的帝国（演示：不真的开局）。确定吗？",
					func(): StickKit.toast(self, "已确认：新游戏流程入口", "info"))
		"quit":
			StickKit.confirm(self, "退出游戏", "确定要退出吗？", func(): get_tree().quit(),
					"退出", StickKit.ButtonKind.DANGER)
		"settings":
			StickKit.toast(self, "打开设置界面（落地时切 settings 场景/面板）", "info")
		"load":
			StickKit.toast(self, "打开读档界面（落地时复用 SavePanel）", "info")
		_:
			StickKit.toast(self, "「%s」演示入口" % item["label"], "info")
