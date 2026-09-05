extends PanelContainer
class_name GranularityIndicator
## 战略图粒度指示器 —— 当前所处层级（L1/L2/L3）+ 按键操作提示
##
## 详见 docs/技术/架构/战略图架构.md §二 模块结构（ui/granularity_indicator.gd）
## 三视图各挂一个实例（strategic_map / strategic_map_l2 / strategic_map_l3 的
## Content 子节点，随视图显隐自动同步，控制器无需管理 visible）。
##
## 右上角停靠（自设 anchor + SCREEN_MARGIN，不贴边不与其他 HUD 抢位）；
## 根 PASS 鼠标由子 Label IGNORE 覆盖，不挡地图拖拽/点击。
##
## 提示文案与实际行为一一对应（Tab/M/ESC 语义见各控制器与 system_setup 接线）：
##   L3：点击地区下钻 · Tab 切地块视图 · ESC/M 关闭
##   L2：点击地块进入 L1 · ESC 返回大世界
##   L1 直开（Tab）：双击城市进入 · Tab/ESC 关闭 · M 切大世界
##   L1 下钻（来自 L2）：双击城市进入 · ESC 返回地区视图

## 视图层级标识（场景里设："L1" / "L2" / "L3"）
@export var view_level: String = "L1"

## 面板固定尺寸（StickKit.dock 需要；宽度容纳提示文案，高度容纳三行）
const PANEL_SIZE := Vector2(248.0, 76.0)

## 是否从上层视图下钻进入（L1 从 L2 下钻时 ESC 语义变为"返回 L2"）
var _drill: bool = false

var _title_label: Label = null
var _subtitle_label: Label = null
var _hint_label: Label = null

## 层级标题（单一真相源）
const LEVEL_TITLES := {
	"L3": "L3 · 大世界",
	"L2": "L2 · 地区",
	"L1": "L1 · 地块",
}


func _ready() -> void:
	theme = StickTheme.create()
	add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	# 右上角停靠：StickKit.dock 设全量 anchors+offsets（SCREEN_MARGIN 安全边距，不贴边）。
	# 不用 set_anchors_preset 单独设 anchors——它默认保持原视觉矩形，CanvasLayer 直下
	# 首次布局时 offset 残留大负值会把面板拉成通栏。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	StickKit.dock(self, StickKit.Corner.TOP_RIGHT, PANEL_SIZE)
	_build_widgets()
	_refresh()


func _build_widgets() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)
	_title_label = StickKit.label(vbox, "", StickKit.LabelKind.BODY, StickTokens.ACCENT)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_subtitle_label = StickKit.label(vbox, "", StickKit.LabelKind.TINY, StickTokens.TEXT_FAINT)
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_subtitle_label.visible = false
	_hint_label = StickKit.label(vbox, "", StickKit.LabelKind.TINY, StickTokens.TEXT_DIM)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


## 设置视图状态（由所属控制器在视图打开/切换时调用）
## subtitle: 当前聚焦对象（L1=地块号、L2=region_id、L3 空）
func set_view(level: String, subtitle: String = "", drill: bool = false) -> void:
	view_level = level
	_drill = drill
	_refresh()
	set_subtitle(subtitle)


## 更新副标题（不重算提示文案；L1 下钻换图等仅聚焦对象变化时用）
func set_subtitle(subtitle: String) -> void:
	if _subtitle_label == null:
		return
	_subtitle_label.text = subtitle
	_subtitle_label.visible = not subtitle.is_empty()


## 更新下钻状态（影响 L1 的 ESC 提示语义）
func set_drill(drill: bool) -> void:
	if _drill == drill:
		return
	_drill = drill
	_refresh()


func _refresh() -> void:
	if _title_label == null:
		return
	_title_label.text = String(LEVEL_TITLES.get(view_level, view_level))
	_hint_label.text = _hint_text()


## 按键提示：与控制器实际 ESC/Tab/M 行为一致（改交互须同步这里）
func _hint_text() -> String:
	match view_level:
		"L3":
			return "点击地区 下钻 · Tab 地块视图 · ESC/M 关闭"
		"L2":
			return "点击地块 进入 · ESC 返回大世界"
		"L1":
			if _drill:
				return "双击城市 进入 · ESC 返回地区视图"
			return "双击城市 进入 · Tab/ESC 关闭 · M 大世界"
	return ""
