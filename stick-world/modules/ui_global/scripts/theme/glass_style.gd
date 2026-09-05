class_name GlassStyle
extends RefCounted
## 玻璃窗 StyleBox 工厂（StyleBoxFlat 实现）—— 主菜单 / 载入屏专用变体。
##
## 「窗户不是海报」的原始实现：纯白极低 alpha 底 + 1px 低透明白描边 + 小圆角。
## 与 SketchStyle（手绘皮肤）接口一一对应，StickTheme 按 Mode 分流。


# ─────────────────────────────── 窗体 ────────────────────────────────

static func window_panel() -> StyleBoxFlat:
	return _make(StickTokens.WINDOW_BG, StickTokens.BORDER, StickTokens.RADIUS_PANEL,
			StickTokens.PAD_X * 2, StickTokens.PAD_Y * 2)


static func window_panel_light() -> StyleBoxFlat:
	return _make(StickTokens.WINDOW_BG_LIGHT, StickTokens.BORDER, StickTokens.RADIUS,
			StickTokens.PAD_X, StickTokens.PAD_Y)


static func groove() -> StyleBoxFlat:
	return _make(StickTokens.GROOVE_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X, StickTokens.PAD_Y)


# ─────────────────────────────── 按钮族 ────────────────────────────────

static func button_normal() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG, StickTokens.BORDER, StickTokens.RADIUS)


static func button_hover() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG_HOVER, StickTokens.BORDER_STRONG, StickTokens.RADIUS)


static func button_pressed() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG_PRESSED, StickTokens.ACCENT, StickTokens.RADIUS)


static func button_disabled() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG_DISABLED, Color.TRANSPARENT, StickTokens.RADIUS)


static func accent_normal() -> StyleBoxFlat:
	return _make(StickTokens.ACCENT_BG, StickTokens.ACCENT, StickTokens.RADIUS)


static func accent_hover() -> StyleBoxFlat:
	var s := accent_normal()
	s.bg_color = Color(StickTokens.ACCENT, 0.18)
	return s


static func accent_pressed() -> StyleBoxFlat:
	var s := accent_normal()
	s.bg_color = Color(StickTokens.ACCENT, 0.08)
	return s


static func danger_normal() -> StyleBoxFlat:
	return _make(StickTokens.DANGER_BG, StickTokens.DANGER, StickTokens.RADIUS)


static func danger_hover() -> StyleBoxFlat:
	var s := danger_normal()
	s.bg_color = Color(StickTokens.DANGER, 0.22)
	return s


# ─────────────────────────────── 标签页 ────────────────────────────────

static func tab_normal() -> StyleBoxFlat:
	return _make(Color.TRANSPARENT, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


static func tab_hover() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


static func tab_selected() -> StyleBoxFlat:
	var s := _make(StickTokens.ACCENT_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)
	s.border_width_bottom = 2
	s.border_color = StickTokens.ACCENT
	return s


# ─────────────────────────────── 进度条 ────────────────────────────────

static func progress_bg() -> StyleBoxFlat:
	return _make(StickTokens.GROOVE_BG, StickTokens.BORDER, StickTokens.RADIUS)


static func progress_fill() -> StyleBoxFlat:
	return _make(StickTokens.ACCENT, Color.TRANSPARENT, StickTokens.RADIUS)


# ─────────────────────────────── 分隔线 ────────────────────────────────

static func separator() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = StickTokens.BORDER
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s


static func vseparator() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = StickTokens.BORDER
	s.content_margin_left = 0
	s.content_margin_right = 0
	return s


# ─────────────────────────────── 内部 ────────────────────────────────

static func _make(bg: Color, border: Color, radius: int,
		pad_x: int = StickTokens.PAD_X, pad_y: int = StickTokens.PAD_Y) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	if border.a > 0.0:
		s.border_width_left = StickTokens.BORDER_W
		s.border_width_top = StickTokens.BORDER_W
		s.border_width_right = StickTokens.BORDER_W
		s.border_width_bottom = StickTokens.BORDER_W
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	return s
