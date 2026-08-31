class_name UIPlaceholderPreview
extends Control
## 占位界面预览入口 —— F6 运行本场景即可逐个打开验收空面板。
##
## 每个预设一张卡片：「打开」→ UIPlaceholderPanel.open_panel(self, id) 模态展示。
## 系统接入后此入口可废弃（面板改接大界面注册挂点）。

@onready var _card_list: VBoxContainer = $Window/MainVBox/CardList
@onready var _title_label: Label = $Window/MainVBox/TitleLabel
@onready var _subtitle_label: Label = $Window/MainVBox/SubtitleLabel
@onready var _footer_label: Label = $Window/MainVBox/FooterLabel


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_subtitle_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_subtitle_label.modulate = StickTokens.TEXT_DIM
	_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_footer_label.modulate = StickTokens.TEXT_FAINT
	for preset in UIPlaceholderPresets.PRESETS:
		_card_list.add_child(_make_card(preset))


func _make_card(preset: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_box)
	StickKit.label(text_box, preset["title"], StickKit.LabelKind.BODY)
	StickKit.label(text_box, preset["desc"], StickKit.LabelKind.HINT)
	var open_btn := StickKit.button(row, "打开 →", func():
		UIPlaceholderPanel.open_panel(self, preset["id"])
	, StickKit.ButtonKind.ACCENT, StickTokens.BTN_H)
	open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return card
