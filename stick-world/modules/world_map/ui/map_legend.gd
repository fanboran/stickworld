extends PanelContainer
class_name MapLegend
## 战略图右下角图例 —— 色块 + 文字条目，数据驱动
##
## 接口即 Phase B 模式系统的预留位：MapModeManager（B4）实装后，切模式时
## 调 set_title/set_entries 换整套内容（地形=群系色 / 政治=政权色），组件无模式概念。
## A2 落地形态：L1 视图挂一个实例，条目 = 出生 8 城邦政权色（与地图填充同色源）。
##
## 停靠右下角并整体抬高避让底部 MapHUD（H=56 通栏，控件集中左侧，抬高纯防视觉贴边）。
## 根 PASS 鼠标由子控件 IGNORE 覆盖，不挡地图拖拽/点击。

## 底部 MapHUD 高度 + 间隙（图例底边高于 HUD 顶边）
const BOTTOM_CLEAR := 64.0

## 色块边长（px）
const SWATCH_SIZE := 12.0

## 面板停靠尺寸（StickKit.dock 需要固定值；宽容纳条目文字，高按 8 条目 + 标题）
const PANEL_SIZE := Vector2(180.0, 220.0)

var _title_label: Label = null
var _entries_box: VBoxContainer = null

## 无条目状态（set_entries 置空后 set_shown 不再显示面板，免得只剩孤零零标题）
var _empty := true


func _ready() -> void:
	theme = StickTheme.create()
	add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	StickKit.dock(self, StickKit.Corner.BOTTOM_RIGHT, PANEL_SIZE)
	# 抬高避让底部 HUD：dock 之后改 top/bottom 偏移即可（left/right 不动）
	offset_top -= BOTTOM_CLEAR
	offset_bottom -= BOTTOM_CLEAR
	_build_widgets()


func _build_widgets() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)
	_title_label = StickKit.label(vbox, "图例", StickKit.LabelKind.SECTION)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_entries_box = VBoxContainer.new()
	_entries_box.add_theme_constant_override("separation", 4)
	_entries_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_entries_box)


## 设置图例标题（分组语义，如 "政权" / "群系"；Phase B 按模式切换调用）
func set_title(title: String) -> void:
	if _title_label == null:
		return
	_title_label.text = "图例 · %s" % title if not title.is_empty() else "图例"


## 换条目（数据驱动，旧条目全清）：
## entries: Array[{color: Color, text: String}]，空数组 = 清空并进入空态隐藏
func set_entries(entries: Array) -> void:
	if _entries_box == null:
		return
	_empty = entries.is_empty()
	# 先脱离树再延迟释放：同一帧内重复 set_entries（连开视图）时
	# get_child_count 立即正确，不残留待删节点
	for child in _entries_box.get_children():
		_entries_box.remove_child(child)
		child.queue_free()
	for e in entries:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_entries_box.add_child(row)
		var swatch := ColorRect.new()
		swatch.color = e.get("color", Color.GRAY)
		swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var text := StickKit.label(row, str(e.get("text", "")), StickKit.LabelKind.HINT)
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER


## 显隐（空态感知）：无条目时无论传什么都保持隐藏。
## 控制器同步视图显隐用本方法，不要直接改 visible（会被空态覆盖语义）。
func set_shown(v: bool) -> void:
	visible = v and not _empty
