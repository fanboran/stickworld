class_name SketchKeyboard
extends Control
## 手绘键盘说明图 —— ANSI 104 布局自绘（KeymapLayout）+ 按键注册表标注
## （KeyBindingRegistry）+ 实时按下高亮。
##
## 纯展示组件：不改按键、不消费事件（ESC 等模态语义不受影响，_input 只读）。
## 视觉状态：未绑定 = 凹槽暗底；绑定 = 微亮底 + 功能标注 + 域色点；按下 = 琥珀
## （唯一操作强调色）；悬停 = 强描边 + 自绘说明卡（不走引擎 tooltip，保持手绘语言）。
## 多域同键（本项目模式态常态）= 多个域色点，标注只显首个域的短语，细节进悬停卡。

const UNIT_MIN := 20.0
## 键帽视觉间隙（u）：键与键之间的缝隙
const CAP_INSET := 0.07
const DOT_R := 2.2
## 说明卡最大宽（px）
const TIP_W := 250.0

var _keys: Array[Dictionary] = []
var _annot: Dictionary = {}
var _domain_meta: Array[Dictionary] = []
var _filter: PackedStringArray = PackedStringArray()
var _pressed: Dictionary = {}
var _hover: int = -1
var _mouse_pos := Vector2.ZERO
var _seed: int = 0
var _boil: float = 0.0
var _u: float = UNIT_MIN
var _origin := Vector2.ZERO
var _font: Font = null


func _ready() -> void:
	_keys = KeymapLayout.load_ansi104()
	var data: Dictionary = KeyBindingRegistry.load_default()
	_domain_meta = KeyBindingRegistry.domains(data)
	_annot = KeyBindingRegistry.key_index(data)
	_font = SketchFonts.hand()
	if _font == null:
		_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_relayout)
	_relayout()


func _get_minimum_size() -> Vector2:
	var units := KeymapLayout.declared_units()
	return units * UNIT_MIN


func _relayout() -> void:
	var units := KeymapLayout.declared_units()
	_u = maxf(minf(size.x / units.x, size.y / units.y), 12.0)
	_origin = (size - units * _u) * 0.5
	queue_redraw()


## 域过滤（空 = 全部域）。重建标注表而非过滤绘制，悬停/点亮路径同源。
func set_domain_filter(domains: PackedStringArray) -> void:
	_filter = domains
	var data: Dictionary = KeyBindingRegistry.load_default()
	_annot = KeyBindingRegistry.key_index(data, domains)
	_hover = -1
	queue_redraw()


# ─────────────────────────────── 输入（只读，不消费）────────────────────────────────

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and not event.is_echo():
		var ek := event as InputEventKey
		var code: int = ek.keycode if ek.keycode != KEY_NONE else ek.physical_keycode
		if code == KEY_NONE or not _is_layout_key(code):
			return
		if ek.pressed:
			_pressed[code] = true
		else:
			_pressed.erase(code)
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_pos = (event as InputEventMouseMotion).position
		var idx := _hit_key(_mouse_pos)
		if idx != _hover:
			_hover = idx
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = -1
		queue_redraw()


func _is_layout_key(code: int) -> bool:
	for k: Dictionary in _keys:
		if int(k["code"]) == code:
			return true
	return false


func _hit_key(p: Vector2) -> int:
	var units := KeymapLayout.declared_units()
	var rel := (p - _origin) / _u
	for i in _keys.size():
		var k: Dictionary = _keys[i]
		if rel.x >= float(k["x"]) and rel.x < float(k["x"]) + float(k["w"]) \
				and rel.y >= float(k["y"]) and rel.y < float(k["y"]) + float(k["h"]):
			return i
	return -1


# ─────────────────────────────── 绘制 ────────────────────────────────

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_boil += delta
	if _boil >= SketchDraw.WOBBLE_INTERVAL:
		_boil = 0.0
		_seed += 7
		queue_redraw()


func _draw() -> void:
	for i in _keys.size():
		_draw_key(i)
	if _hover >= 0 and _hover < _keys.size():
		_draw_tip(_keys[_hover])


func _cap_rect(k: Dictionary) -> Rect2:
	return Rect2(_origin + Vector2(float(k["x"]) + CAP_INSET, float(k["y"]) + CAP_INSET) * _u,
			Vector2(float(k["w"]) - CAP_INSET * 2.0, float(k["h"]) - CAP_INSET * 2.0) * _u)


func _draw_key(i: int) -> void:
	var k: Dictionary = _keys[i]
	var rect := _cap_rect(k)
	if rect.size.x < 3.0:
		return
	var annots: Array = _annot.get(int(k["code"]), [])
	var pressed: bool = _pressed.has(int(k["code"]))
	var hovered: bool = _hover == i

	var fill := StickTokens.GROOVE_BG
	var outline := StickTokens.BORDER
	var legend_c := StickTokens.TEXT_FAINT
	if not annots.is_empty():
		fill = Color(1.0, 1.0, 1.0, 0.10)
		outline = StickTokens.BORDER_PANEL
		legend_c = StickTokens.TEXT_DIM
	if hovered:
		outline = StickTokens.BORDER_STRONG
	if pressed:
		if annots.is_empty():
			fill = Color(1.0, 1.0, 1.0, 0.18)
			legend_c = StickTokens.TEXT_DIM
		else:
			fill = StickTokens.ACCENT
			outline = StickTokens.ACCENT
			legend_c = StickTokens.INK

	SketchDraw.draw_panel(self, rect, _seed + i * 13, fill, outline, 1.2, 3.0)

	var legend: String = String(k["legend"])
	var cap_w: float = rect.size.x - 3.0
	if not annots.is_empty():
		# 键帽刻字收进左上角，功能标注占主视野
		draw_string(_font, rect.position + Vector2(3.0, 3.0 + _font.get_ascent(StickTokens.FONT_TINY)),
				legend, HORIZONTAL_ALIGNMENT_LEFT, -1, StickTokens.FONT_TINY, legend_c)
		_draw_action(rect, annots, pressed)
	else:
		_draw_centered(legend, rect.position + Vector2(rect.size.x * 0.5, rect.size.y * 0.5),
				StickTokens.FONT_TINY, legend_c, cap_w)
	_draw_domain_dots(rect, annots, pressed)


## 功能标注：首域短语（修饰键前缀并入；多域只显首个，域色点+悬停卡承载其余），
## 超宽折两行，仍放不下截断。
func _draw_action(rect: Rect2, annots: Array, pressed: bool) -> void:
	var first: Dictionary = annots[0]
	var text: String = String(first["label"])
	if first.has("mods"):
		var mods: PackedStringArray = first["mods"]
		if not mods.is_empty():
			text = "+".join(mods) + "·" + text
	var color := StickTokens.ACCENT_TEXT if pressed else StickTokens.TEXT
	var fs := StickTokens.FONT_TINY
	var max_w: float = rect.size.x - 4.0
	var lines := _wrap_text(text, max_w, fs, 2)
	var lh: float = _font.get_height(fs)
	var y0: float = rect.position.y + rect.size.y * 0.5 - lh * lines.size() * 0.5
	for j in lines.size():
		_draw_centered(lines[j], Vector2(rect.position.x + rect.size.x * 0.5, y0 + lh * (j + 0.5)),
				fs, color, max_w)


## 居中绘制（自测宽 + 左对齐落笔；超宽逐号缩字号到 8 兜底——键帽刻字永不溢出）。
func _draw_centered(text: String, center: Vector2, fs: int, color: Color, max_w: float) -> void:
	while fs > 8 and _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		fs -= 1
	var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(center.x - w * 0.5, center.y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _draw_domain_dots(rect: Rect2, annots: Array, pressed: bool) -> void:
	if annots.is_empty():
		return
	var data := KeyBindingRegistry.load_default()
	var shown: Array = []
	for a: Dictionary in annots:
		var dom: String = String(a["domain"])
		if not shown.has(dom):
			shown.append(dom)
	var n: float = shown.size()
	var cx: float = rect.position.x + rect.size.x * 0.5
	var cy: float = rect.end.y - 3.0
	for j in shown.size():
		var cid := KeyBindingRegistry.domain_color_id(data, shown[j])
		var col := StickTokens.content_color(cid)
		if pressed:
			col = _ink_mix(col)
		draw_circle(Vector2(cx - (n - 1.0) * 3.0 + 6.0 * j, cy), DOT_R, col)


## 按下态域点压成墨色系（琥珀底上内容色发灰，统一换深墨保持对比）
func _ink_mix(col: Color) -> Color:
	return Color(col.r * 0.25 + 0.05, col.g * 0.25 + 0.04, col.b * 0.25 + 0.03, 1.0)


func _wrap_text(text: String, max_w: float, fs: int, max_lines: int) -> PackedStringArray:
	var lines := PackedStringArray()
	if _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		lines.append(text)
		return lines
	# 逐字贪心装行（CJK 语义下单字不可拆）
	var cur := ""
	var rest := text
	while lines.size() < max_lines and not rest.is_empty():
		var take := ""
		for ch: String in rest:
			if _font.get_string_size(cur + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
				cur += ch
				take += ch
			else:
				break
		if take.is_empty():
			break
		lines.append(cur)
		rest = rest.substr(take.length())
		cur = ""
	if not rest.is_empty():
		var last: String = lines[lines.size() - 1]
		if last.length() > 1:
			lines[lines.size() - 1] = last.substr(0, last.length() - 1) + "…"
	return lines


## 自绘悬停说明卡：键名 + 各域标注（域色点 + 域名 + 短语 + 说明）。
func _draw_tip(k: Dictionary) -> void:
	var annots: Array = _annot.get(int(k["code"]), [])
	var data := KeyBindingRegistry.load_default()
	var fs := StickTokens.FONT_HINT
	var lh: float = _font.get_height(fs) + 2.0
	var title_fs := StickTokens.FONT_SECTION
	# 行装配：标题行 + 每标注一行（说明超宽再折行）
	var rows: Array = [{"kind": "title", "text": "按键 " + String(k["legend"])}]
	for a: Dictionary in annots:
		var dom_title := KeyBindingRegistry.domain_title(data, String(a["domain"]))
		var line: String = "［%s］%s" % [dom_title, a["label"]]
		if not String(a["note"]).is_empty():
			line += " — " + String(a["note"])
		rows.append({"kind": "annot", "text": line, "domain": a["domain"]})
	if annots.is_empty():
		rows.append({"kind": "annot", "text": "（未绑定功能）", "domain": ""})

	var w: float = 0.0
	var flat_rows: Array = []
	for r: Dictionary in rows:
		var lines := _wrap_text(String(r["text"]), TIP_W - 16.0, fs, 3)
		for line: String in lines:
			flat_rows.append({"kind": r["kind"], "text": line, "domain": r.get("domain", "")})
			w = maxf(w, _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	w += 16.0
	var h: float = _font.get_height(title_fs) + 8.0 + lh * flat_rows.size() + 6.0
	var pos := _mouse_pos + Vector2(14.0, 10.0)
	pos.x = minf(pos.x, size.x - w - 4.0)
	pos.y = minf(pos.y, size.y - h - 4.0)
	var tip := Rect2(pos, Vector2(w, h))
	SketchDraw.draw_panel(self, tip, _seed + 991, StickTokens.WINDOW_BG,
			StickTokens.BORDER_PANEL, 1.3, 5.0)
	draw_string(_font, tip.position + Vector2(8.0, 4.0 + _font.get_ascent(title_fs)),
			String(rows[0]["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, title_fs, StickTokens.ACCENT)
	var y: float = tip.position.y + _font.get_height(title_fs) + 8.0
	for r: Dictionary in flat_rows:
		if r["kind"] == "annot":
			var dom: String = String(r["domain"])
			if not dom.is_empty():
				var col := StickTokens.content_color(
						KeyBindingRegistry.domain_color_id(data, dom))
				draw_circle(tip.position + Vector2(12.0, y + _font.get_ascent(fs) * 0.4),
						2.6, col)
			draw_string(_font, tip.position + Vector2(18.0, y + _font.get_ascent(fs)),
					String(r["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, StickTokens.TEXT_DIM)
		y += lh
