extends SketchPanel
## Demo 阶段目标卡 —— 右上角常驻小卡：当前目标 + 进度 + 已完成列表。
##
## 纯被动显示部件：由 DemoQuest（装配逻辑组件）调用 show_quest / mark_done 驱动，
## 自身不监听任何业务信号。经 UIKit.widget 创建（锚定由本脚本 _ready 自理）。

var _current_title: Label
var _current_desc: Label
var _progress_label: Label
var _done_box: VBoxContainer
var _title_label: Label


func _ready() -> void:
	name = "QuestPanel"
	# 角落部件自设 anchor：右上角（顶栏 + 资源条约占顶部 128px，从 132 起）
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -298.0
	offset_right = -16.0
	offset_top = 132.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	super._ready()  # SketchPanel：手绘底 + 沸腾
	tone = Tone.LIGHT
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(282, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	add_child(box)

	_title_label = Label.new()
	_title_label.text = "◈ 阶段目标"
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.45))
	box.add_child(_title_label)

	_current_title = Label.new()
	_current_title.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
	_current_title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	box.add_child(_current_title)

	_current_desc = Label.new()
	_current_desc.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_current_desc.add_theme_color_override("font_color", Color(0.72, 0.75, 0.8))
	_current_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_current_desc)

	_progress_label = Label.new()
	_progress_label.add_theme_font_size_override("font_size", StickTokens.FONT_SECTION)
	_progress_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.6))
	box.add_child(_progress_label)

	_done_box = VBoxContainer.new()
	_done_box.add_theme_constant_override("separation", 2)
	box.add_child(_done_box)


## 显示当前目标（进度文本为空则隐藏进度行）
func show_quest(title: String, desc: String, progress_text: String = "") -> void:
	_title_label.text = "◈ 阶段目标"
	_current_title.text = "▶ %s" % title
	_current_desc.text = desc
	_progress_label.text = progress_text
	_progress_label.visible = not progress_text.is_empty()
	# 新目标滑入感
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.35)


## 当前目标完成：移入已完成列表（打勾 + 淡绿），返回自身供链式
func mark_done(title: String) -> void:
	var done := Label.new()
	done.text = "✓ %s" % title
	done.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	done.add_theme_color_override("font_color", Color(0.45, 0.75, 0.5))
	_done_box.add_child(done)


## 全部完成：当前目标区收起，标题致谢
func show_all_done() -> void:
	_current_title.text = "▶ 自由探索"
	_current_desc.text = "Tab 战略图 · Q 战斗 · 附身微操 · 继续建造扩张"
	_progress_label.visible = false
