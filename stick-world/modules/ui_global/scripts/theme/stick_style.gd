class_name StickStyle
extends RefCounted
## StyleBox 样式工厂 —— 从 StickTokens 派生所有 StyleBoxFlat，一处改 token 全局生效。
##
## 只产样式不产控件；控件装配见 StickTheme（Theme 打包）与各模板脚本。


# ─────────────────────────────── 窗体 ────────────────────────────────

## 主窗体底（大面板/弹窗）：白色磨砂 + 柔和投影（不描边，投影造深度）
static func window_panel() -> StyleBoxFlat:
	var s := _make(StickTokens.WINDOW_BG, StickTokens.BORDER, StickTokens.RADIUS_PANEL,
			StickTokens.PAD_X * 2, StickTokens.PAD_Y * 2)
	s.shadow_color = Color(0.1, 0.16, 0.32, 0.28)
	s.shadow_size = StickTokens.PANEL_SHADOW_SIZE
	s.shadow_offset = StickTokens.PANEL_SHADOW_OFFSET
	return s


## 次窗体底（HUD 横条/内嵌区块）：深色玻璃（更透，"黑玻璃窗"）
static func window_panel_light() -> StyleBoxFlat:
	return _make(StickTokens.WINDOW_BG_LIGHT, StickTokens.BORDER, StickTokens.RADIUS,
			StickTokens.PAD_X, StickTokens.PAD_Y)


## 资源横条（白色磨砂薄条：无大投影、内边距紧凑，内容行不被压扁）
static func window_panel_strip() -> StyleBoxFlat:
	var s := _make(StickTokens.WINDOW_BG, Color.TRANSPARENT, 6,
			StickTokens.PAD_X, 4)
	s.shadow_color = Color(0.1, 0.16, 0.32, 0.22)
	s.shadow_size = 10.0
	s.shadow_offset = Vector2(0, 4)
	return s


## 纯底无边框（列表行/凹槽）
static func groove() -> StyleBoxFlat:
	return _make(StickTokens.GROOVE_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X, StickTokens.PAD_Y)


# ─────────────────────────────── 按钮族 ────────────────────────────────

## 真透明磨砂玻璃按钮：无白无黑底色（模糊层负责磨砂）+ 灰细边 + 上缘高光（受光边）
static func button_normal() -> StyleBoxFlat:
	var s := _make(StickTokens.BTN_BG, StickTokens.BTN_BORDER, StickTokens.RADIUS)
	_apply_glass_top_edge(s, StickTokens.BTN_EDGE_TOP)
	return s


static func button_hover() -> StyleBoxFlat:
	var s := _make(StickTokens.BTN_BG_HOVER, StickTokens.BTN_BORDER_STRONG, StickTokens.RADIUS)
	_apply_glass_top_edge(s, StickTokens.BTN_EDGE_TOP)
	return s


static func button_pressed() -> StyleBoxFlat:
	var s := _make(StickTokens.BTN_BG_PRESSED, StickTokens.ACCENT, StickTokens.RADIUS)
	_apply_glass_top_edge(s, Color(StickTokens.BTN_EDGE_TOP, 0.25))
	return s


static func button_disabled() -> StyleBoxFlat:
	var s := _make(StickTokens.BTN_BG_DISABLED, Color.TRANSPARENT, StickTokens.RADIUS)
	_apply_glass_top_edge(s, Color(StickTokens.BTN_EDGE_TOP, 0.15))
	return s


## 强调按钮（主行动点：新游戏/确定/应用）
static func accent_normal() -> StyleBoxFlat:
	return _make(StickTokens.ACCENT_BG, StickTokens.ACCENT, StickTokens.RADIUS)


static func accent_hover() -> StyleBoxFlat:
	var s := accent_normal()
	s.bg_color = Color(StickTokens.ACCENT, 0.26)
	return s


static func accent_pressed() -> StyleBoxFlat:
	var s := accent_normal()
	s.bg_color = Color(StickTokens.ACCENT, 0.08)
	return s


## 危险按钮（删除存档/放弃战斗）
static func danger_normal() -> StyleBoxFlat:
	return _make(StickTokens.DANGER_BG, StickTokens.DANGER, StickTokens.RADIUS)


static func danger_hover() -> StyleBoxFlat:
	var s := danger_normal()
	s.bg_color = Color(StickTokens.DANGER, 0.26)
	return s


# ─────────────────────────────── 标签页 ────────────────────────────────

## 未选中标签
static func tab_normal() -> StyleBoxFlat:
	return _make(Color.TRANSPARENT, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


static func tab_hover() -> StyleBoxFlat:
	return _make(StickTokens.BTN_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


## 选中标签：琥珀底光 + 底部 2px 强调条（用 border 底边模拟）
static func tab_selected() -> StyleBoxFlat:
	var s := _make(StickTokens.ACCENT_BG, Color.TRANSPARENT, StickTokens.RADIUS,
			StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)
	s.border_width_bottom = 2
	s.border_color = StickTokens.ACCENT
	return s


# ─────────────────────────────── 进度条 ────────────────────────────────

static func progress_bg() -> StyleBoxFlat:
	return _make(StickTokens.GROOVE_BG, StickTokens.BORDER, StickTokens.RADIUS)


static func progress_fill(color: Color = StickTokens.ACCENT) -> StyleBoxFlat:
	return _make(color, Color.TRANSPARENT, StickTokens.RADIUS)


# ─────────────────────────────── 分隔线 ────────────────────────────────

static func separator() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = StickTokens.BORDER
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s


# ─────────────────────────────── 内部 ────────────────────────────────

## 给 StyleBoxFlat 加上 1px 上缘高光（玻璃受光边，比其余边框更亮）
static func _apply_glass_top_edge(s: StyleBoxFlat, edge_color: Color) -> void:
	if s.border_width_top < 1:
		s.border_width_top = 1
	s.border_color = edge_color


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
