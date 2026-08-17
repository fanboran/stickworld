class_name TemplateIndex
extends Control
## 模板总览导航页 —— 所有 UI 模板的入口目录（模板间切换枢纽）。
##
## 模板清单是数据（TEMPLATES）：加一个模板 = 加一行。
## F6 运行本场景即可逐个点开验收；每个模板右上角有「返回总览」。

## 模板清单：场景路径 / 名称 / 一句话说明
const TEMPLATES: Array[Dictionary] = [
	{
		"scene": "res://modules/ui_global/scenes/templates/main_menu_template.tscn",
		"name": "主菜单",
		"desc": "标题 + 数据驱动菜单列 + 版本角标；含退出确认框演示",
	},
	{
		"scene": "res://modules/ui_global/scenes/templates/settings_template.tscn",
		"name": "设置界面",
		"desc": "左分类右内容，整页 SETTINGS_SCHEMA 数据驱动（滑条/下拉/开关）",
	},
	{
		"scene": "res://modules/ui_global/scenes/templates/hud_template.tscn",
		"name": "游戏内 HUD",
		"desc": "顶栏速度/时间/资源 + 小地图框 + 密集快捷栏 + 堆叠通知流",
	},
	{
		"scene": "res://modules/ui_global/scenes/templates/workspace_template.tscn",
		"name": "工作区预设（组织面板）",
		"desc": "军事/科研/工程/行政/商业标签切换，快速操作随预设重建",
	},
	{
		"scene": "res://modules/ui_global/scenes/templates/component_gallery.tscn",
		"name": "组件展示页",
		"desc": "按钮/标签/输入/滑条/列表/反馈全族陈列，主题回归自检页",
	},
]

@onready var _card_list: VBoxContainer = $Window/MainVBox/CardList
@onready var _title_label: Label = $Window/MainVBox/TitleLabel
@onready var _subtitle_label: Label = $Window/MainVBox/SubtitleLabel
@onready var _footer_label: Label = $Window/MainVBox/FooterLabel


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_subtitle_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_subtitle_label.modulate = StickTokens.TEXT_DIM
	_footer_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_footer_label.modulate = StickTokens.TEXT_FAINT
	_build_cards()


func _build_cards() -> void:
	for tpl in TEMPLATES:
		_card_list.add_child(_make_card(tpl))


func _make_card(tpl: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_box)
	StickKit.label(text_box, tpl["name"], StickKit.LabelKind.BODY)
	StickKit.label(text_box, tpl["desc"], StickKit.LabelKind.HINT)
	var open_btn := StickKit.button(row, "打开 →", func():
		get_tree().change_scene_to_file(tpl["scene"])
	, StickKit.ButtonKind.ACCENT, StickTokens.BTN_H)
	open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return card
