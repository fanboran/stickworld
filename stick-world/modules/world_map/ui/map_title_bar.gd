extends PanelContainer
class_name MapTitleBar
## 战略图左上角视图名牌 —— 层级徽标 + 视图名 + 数据概览副标题
##
## 与其他 HUD 部件分工（P 社地图四角布局）：
##   左上 = 视图身份（你在看哪张图，本组件）
##   右上 = GranularityIndicator（层级 + 按键操作提示）
##   左下 = MapHUD（缩放条 + 模式按钮）
##   右下 = MapLegend（图例）
##
## 三视图各挂一个实例（strategic_map / strategic_map_l2 / strategic_map_l3 的
## CanvasLayer 直接子节点），控制器 open/close 同步显隐并喂内容：
##   L3：大世界 · N 地区
##   L2：地区 N · N 地块
##   L1：地块 #N · N 聚落
##
## 根 PASS 鼠标由子标签 IGNORE 覆盖，不挡地图拖拽/点击。

## 面板停靠尺寸（StickKit.dock 需要固定值；宽度容纳 TITLE 档 8 字符 + 副标题）
const PANEL_SIZE := Vector2(232.0, 60.0)

var _badge_label: Label = null
var _title_label: Label = null
var _subtitle_label: Label = null


func _ready() -> void:
	theme = StickTheme.create()
	add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	StickKit.dock(self, StickKit.Corner.TOP_LEFT, PANEL_SIZE)
	_build_widgets()


func _build_widgets() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	# 层级徽标（琥珀，竖直居中）：L3 / L2 / L1
	_badge_label = StickKit.label(row, "", StickKit.LabelKind.TINY, StickTokens.ACCENT)
	_badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	StickKit.vseparator(row)
	# 名称 + 副标题两行
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(vbox)
	_title_label = StickKit.label(vbox, "", StickKit.LabelKind.TITLE)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle_label = StickKit.label(vbox, "", StickKit.LabelKind.HINT)
	_subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle_label.visible = false


## 喂内容（由所属控制器在视图打开时调用）
## badge: 层级徽标（"L3"/"L2"/"L1"）；title: 视图名；subtitle: 数据概览（空 = 隐藏）
func set_content(badge: String, title: String, subtitle: String = "") -> void:
	if _title_label == null:
		return
	_badge_label.text = badge
	_title_label.text = title
	_subtitle_label.text = subtitle
	_subtitle_label.visible = not subtitle.is_empty()
