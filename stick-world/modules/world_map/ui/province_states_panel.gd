extends PanelContainer
class_name ProvinceStatesPanel
## 战略图政权列表侧栏（需求 9）—— 当包各政权逐行「色块 + 政权名 + 都城名」。
##
## 数据：当前 L1 包的 states（state_id/name/color/capital_settlement_id）+ tiles[].settlement
## （name/position），由控制器在 open / 切省后经 set_data 注入（包切换即整表刷新）。
## 行点击 = 相机聚焦该政权都城所在地块（走控制器注入的 focus_fn，复用既有相机聚焦路径；
## 本文件不认识相机/api，只出 settlement_id）。
##
## 停靠右侧中部（垂直居中、贴右安全边距）：避让右下图例（MapLegend）、
## 地图内的切省箭头环、顶部名牌与右上粒度指示器。
## 面板底 = 主题自带 SketchStyle 手绘贴图（与图例/指示器同一皮肤语言）；
## 行多时在面板内滚动（13~17 城邦一屏内可读）。
##
## 无政权数据（包为空）时隐藏——同 MapLegend 空态语义，set_shown 一律走本文件。
## 根 IGNORE 鼠标（不挡地图拖拽），行按钮照常收点击（mouse_filter 逐控件判定）。

## 面板停靠尺寸（贴右缘、竖直居中；高容标题 + 13 行，超出滚动；
## 宽度留足「色块+政权名+都城名」一行不裁）
const PANEL_SIZE := Vector2(248.0, 420.0)
## 行内色块边长（px）
const SWATCH_SIZE := 12.0
## 行内容左右内边距（按钮自绘底贴边，内容内缩一圈）
const ROW_PAD := 8.0

## 行激活回调（控制器注入；收 settlement_id）
var focus_fn: Callable = Callable()

var _title_label: Label = null
var _scroll: ScrollContainer = null
var _rows_box: VBoxContainer = null
## 当前行按钮（重建时全清；测试/调试读取）
var _rows: Array[Button] = []
## 空态：无政权数据时 set_shown 不再显示面板
var _empty := true


func _ready() -> void:
	theme = StickTheme.create()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 右侧中部：anchor = 右缘 + 垂直居中，再由 offset 收敛到固定尺寸矩形
	# （CanvasLayer 直下 Control 必须自设 anchors 与 offsets，只设 anchors 会保持旧矩形跑位）
	set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	offset_right = -StickTokens.SCREEN_MARGIN
	offset_left = offset_right - PANEL_SIZE.x
	offset_top = -PANEL_SIZE.y * 0.5
	offset_bottom = PANEL_SIZE.y * 0.5
	custom_minimum_size = PANEL_SIZE
	_build_widgets()
	visible = false


func _build_widgets() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)
	_title_label = StickKit.label(vbox, "政权", StickKit.LabelKind.SECTION)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 面板尺寸由 anchor 定，滚动区首帧才布局出宽度；尺寸变化时把行宽对齐可视宽
	_scroll.resized.connect(_refresh_row_width)
	vbox.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_rows_box)


## 喂当前包数据（控制器 open / 切省后调用）：整表重建政权行；null/无政权 = 空态隐藏。
func set_data(data: L1WorldData) -> void:
	if _rows_box == null:
		return
	for b in _rows:
		_rows_box.remove_child(b)
		b.queue_free()
	_rows.clear()
	if data != null:
		for state_id in data.states:
			_add_row(_state_entry(data, str(state_id)))
	_empty = _rows.is_empty()
	if _empty:
		visible = false
		return
	if _title_label != null:
		_title_label.text = "政权 · %d" % _rows.size()
	_refresh_row_width()


## 单条政权行数据（state_id/name/color/capital 都城名/settlement_id 都城聚落）
func _state_entry(data: L1WorldData, state_id: String) -> Dictionary:
	var info: Dictionary = data.states.get(state_id, {})
	var capital_id := str(info.get("capital_settlement_id", ""))
	var capital_name := ""
	for tile in data.tiles:
		if tile.settlement != null and tile.settlement.settlement_id == capital_id:
			capital_name = tile.settlement.name
			break
	if capital_name.is_empty():
		capital_name = capital_id
	return {
		"state_id": state_id,
		"name": str(info.get("name", state_id)),
		"color": data.get_state_color(state_id),
		"capital": capital_name,
		"settlement_id": capital_id,
	}


## 单行：手绘按钮底 + 内嵌「色块 + 政权名 + 都城名」（内容挂按钮的子控件，
## 点击整行 = 聚焦都城；子控件 IGNORE 鼠标，不抢按钮点击）
func _add_row(e: Dictionary) -> void:
	var row := StickKit.sketch_button(_rows_box, "", _on_row_pressed.bind(e),
			StickKit.ButtonKind.PAPER, StickTokens.BTN_H_SM)
	row.custom_minimum_size = Vector2(0.0, StickTokens.BTN_H_SM)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.tooltip_text = "聚焦 %s · 都城 %s" % [str(e.get("name", "")), str(e.get("capital", ""))]
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Button 非容器：子控件不进自动布局，用 FULL_RECT 锚点铺满按钮矩形再内缩
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = ROW_PAD
	box.offset_right = -ROW_PAD
	row.add_child(box)
	var swatch := ColorRect.new()
	swatch.color = e.get("color", Color.GRAY)
	swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(swatch)
	# PAPER 纸底是亮面：行内文字用深墨（TEXT_DIM/TEXT_FAINT 是暗底近白，纸底上隐形）
	var name_label := StickKit.label(box, str(e.get("name", "")), StickKit.LabelKind.HINT,
			StickTokens.INK)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cap_label := StickKit.label(box, str(e.get("capital", "")),
			StickKit.LabelKind.TINY, Color(StickTokens.INK, 0.62))
	cap_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cap_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.append(row)


func _on_row_pressed(e: Dictionary) -> void:
	var sid := str(e.get("settlement_id", ""))
	if not sid.is_empty() and focus_fn.is_valid():
		focus_fn.call(sid)


## 行宽 = 滚动区可视宽（行按钮不随内容撑出横向滚动条）
func _refresh_row_width() -> void:
	if _scroll == null:
		return
	var w: float = _scroll.size.x
	if w <= 1.0:
		w = PANEL_SIZE.x - 16.0
	for b in _rows:
		b.custom_minimum_size = Vector2(w, StickTokens.BTN_H_SM)


## 显隐（空态感知）：无政权时无论传什么都保持隐藏。
## 控制器同步视图显隐用本方法，不要直接改 visible（会被空态覆盖语义）。
func set_shown(v: bool) -> void:
	visible = v and not _empty


## 当前政权行数（测试/调试读取）
func row_count() -> int:
	return _rows.size()
