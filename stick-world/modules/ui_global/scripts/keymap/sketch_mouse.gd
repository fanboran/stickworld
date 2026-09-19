class_name SketchMouse
extends Control
## 手绘鼠标说明图 —— 轮廓自绘（掌托 + 键区双板 + 滚轮 + 左缘侧键）+ 注册表鼠标标注
## + 实时按下/滚轮高亮。与 SketchKeyboard 同一套视觉语言（状态色/域点/悬停卡）。

const BODY_ASPECT := 0.62  # 宽/高
const DOT_R := 2.2
const TIP_W := 250.0
const WHEEL_FLASH := 0.35

## 可点区域（相对掌托矩形的比例坐标）：LEFT/RIGHT 覆盖键区上半，MIDDLE 归滚轮带，
## 侧键贴左缘外凸。滚轮上/下不占区域，点亮画在滚轮带上侧/下侧小箭头。
const REGIONS: Array[Dictionary] = [
	{"id": "LEFT", "label": "左键", "r": Rect2(0.02, 0.02, 0.44, 0.28)},
	{"id": "RIGHT", "label": "右键", "r": Rect2(0.54, 0.02, 0.44, 0.28)},
	{"id": "MIDDLE", "label": "中键", "r": Rect2(0.42, 0.02, 0.16, 0.26)},
	{"id": "XBUTTON1", "label": "侧键·后", "r": Rect2(-0.055, 0.34, 0.06, 0.12)},
	{"id": "XBUTTON2", "label": "侧键·前", "r": Rect2(-0.055, 0.50, 0.06, 0.12)},
]

var _annot: Dictionary = {}
var _domain_meta: Array[Dictionary] = []
var _filter: PackedStringArray = PackedStringArray()
var _pressed: Dictionary = {}
var _hover: String = ""
var _mouse_pos := Vector2.ZERO
var _wheel_dir: int = 0
var _wheel_t: float = 0.0
var _seed: int = 0
var _boil: float = 0.0
var _font: Font = null


func _ready() -> void:
	var data: Dictionary = KeyBindingRegistry.load_default()
	_domain_meta = KeyBindingRegistry.domains(data)
	_annot = KeyBindingRegistry.mouse_index(data)
	_font = SketchFonts.hand()
	if _font == null:
		_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


func _get_minimum_size() -> Vector2:
	return Vector2(112.0, 112.0 / BODY_ASPECT)


func set_domain_filter(domains: PackedStringArray) -> void:
	_filter = domains
	var data: Dictionary = KeyBindingRegistry.load_default()
	_annot = KeyBindingRegistry.mouse_index(data, domains)
	_hover = ""
	queue_redraw()


# ─────────────────────────────── 输入（只读，不消费）────────────────────────────────

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE, \
					MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2:
				if mb.pressed:
					_pressed[mb.button_index] = true
				else:
					_pressed.erase(mb.button_index)
				queue_redraw()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				_wheel_dir = 1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				_wheel_t = WHEEL_FLASH
				queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_pos = (event as InputEventMouseMotion).position
		var id := _hit_region(_mouse_pos)
		if id != _hover:
			_hover = id
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = ""
		queue_redraw()


func _hit_region(p: Vector2) -> String:
	var body := _body_rect()
	for reg: Dictionary in REGIONS:
		var r: Rect2 = _region_rect(reg, body)
		var pad := 4.0
		if r.grow(pad).has_point(p):
			return String(reg["id"])
	return ""


# ─────────────────────────────── 绘制 ────────────────────────────────

func _process(delta: float) -> void:
	if _wheel_t > 0.0:
		_wheel_t -= delta
		if _wheel_t <= 0.0:
			_wheel_t = 0.0
			queue_redraw()
	if not is_visible_in_tree():
		return
	_boil += delta
	if _boil >= SketchDraw.WOBBLE_INTERVAL:
		_boil = 0.0
		_seed += 11
		queue_redraw()


## 掌托矩形（键区占上 36%，掌托略宽出 6% 成肩形）
func _body_rect() -> Rect2:
	var h: float = size.y
	var w: float = h * BODY_ASPECT
	return Rect2((size.x - w) * 0.5, 0.0, w, h)


func _region_rect(reg: Dictionary, body: Rect2) -> Rect2:
	var r: Rect2 = reg["r"]
	return Rect2(body.position + Vector2(r.position.x * body.size.x, r.position.y * body.size.y),
			Vector2(r.size.x * body.size.x, r.size.y * body.size.y))


func _draw() -> void:
	var body := _body_rect()
	# 掌托（先画，托底）：微亮底 + 底部「鼠标」刻字，避免深底读成空洞
	var palm := Rect2(body.position.x - body.size.x * 0.03, body.position.y + body.size.y * 0.30,
			body.size.x * 1.06, body.size.y * 0.70)
	SketchDraw.draw_panel(self, palm, _seed + 1, Color(1.0, 1.0, 1.0, 0.06),
			StickTokens.BORDER_PANEL, 1.3, body.size.x * 0.22)
	_draw_centered("鼠标", Vector2(palm.get_center().x, palm.end.y - 10.0),
			StickTokens.FONT_TINY, StickTokens.TEXT_FAINT, palm.size.x * 0.6)
	# 键区板（叠在掌托上，左/右键分界线 = 中缝波浪线）
	var deck := Rect2(body.position.x, body.position.y, body.size.x, body.size.y * 0.36)
	var deck_fill := Color(1.0, 1.0, 1.0, 0.10) if not _annot.is_empty() else StickTokens.GROOVE_BG
	SketchDraw.draw_panel(self, deck, _seed + 2, deck_fill, StickTokens.BORDER_PANEL,
			1.3, body.size.x * 0.20)
	var seam_y0 := deck.position.y + 2.0
	var seam_y1 := deck.position.y + deck.size.y * 0.82
	SketchDraw.draw_wavy_line(self, Vector2(deck.get_center().x, seam_y0),
			Vector2(deck.get_center().x, seam_y1), _seed + 3, StickTokens.BORDER, 1.1)
	# 滚轮带（中键/滚轮区域）
	var wheel := Rect2(deck.position.x + deck.size.x * 0.44, deck.position.y + deck.size.y * 0.10,
			deck.size.x * 0.12, deck.size.y * 0.62)
	_draw_wheel(wheel)
	# 左/右键 + 侧键区域（点亮填充 + 标注 + 域点）
	for reg: Dictionary in REGIONS:
		_draw_region(reg, _region_rect(reg, body))
	# 滚轮点亮箭头
	if _wheel_t > 0.0:
		_draw_wheel_arrow(wheel)
	if not _hover.is_empty():
		_draw_tip(_hover)


func _draw_wheel(wheel: Rect2) -> void:
	var mid_pressed: bool = _pressed.has(MOUSE_BUTTON_MIDDLE)
	var annots: Array = _annot.get(MOUSE_BUTTON_MIDDLE, [])
	var annots_up: Array = _annot.get(MOUSE_BUTTON_WHEEL_UP, [])
	var annots_down: Array = _annot.get(MOUSE_BUTTON_WHEEL_DOWN, [])
	var fill := Color(1.0, 1.0, 1.0, 0.10) if annots_up.size() + annots_down.size() > 0 \
			else StickTokens.GROOVE_BG
	var outline := StickTokens.BORDER_PANEL
	if mid_pressed:
		fill = StickTokens.ACCENT
		outline = StickTokens.ACCENT
	SketchDraw.draw_panel(self, wheel, _seed + 4, fill, outline, 1.1, wheel.size.x * 0.35)
	# 滚轮刻痕（两道横线，滚动感）
	for off: float in [0.3, 0.6]:
		var y: float = wheel.position.y + wheel.size.y * off
		SketchDraw.draw_wavy_line(self, Vector2(wheel.position.x + 1.5, y),
				Vector2(wheel.end.x - 1.5, y), _seed + 5, StickTokens.BORDER, 0.9)
	# 滚轮标注（缩放短语画在滚轮带右侧避让）
	if not annots_up.is_empty() or not annots_down.is_empty():
		var fs := StickTokens.FONT_TINY
		var text := "滚轮"
		var src: Array = annots_up if not annots_up.is_empty() else annots_down
		var col := StickTokens.TEXT
		if mid_pressed:
			text = String(src[0]["label"])
			col = StickTokens.ACCENT_TEXT
		else:
			text = String(src[0]["label"])
		draw_string(_font, Vector2(wheel.end.x + 6.0, wheel.get_center().y + _font.get_ascent(fs) * 0.5),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		_draw_dots(Vector2(wheel.end.x + 6.0, wheel.end.y + 4.0), _merge_domains([annots_up, annots_down]), mid_pressed)


func _draw_wheel_arrow(wheel: Rect2) -> void:
	var up: bool = _wheel_dir > 0
	var c: Color = StickTokens.ACCENT
	var cx: float = wheel.get_center().x
	var y: float = wheel.position.y - 8.0 if up else wheel.end.y + 8.0
	var dir: float = -1.0 if up else 1.0
	var pts := PackedVector2Array([
		Vector2(cx - 4.0, y + dir * 4.0), Vector2(cx + 4.0, y + dir * 4.0), Vector2(cx, y - dir * 4.0),
	])
	draw_colored_polygon(pts, c)
	var a: float = _wheel_t / WHEEL_FLASH
	draw_circle(Vector2(cx, y), 1.5, Color(c.r, c.g, c.b, a))


func _draw_region(reg: Dictionary, rect: Rect2) -> void:
	var id: String = String(reg["id"])
	var btn: int = KeyBindingRegistry.MOUSE_IDS.get(id, 0)
	var annots: Array = _annot.get(btn, [])
	var pressed: bool = _pressed.has(btn)
	var hovered: bool = _hover == id

	var fill := StickTokens.GROOVE_BG
	var outline := StickTokens.BORDER
	if not annots.is_empty():
		fill = Color(1.0, 1.0, 1.0, 0.10)
		outline = StickTokens.BORDER_PANEL
	if hovered:
		outline = StickTokens.BORDER_STRONG
	if pressed:
		fill = StickTokens.ACCENT if not annots.is_empty() else Color(1.0, 1.0, 1.0, 0.18)
		outline = StickTokens.ACCENT if not annots.is_empty() else StickTokens.BORDER_PANEL
	SketchDraw.draw_panel(self, rect, _seed + 6 + btn, fill, outline, 1.1, 2.5)

	# 标注：首域短语居中（侧键窄条放不下，只画域点）
	if rect.size.x >= 22.0:
		var fs := StickTokens.FONT_TINY
		var text := String(annots[0]["label"]) if not annots.is_empty() else ""
		var col := StickTokens.TEXT if not pressed else StickTokens.ACCENT_TEXT
		if text.is_empty():
			text = String(reg["label"])
			col = StickTokens.TEXT_FAINT if not pressed else StickTokens.TEXT_DIM
		_draw_centered(text, Vector2(rect.get_center().x,
				rect.get_center().y + _font.get_ascent(fs) * 0.5), fs, col, rect.size.x - 2.0)
	_draw_dots(Vector2(rect.get_center().x, rect.end.y - 3.0), _merge_domains([annots]), pressed)


## 居中绘制（自测宽 + 左对齐落笔；超宽逐号缩字号到 8 兜底）
func _draw_centered(text: String, center: Vector2, fs: int, color: Color, max_w: float) -> void:
	while fs > 8 and _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		fs -= 1
	var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(center.x - w * 0.5, center.y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _merge_domains(annot_sets: Array) -> Array:
	var out: Array = []
	for set: Array in annot_sets:
		for a: Dictionary in set:
			var dom: String = String(a["domain"])
			if not out.has(dom):
				out.append(dom)
	return out


func _draw_dots(center: Vector2, domains: Array, pressed: bool) -> void:
	if domains.is_empty():
		return
	var data := KeyBindingRegistry.load_default()
	var n: float = domains.size()
	for j in domains.size():
		var col := StickTokens.content_color(
				KeyBindingRegistry.domain_color_id(data, String(domains[j])))
		if pressed:
			col = Color(col.r * 0.25 + 0.05, col.g * 0.25 + 0.04, col.b * 0.25 + 0.03, 1.0)
		draw_circle(Vector2(center.x - (n - 1.0) * 3.0 + 6.0 * j, center.y), DOT_R, col)


## 自绘悬停说明卡（与键盘同款结构：区域名 + 各域标注行）
func _draw_tip(id: String) -> void:
	var btn: int = KeyBindingRegistry.MOUSE_IDS.get(id, 0)
	var annots: Array = _annot.get(btn, [])
	if btn == MOUSE_BUTTON_MIDDLE:
		annots = _annot.get(MOUSE_BUTTON_WHEEL_UP, []) + _annot.get(MOUSE_BUTTON_WHEEL_DOWN, [])
	var data := KeyBindingRegistry.load_default()
	var fs := StickTokens.FONT_HINT
	var lh: float = _font.get_height(fs) + 2.0
	var title_fs := StickTokens.FONT_SECTION
	var reg_label := id
	for reg: Dictionary in REGIONS:
		if String(reg["id"]) == id:
			reg_label = String(reg["label"])
	var rows: Array = [{"kind": "title", "text": "鼠标 " + reg_label}]
	if annots.is_empty():
		rows.append({"kind": "annot", "text": "（未绑定功能）", "domain": ""})
	for a: Dictionary in annots:
		var dom_title := KeyBindingRegistry.domain_title(data, String(a["domain"]))
		rows.append({"kind": "annot",
				"text": "［%s］%s — %s" % [dom_title, a["label"], a["note"]],
				"domain": a["domain"]})

	var w: float = 0.0
	for r: Dictionary in rows:
		w = maxf(w, _font.get_string_size(String(r["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	w = minf(w + 16.0, TIP_W)
	var h: float = _font.get_height(title_fs) + 8.0 + lh * (rows.size() - 1) + 6.0
	var pos := _mouse_pos + Vector2(14.0, 10.0)
	pos.x = minf(pos.x, size.x - w - 4.0)
	pos.y = minf(pos.y, size.y - h - 4.0)
	pos.x = maxf(pos.x, 0.0)
	pos.y = maxf(pos.y, 0.0)
	var tip := Rect2(pos, Vector2(w, h))
	SketchDraw.draw_panel(self, tip, _seed + 991, StickTokens.WINDOW_BG,
			StickTokens.BORDER_PANEL, 1.3, 5.0)
	draw_string(_font, tip.position + Vector2(8.0, 4.0 + _font.get_ascent(title_fs)),
			String(rows[0]["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, title_fs, StickTokens.ACCENT)
	var y: float = tip.position.y + _font.get_height(title_fs) + 8.0
	for i in range(1, rows.size()):
		var r: Dictionary = rows[i]
		var dom: String = String(r["domain"])
		if not dom.is_empty():
			var col := StickTokens.content_color(
					KeyBindingRegistry.domain_color_id(data, dom))
			draw_circle(tip.position + Vector2(12.0, y + _font.get_ascent(fs) * 0.4), 2.6, col)
		draw_string(_font, tip.position + Vector2(18.0, y + _font.get_ascent(fs)),
				String(r["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, StickTokens.TEXT_DIM)
		y += lh
