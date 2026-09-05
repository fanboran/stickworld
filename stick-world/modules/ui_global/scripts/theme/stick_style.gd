class_name StickStyle
extends RefCounted
## StyleBox 样式工厂 —— Flat 玻璃样式分发（= GlassStyle 同实现）。
##
## 游戏内主视觉走自绘控件（scripts/sketch/，血条同源沸腾）；
## StickStyle 只服务 Theme 兜底与开发模板（templates/）的 StyleBox 需求。
## 调用方只认 StickStyle.xxx()，换肤不动调用点。


# ─────────────────────────────── 窗体 ────────────────────────────────

static func window_panel() -> StyleBox:
	return GlassStyle.window_panel()


static func window_panel_light() -> StyleBox:
	return GlassStyle.window_panel_light()


static func groove() -> StyleBox:
	return GlassStyle.groove()


## LineEdit 聚焦态：琥珀描边凹槽
static func groove_focus() -> StyleBox:
	return GlassStyle.groove()


# ─────────────────────────────── 按钮族 ────────────────────────────────

static func button_normal() -> StyleBox:
	return GlassStyle.button_normal()


static func button_hover() -> StyleBox:
	return GlassStyle.button_hover()


static func button_pressed() -> StyleBox:
	return GlassStyle.button_pressed()


static func button_disabled() -> StyleBox:
	return GlassStyle.button_disabled()


static func accent_normal() -> StyleBox:
	return GlassStyle.accent_normal()


static func accent_hover() -> StyleBox:
	return GlassStyle.accent_hover()


static func accent_pressed() -> StyleBox:
	return GlassStyle.accent_pressed()


static func danger_normal() -> StyleBox:
	return GlassStyle.danger_normal()


static func danger_hover() -> StyleBox:
	return GlassStyle.danger_hover()


# ─────────────────────────────── 标签页 ────────────────────────────────

static func tab_normal() -> StyleBox:
	return GlassStyle.tab_normal()


static func tab_hover() -> StyleBox:
	return GlassStyle.tab_hover()


static func tab_selected() -> StyleBox:
	return GlassStyle.tab_selected()


# ─────────────────────────────── 进度条 ────────────────────────────────

static func progress_bg() -> StyleBox:
	return GlassStyle.progress_bg()


static func progress_fill() -> StyleBox:
	return GlassStyle.progress_fill()


# ─────────────────────────────── 分隔线 ────────────────────────────────

static func separator() -> StyleBox:
	return GlassStyle.separator()


static func vseparator() -> StyleBox:
	return GlassStyle.vseparator()
