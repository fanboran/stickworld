extends PanelContainer
class_name TerritoryPanel
## 战略图据点面板 —— 已占/未易手清单（扩张循环 P4「疆域可观看可操作」）
##
## 逐据点列一行（名称 · 归属状态），点击行 = 地图定位到该聚落 + 走双击聚落同一条
## 交互链（未易手据点弹征伐确认 / 我方已占据点弹旅行窗）——面板与地图两条入口
## 共用控制器 activate_settlement，不各自复制分流逻辑。
##
## 归属与守军真值来自 expansion（WorldState.territories 的 owner/faction + 车轮战余量），
## 本文件属 world_map 不 preload expansion：数据与动作全由控制器注入
##   targets_fn:  () -> Array（expansion api.list_targets）
##   activate_fn: (target: Dictionary) -> void（控制器定位 + 激活）
## 领地状态变化经 EventBus.territory_state_changed 重刷（占领后清单/计数即时更新）。
##
## 停靠左上（下移避让名牌），无据点数据（expansion 未装配 / 配置为空）时隐藏
## ——同 MapLegend 空态语义，set_shown 一律走本文件。

## 名牌高度留白（面板顶边下移到名牌之下）
const TOP_CLEAR := 96.0
## 面板停靠尺寸（StickKit.dock 需固定值；高按 3 据点 + 标题）
const PANEL_SIZE := Vector2(236.0, 152.0)

## 数据源（控制器注入；未注入 = 空态）
var targets_fn: Callable = Callable()
## 行激活回调（控制器注入；收整条 target 字典，定位要用其中的 tile_key）
var activate_fn: Callable = Callable()

var _title_label: Label = null
var _rows_box: VBoxContainer = null
## 当前行按钮（重建时全清；测试/调试读取）
var _rows: Array[Button] = []
## 空态：无据点数据时 set_shown 不再显示面板
var _empty := true


func _ready() -> void:
	# 面板底 = 主题自带 SketchStyle 手绘贴图（与图例/指示器同一皮肤语言）
	theme = StickTheme.create()
	# 本体不吃鼠标（不挡地图拖拽），行按钮照常收点击（mouse_filter 逐控件判定）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	StickKit.dock(self, StickKit.Corner.TOP_LEFT, PANEL_SIZE)
	offset_top += TOP_CLEAR
	offset_bottom += TOP_CLEAR
	_build_widgets()
	if EventBus != null and not EventBus.territory_state_changed.is_connected(_on_territory_state_changed):
		EventBus.territory_state_changed.connect(_on_territory_state_changed)
	visible = false


func _build_widgets() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)
	_title_label = StickKit.label(vbox, "据点", StickKit.LabelKind.SECTION)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_rows_box)


## 重建清单（控制器注入回调后、地图打开时、领地状态变化时调用）
func refresh() -> void:
	if _rows_box == null:
		return
	# 先脱离树再延迟释放：同一帧内重复 refresh（连开视图）时 get_child_count 立即正确
	for b in _rows:
		_rows_box.remove_child(b)
		b.queue_free()
	_rows.clear()
	var targets: Array = targets_fn.call() if targets_fn.is_valid() else []
	var n_captured := 0
	for t in targets:
		if not (t is Dictionary):
			continue
		if bool((t as Dictionary).get("captured", false)):
			n_captured += 1
		_add_row(t as Dictionary)
	_empty = _rows.is_empty()
	if _empty:
		visible = false
		return
	if _title_label != null:
		_title_label.text = "据点 · %d/%d 已占" % [n_captured, _rows.size()]


## 单行：未易手用 DANGER 档（可征伐）/ 已占用 PAPER 档（巡视自家）
func _add_row(t: Dictionary) -> void:
	var captured := bool(t.get("captured", false))
	var display_name := String(t.get("name_zh", ""))
	var tail := "我方已占" if captured else "守军 %d" % int(t.get("garrison_count", 0))
	var row := StickKit.button(_rows_box, "%s · %s" % [display_name, tail],
			_on_row_pressed.bind(t),
			StickKit.ButtonKind.PAPER if captured else StickKit.ButtonKind.DANGER,
			StickTokens.BTN_H_SM)
	_rows.append(row)


func _on_row_pressed(target: Dictionary) -> void:
	if activate_fn.is_valid():
		activate_fn.call(target)


## 领地状态变化（ConquestManager 占领后广播）→ 清单重刷
func _on_territory_state_changed(_territory_id: String, _new_state: int) -> void:
	refresh()


## 显隐（空态感知）：无据点时无论传什么都保持隐藏。
## 控制器同步视图显隐用本方法，不要直接改 visible（会被空态覆盖语义）。
func set_shown(v: bool) -> void:
	visible = v and not _empty
