extends Control
## 城外舆图 —— Tab 战略图同源数据的悬浮版（出生 L1 世界，地图与场景图 §5.5.5
## 实现要点 5：道路选择 UI 显示大世界地图缩略图、标注当前城镇、高亮可到道路）。
##
## 数据 = GameRoot 常驻战略图 Api 的 L1WorldData（与 Tab 缩略窗 l1_thumbnail.gd
## 同源同视觉语言）：l1_base.png 底图 + 八城邦 + MST 路网。相比 120px 缩略窗
## 放大到可交互尺寸并叠加：路网折线（土路/铺装分色）、城邦名字牌、地块描边；
## 选项框悬浮某村庄项 → set_highlight 金框点亮对应地块；出生城沿用缩略窗的
## 白点 + 蓝脉冲扩散环标记。
##
## 纯展示组件：mouse_filter IGNORE 不接输入（交互在选项框按钮上），位置由
## 选项框组件逐帧跟随"墙外投影点"钉在天空带上。可见时才挂。

const PANEL_SIZE := Vector2(440, 440)
## 底图四周留白（面板边框 + 标题行）
const FIT_MARGIN := 34.0

## 配色（羊皮纸面板 + Tab 缩略窗标记语言）
const COL_BG := Color(0.09, 0.08, 0.06, 0.88)
const COL_BORDER := Color(0.85, 0.82, 0.75, 0.75)
const COL_TEXT := Color(0.95, 0.92, 0.85)
const COL_ROAD_DIRT := Color(0.62, 0.48, 0.33, 0.85)
const COL_ROAD_PAVED := Color(0.80, 0.74, 0.64, 0.9)
const COL_TILE_DIM := Color(1.0, 1.0, 1.0, 0.12)
const COL_HL := Color(1.0, 0.84, 0.35)
const COL_MARK_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const COL_PULSE := Color(0.35, 0.70, 1.0)
## 出生城脉冲（同 l1_thumbnail 口径）
const PULSE_PERIOD := 1.4
const PULSE_MAX_RADIUS := 16.0

var _data = null                  # L1WorldData（duck 引用，不跨模块类型依赖）
var _anchor_id: String = ""       # 出生/当前聚落（脉冲标记）
var _highlight_id: String = ""    # 悬浮高亮的聚落
var _anim_time: float = 0.0
var _fit_scale: float = 1.0
var _fit_offset: Vector2 = Vector2.ZERO
var _font: Font
var _tile_by_sid: Dictionary = {}   # settlement_id -> L1TileDef

## 样式缓存（_ready 建一次，_draw 零分配重画）
var _sb_panel: StyleBoxFlat
var _sb_chip: StyleBoxFlat
var _sb_chip_hl: StyleBoxFlat
var _sb_glow: StyleBoxFlat


func _init() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_sb_panel = _make_box(COL_BG, COL_BORDER, 2, 8)
	_sb_chip = _make_box(Color(0.12, 0.10, 0.08, 0.92), Color(0.72, 0.67, 0.56, 0.9), 1, 4)
	_sb_chip_hl = _make_box(Color(0.20, 0.16, 0.09, 0.95), COL_HL, 2, 4)
	_sb_glow = _make_box(Color(COL_HL.r, COL_HL.g, COL_HL.b, 0.14),
			Color(COL_HL.r, COL_HL.g, COL_HL.b, 0.4), 5, 8)


func _make_box(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	return sb


func _process(delta: float) -> void:
	if not visible:
		return
	# 出生城脉冲环动画（可见才重画）
	_anim_time += delta
	queue_redraw()


## 喂 Tab 战略图同源数据（api.get_data()；null = 数据未就绪，画占位）
func set_data(data, anchor_id: String) -> void:
	_data = data
	_anchor_id = anchor_id
	_highlight_id = ""
	_tile_by_sid.clear()
	if _data != null:
		var ctx := Vector2(maxf(float(_data.context_size.x), 1.0),
				maxf(float(_data.context_size.y), 1.0))
		var avail := PANEL_SIZE - Vector2(FIT_MARGIN, FIT_MARGIN) * 2.0
		_fit_scale = minf(avail.x / ctx.x, avail.y / ctx.y)
		var drawn := ctx * _fit_scale
		_fit_offset = (PANEL_SIZE - drawn) * 0.5
		for tile in _data.tiles:
			if tile.settlement != null:
				_tile_by_sid[str(tile.settlement.settlement_id)] = tile
	queue_redraw()


## 选项框按钮悬浮联动：点亮对应城邦地块（"" = 清除）
func set_highlight(settlement_id: String) -> void:
	if settlement_id == _highlight_id:
		return
	_highlight_id = settlement_id
	queue_redraw()


func _to_panel(p: Vector2) -> Vector2:
	return p * _fit_scale + _fit_offset


func _draw() -> void:
	if _font == null:
		return
	var ci := get_canvas_item()
	_sb_panel.draw(ci, Rect2(Vector2.ZERO, size))
	_draw_text("城外舆图", Vector2(18, 26), 15, COL_TEXT)
	if _data == null:
		_draw_text("暂无世界数据", Vector2(18, size.y * 0.5), 13,
				Color(0.75, 0.72, 0.65, 0.8))
		return

	# ── 底图（Tab 缩略窗同源 l1_base.png，等比适配居中）
	var ctx := Vector2(float(_data.context_size.x), float(_data.context_size.y))
	var base_rect := Rect2(_fit_offset, ctx * _fit_scale)
	if _data.base_texture != null:
		draw_texture_rect(_data.base_texture, base_rect, false)
	else:
		draw_rect(base_rect, Color(0.16, 0.15, 0.13, 0.9), true)

	# ── 地块描边（很淡，高亮时金框点亮）
	for tile in _data.tiles:
		var poly: PackedVector2Array = _scaled_closed(tile.polygon)
		if poly.size() < 3:
			continue
		var sid := ""
		if tile.settlement != null:
			sid = str(tile.settlement.settlement_id)
		if not sid.is_empty() and sid == _highlight_id:
			draw_polyline(poly, Color(COL_HL.r, COL_HL.g, COL_HL.b, 0.25), 7.0)
			draw_polyline(poly, COL_HL, 2.5)
		else:
			draw_polyline(poly, COL_TILE_DIM, 1.0)

	# ── 路网（土路细棕 / 铺装宽米白；MST 连通八城邦）
	for rd in _data.roads:
		var pts: PackedVector2Array = _scaled_open(rd.get("pts", PackedVector2Array()))
		if pts.size() < 2:
			continue
		var paved := str(rd.get("tier", "DIRT")) == "PAVED"
		draw_polyline(pts, COL_ROAD_PAVED if paved else COL_ROAD_DIRT,
				3.5 if paved else 2.0)

	# ── 城邦名字牌 + 出生城脉冲标记
	for sid: String in _tile_by_sid:
		var tile = _tile_by_sid[sid]
		var s = tile.settlement
		var pos := _to_panel(Vector2(s.position))
		var name_txt := str(s.name)
		if name_txt.is_empty():
			name_txt = str(s.settlement_id)
		var w := _font.get_string_size(name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var chip := Rect2(Vector2(pos.x - w * 0.5 - 6.0, pos.y - 9.0),
				Vector2(w + 12.0, 18.0))
		var hl: bool = sid == _highlight_id
		if hl:
			_sb_glow.draw(ci, chip.grow(4.0))
		(_sb_chip_hl if hl else _sb_chip).draw(ci, chip)
		_draw_text_centered(name_txt, Vector2(pos.x, pos.y + 4.0), 12,
				COL_HL if hl else COL_TEXT)
		if sid == _anchor_id:
			# 当前位置：白点 + 蓝色脉冲扩散环（l1_thumbnail 同款语言）
			draw_circle(pos, 2.5, COL_MARK_COLOR)
			var ph := fmod(_anim_time / PULSE_PERIOD, 1.0)
			draw_arc(pos, 4.0 + ph * (PULSE_MAX_RADIUS - 4.0), 0.0, TAU, 32,
					Color(COL_PULSE, 1.0 - ph), 1.5, true)

	# ── 图例（左下）
	var ly := size.y - 14.0
	draw_line(Vector2(18, ly - 4), Vector2(44, ly - 4), COL_ROAD_DIRT, 2.0)
	_draw_text("土路", Vector2(50, ly), 12, Color(0.78, 0.75, 0.68, 0.9))
	draw_line(Vector2(92, ly - 4), Vector2(118, ly - 4), COL_ROAD_PAVED, 3.5)
	_draw_text("铺装路", Vector2(124, ly), 12, Color(0.78, 0.75, 0.68, 0.9))


func _scaled_closed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(_to_panel(p))
	if out.size() > 2:
		out.append(out[0])   # 闭合
	return out


func _scaled_open(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(_to_panel(p))
	return out


func _draw_text(txt: String, pos: Vector2, font_size: int, color: Color) -> void:
	draw_string(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_text_centered(txt: String, center: Vector2, font_size: int, color: Color) -> void:
	var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(_font, Vector2(center.x - w * 0.5, center.y), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
