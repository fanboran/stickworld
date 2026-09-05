class_name ComponentGallery
extends Control
## 组件展示页模板 —— 组件库的"活文档"：所有标准控件集中陈列、可交互验证。
##
## 设计要点（详见 docs/设计/UI/06-组件库.md）：
## - 每个组件的真实样式即主题样式（改 token → 本页立即反映，做回归自检页用）
## - 分组数据驱动（SECTIONS）：加一组 = 加一行 id，构建函数按 id 分发
##
## F6 直接运行可预览。

const INDEX_SCENE := "res://modules/ui_global/scenes/templates/template_index.tscn"

## 分组清单（构建函数 _build_<id>）
const SECTIONS: Array[String] = [
	"buttons", "labels", "inputs", "sliders", "lists", "feedback",
]

@onready var _content: VBoxContainer = $Window/MainVBox/Scroll/ContentVBox
@onready var _title_label: Label = $Window/MainVBox/Header/TitleLabel
@onready var _nav_button: Button = $Window/MainVBox/Header/NavButton


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_nav_button.pressed.connect(func(): get_tree().change_scene_to_file(INDEX_SCENE))
	for section_id in SECTIONS:
		call("_build_" + section_id)
		StickKit.separator(_content)


# ─────────────────────────────── 按钮族 ────────────────────────────────

func _build_buttons() -> void:
	var sec := StickKit.section(_content, "按钮 / BUTTON")
	var row1 := StickKit.row(sec)
	StickKit.button(row1, "普通按钮", _demo_toast("普通按钮"))
	StickKit.button(row1, "强调按钮", _demo_toast("强调按钮"), StickKit.ButtonKind.ACCENT)
	StickKit.button(row1, "危险按钮", _demo_toast("危险按钮"), StickKit.ButtonKind.DANGER)
	var disabled := StickKit.button(row1, "禁用按钮")
	disabled.disabled = true
	var row2 := StickKit.row(sec)
	StickKit.label(row2, "尺寸：", StickKit.LabelKind.HINT)
	StickKit.button(row2, "小型 26", Callable(), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	StickKit.button(row2, "标准 32", Callable(), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
	StickKit.button(row2, "大型 44", Callable(), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)


# ─────────────────────────────── 标签族 ────────────────────────────────

func _build_labels() -> void:
	var sec := StickKit.section(_content, "标签 / LABEL")
	StickKit.label(sec, "大标题 TITLE 22 —— 面板标题", StickKit.LabelKind.TITLE)
	StickKit.label(sec, "区块 SECTION 13 —— 分节小标题", StickKit.LabelKind.SECTION)
	StickKit.label(sec, "正文 BODY 14 —— 按钮与正文文字", StickKit.LabelKind.BODY)
	StickKit.label(sec, "提示 HINT 11 —— 辅助说明文字", StickKit.LabelKind.HINT)
	StickKit.label(sec, "角标 TINY 10 —— 徽标与极密列表", StickKit.LabelKind.TINY)
	var row := StickKit.row(sec)
	StickKit.label(row, "语义色：", StickKit.LabelKind.HINT)
	StickKit.label(row, "强调琥珀", StickKit.LabelKind.BODY, StickTokens.ACCENT)
	StickKit.label(row, "信息", StickKit.LabelKind.BODY, StickTokens.INFO)
	StickKit.label(row, "警告", StickKit.LabelKind.BODY, StickTokens.WARN)
	StickKit.label(row, "危险", StickKit.LabelKind.BODY, StickTokens.DANGER)
	StickKit.label(row, "成功", StickKit.LabelKind.BODY, StickTokens.SUCCESS)


# ─────────────────────────────── 输入族 ────────────────────────────────

func _build_inputs() -> void:
	var sec := StickKit.section(_content, "输入 / INPUT")
	var row1 := StickKit.field_row(sec, "文本框", "LineEdit 聚焦显琥珀描边")
	var edit := LineEdit.new()
	edit.placeholder_text = "输入帝国名称…"
	edit.custom_minimum_size = Vector2(220, StickTokens.BTN_H)
	row1.add_child(edit)
	var row2 := StickKit.field_row(sec, "下拉选项", "OptionButton")
	var opt := OptionButton.new()
	for item in ["低", "中", "高", "极高"]:
		opt.add_item(item)
	opt.selected = 1
	opt.custom_minimum_size = Vector2(160, StickTokens.BTN_H)
	row2.add_child(opt)
	var row3 := StickKit.field_row(sec, "开关", "CheckButton / CheckBox")
	var toggle := CheckButton.new()
	toggle.button_pressed = true
	row3.add_child(toggle)
	var chk := CheckBox.new()
	chk.text = "复选项"
	row3.add_child(chk)


# ─────────────────────────────── 滑条与进度 ────────────────────────────────

func _build_sliders() -> void:
	var sec := StickKit.section(_content, "滑条与进度 / SLIDER & PROGRESS")
	var row1 := StickKit.field_row(sec, "滑条", "HSlider")
	var slider := SketchHSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.value = 65
	slider.custom_minimum_size = Vector2(260, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(slider)
	var row2 := StickKit.field_row(sec, "进度条", "ProgressBar（演示动画）")
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 40
	bar.custom_minimum_size = Vector2(260, 22)
	bar.show_percentage = true
	row2.add_child(bar)
	var tween := bar.create_tween()
	tween.set_loops()
	tween.tween_property(bar, "value", 100.0, 2.0)
	tween.tween_property(bar, "value", 20.0, 1.2)


# ─────────────────────────────── 列表 ────────────────────────────────

func _build_lists() -> void:
	var sec := StickKit.section(_content, "列表 / ITEM LIST")
	var list := ItemList.new()
	for item in ["第一步兵团 · 120人", "皇家工程队 · 45人", "中央科学院 · 230人",
			"北境行省官府 · 89人", "黑石商队 · 12人"]:
		list.add_item(item)
	list.custom_minimum_size = Vector2(0, 120)
	sec.add_child(list)


# ─────────────────────────────── 反馈（Toast / 确认框）────────────────────────────────

func _build_feedback() -> void:
	var sec := StickKit.section(_content, "反馈 / TOAST & CONFIRM")
	var row := StickKit.row(sec)
	StickKit.button(row, "信息 Toast", func(): StickKit.toast(self, "这是一条信息通知", "info"))
	StickKit.button(row, "警告 Toast", func(): StickKit.toast(self, "石料储备不足", "warn"))
	StickKit.button(row, "错误 Toast", func(): StickKit.toast(self, "编队已溃散", "error"))
	StickKit.button(row, "确认框", func():
		StickKit.confirm(self, "拆除建筑", "拆除后将返还 50% 材料，确定拆除「草棚」吗？",
				func(): StickKit.toast(self, "已拆除（演示）", "info"), "拆除", StickKit.ButtonKind.DANGER)
	, StickKit.ButtonKind.ACCENT)


# ─────────────────────────────── 内部 ────────────────────────────────

func _demo_toast(name: String) -> Callable:
	return func(): StickKit.toast(self, "点击：%s" % name, "info")
