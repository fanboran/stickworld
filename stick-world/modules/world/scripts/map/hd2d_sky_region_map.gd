extends Control
## 城外舆图 —— HD-2D 城门选项框弹出时，悬在对应城门外上空的周边地区示意图。
##
## 地图与场景图 §5.5.5 实现要点 5（道路选择 UI 显示地图缩略图、标注当前城镇、
## 高亮可到达道路）的场景图 P0 版：数据 = SceneLoader 出口表（当前城直达一程
## + 村间道路对岸，见 hd2d_gate_prompt._build_region）；瓦片 = 城/村/资源地，
## 虚线 = 村间道路（带路名），点线 = 城门传送直达。选项框按钮悬浮 →
## set_highlight 点亮对应地块。
##
## 纯展示组件：mouse_filter IGNORE 不接输入，位置由选项框组件逐帧跟随
## "墙外投影点"钉在天空带上。绘制全部走 _draw + 样式缓存，可见时才挂。

## 面板尺寸（HudOverlay 槽内屏幕像素）
const PANEL_SIZE := Vector2(520, 316)

## 版式（面板本地 px）。三列：道路对岸/直达邻图同占一侧列（上下带分层），
## 当前城居中。region.nodes[].col 约定：0 = 当前城，±1 = 该侧直达邻图，
## ±2 = 该侧村间道路对岸（|col|≥2 即道路对岸带）。
const TILE_CURRENT := Vector2(150, 60)
const TILE_OTHER := Vector2(136, 52)
const COL_DX := 178.0          # 侧列相对当前城的横向间距
const BAND_ROAD_DY := -62.0    # 道路对岸带（中心上方）
const BAND_DIRECT_DY := 86.0   # 直达邻图带（中心下方）
const LANE_H := 64.0           # 同带多瓦片的纵向间距

## 配色（与选项框同一羊皮纸语言）
const COL_BG := Color(0.09, 0.08, 0.06, 0.88)
const COL_BORDER := Color(0.85, 0.82, 0.75, 0.75)
const COL_TEXT := Color(0.95, 0.92, 0.85)
const COL_TEXT_DIM := Color(0.78, 0.75, 0.68, 0.9)
const COL_TILE_BG := Color(0.16, 0.14, 0.11, 0.95)
const COL_TILE_BORDER := Color(0.72, 0.67, 0.56, 0.9)
const COL_CURRENT_BG := Color(0.11, 0.16, 0.21, 0.95)
const COL_CURRENT_BORDER := Color(0.45, 0.75, 0.95)
const COL_HL := Color(1.0, 0.84, 0.35)
const COL_ROAD := Color(0.74, 0.58, 0.38, 0.9)
const COL_TELEPORT := Color(0.75, 0.75, 0.75, 0.45)

var _region: Dictionary = {}
var _highlight_id: String = ""
var _font: Font

## 样式缓存（_ready 建一次，_draw 零分配重画）
var _sb_panel: StyleBoxFlat
var _sb_tile: StyleBoxFlat
var _sb_current: StyleBoxFlat
var _sb_hl: StyleBoxFlat
var _sb_glow: StyleBoxFlat


func _init() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_sb_panel = _make_box(COL_BG, COL_BORDER, 2, 8)
	_sb_tile = _make_box(COL_TILE_BG, COL_TILE_BORDER, 2, 6)
	_sb_current = _make_box(COL_CURRENT_BG, COL_CURRENT_BORDER, 2, 6)
	_sb_hl = _make_box(COL_TILE_BG, COL_HL, 3, 6)
	_sb_glow = _make_box(Color(COL_HL.r, COL_HL.g, COL_HL.b, 0.16),
			Color(COL_HL.r, COL_HL.g, COL_HL.b, 0.35), 6, 10)


func _make_box(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	return sb


## 喂入地区数据（结构见文件头 col 约定；空 nodes 不画）
func set_region(region: Dictionary) -> void:
	_region = region
	queue_redraw()


## 选项框按钮悬浮联动：点亮对应地块（"" = 清除）
func set_highlight(map_id: String) -> void:
	if map_id == _highlight_id:
		return
	_highlight_id = map_id
	queue_redraw()


func _draw() -> void:
	if _region.is_empty() or _font == null:
		return
	var nodes: Array = _region.get("nodes", [])
	if nodes.is_empty():
		return
	var links: Array = _region.get("links", [])

	# ── 版面：当前城列位置按邻接方向反推（只有西侧邻图 → 城瓦片靠右，
	# 让地图主体朝城外方向铺开），同侧列按"道路对岸上带 / 直达邻图下带"排车道
	var has_w := false
	var has_e := false
	for n: Dictionary in nodes:
		var c := int(n.get("col", 0))
		if c < 0:
			has_w = true
		elif c > 0:
			has_e = true
	var cx := size.x * (0.5 if (has_w and has_e) else (0.66 if has_w else 0.34))
	var cy := size.y * 0.56

	var road_lane := {}    # side(+1/-1) -> 已排道路对岸瓦片数
	var direct_lane := {}  # side(+1/-1) -> 已排直达瓦片数
	var rects := {}        # id -> Rect2
	for n: Dictionary in nodes:
		var id := String(n.get("id", ""))
		var col := int(n.get("col", 0))
		var pos: Vector2
		if col == 0:
			pos = Vector2(cx, cy)
			rects[id] = Rect2(pos - TILE_CURRENT * 0.5, TILE_CURRENT)
			continue
		var side := 1 if col > 0 else -1
		var lane_idx: int
		if absi(col) >= 2:
			lane_idx = int(road_lane.get(side, 0))
			road_lane[side] = lane_idx + 1
			pos = Vector2(cx + side * COL_DX, cy + BAND_ROAD_DY - lane_idx * LANE_H)
		else:
			lane_idx = int(direct_lane.get(side, 0))
			direct_lane[side] = lane_idx + 1
			pos = Vector2(cx + side * COL_DX, cy + BAND_DIRECT_DY + lane_idx * LANE_H)
		rects[id] = Rect2(pos - TILE_OTHER * 0.5, TILE_OTHER)

	var ci := get_canvas_item()
	# ── 面板底
	_sb_panel.draw(ci, Rect2(Vector2.ZERO, size))
	# ── 标题
	_draw_text("城外舆图", Vector2(18, 30), 15, COL_TEXT)

	# ── 连线（压在瓦片下）：村间道路=棕色虚线+路名，城门直达=灰点线
	for l: Dictionary in links:
		if not (rects.has(l.get("a")) and rects.has(l.get("b"))):
			continue
		var ra: Rect2 = rects[l.get("a")]
		var rb: Rect2 = rects[l.get("b")]
		var p1 := ra.get_center() + (rb.get_center() - ra.get_center()).normalized() * ra.size.x * 0.5
		var p2 := rb.get_center() - (rb.get_center() - ra.get_center()).normalized() * rb.size.x * 0.5
		var is_road := bool(l.get("road", false))
		draw_dashed_line(p1, p2, COL_ROAD if is_road else COL_TELEPORT,
				3.0 if is_road else 2.0, 12.0 if is_road else 4.0)
		if is_road and not String(l.get("label", "")).is_empty():
			var mid := (p1 + p2) * 0.5 + Vector2(0, -10)
			_draw_text_centered(String(l["label"]), mid, 12, COL_ROAD.lightened(0.25))

	# ── 瓦片（悬浮高亮：光晕 + 金边）
	for n: Dictionary in nodes:
		var id := String(n.get("id", ""))
		if not rects.has(id):
			continue
		var r: Rect2 = rects[id]
		var is_cur := bool(n.get("current", false))
		var hl := id == _highlight_id
		if hl:
			_sb_glow.draw(ci, r.grow(5.0))
		(_sb_current if is_cur else (_sb_hl if hl else _sb_tile)).draw(ci, r)
		var name_txt := String(n.get("name", id))
		_draw_text_centered(name_txt, r.get_center() + Vector2(0, 1), 14,
				COL_HL if hl else COL_TEXT)
		if is_cur:
			_draw_text_centered("你在这里", Vector2(r.get_center().x, r.end.y + 14), 12,
					COL_CURRENT_BORDER)

	# ── 图例（左下）
	var ly := size.y - 18.0
	draw_dashed_line(Vector2(18, ly - 4), Vector2(46, ly - 4), COL_ROAD, 3.0, 10.0)
	_draw_text("村间道路", Vector2(52, ly), 12, COL_TEXT_DIM)
	draw_dashed_line(Vector2(136, ly - 4), Vector2(164, ly - 4), COL_TELEPORT, 2.0, 4.0)
	_draw_text("城门传送", Vector2(170, ly), 12, COL_TEXT_DIM)


func _draw_text(txt: String, pos: Vector2, font_size: int, color: Color) -> void:
	draw_string(_font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_text_centered(txt: String, center: Vector2, font_size: int, color: Color) -> void:
	var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(_font, Vector2(center.x - w * 0.5, center.y), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
