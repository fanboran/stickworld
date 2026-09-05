class_name SketchStyle
extends RefCounted
## 手绘贴图 StyleBox 工厂 —— SketchTextures 沸腾贴图组装成九宫格 StyleBoxTexture。
##
## MARGIN=10：矮按钮（30px）上下边带只占 20px，中心内容区剩 10px 不挤压。
## 边 TILE 平铺（cos 周期噪声无缝）、角固定、中心纯色拉伸。

const PANEL_PAD_X := 16
const PANEL_PAD_Y := 12


static func _box(slot: StringName, pad_x: int, pad_y: int) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	SketchTextures.register_box(sb, slot)
	sb.texture_margin_left = SketchTextures.MARGIN
	sb.texture_margin_right = SketchTextures.MARGIN
	sb.texture_margin_top = SketchTextures.MARGIN
	sb.texture_margin_bottom = SketchTextures.MARGIN
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


static func window_panel() -> StyleBoxTexture:
	return _box(&"panel", PANEL_PAD_X, PANEL_PAD_Y)


## PopupMenu 弹出菜单（底 = 主窗体贴图；悬停行 = hover 按钮贴图）
static func menu_panel() -> StyleBoxTexture:
	return _box(&"panel", StickTokens.PAD_X, StickTokens.PAD_Y)


static func menu_hover() -> StyleBoxTexture:
	return _box(&"btn_hover", StickTokens.PAD_X + 2, 2)


static func window_panel_light() -> StyleBoxTexture:
	return _box(&"panel_light", StickTokens.PAD_X + 4, StickTokens.PAD_Y + 3)


static func groove() -> StyleBoxTexture:
	return _box(&"groove", StickTokens.PAD_X, StickTokens.PAD_Y)


static func groove_focus() -> StyleBoxTexture:
	return _box(&"groove_focus", StickTokens.PAD_X, StickTokens.PAD_Y)


static func button_normal() -> StyleBoxTexture:
	return _box(&"btn_normal", StickTokens.PAD_X + 2, 2)


static func button_hover() -> StyleBoxTexture:
	return _box(&"btn_hover", StickTokens.PAD_X + 2, 2)


static func button_pressed() -> StyleBoxTexture:
	return _box(&"btn_pressed", StickTokens.PAD_X + 2, 2)


static func button_disabled() -> StyleBoxTexture:
	return _box(&"btn_disabled", StickTokens.PAD_X + 2, 2)


static func accent_normal() -> StyleBoxTexture:
	return _box(&"accent_normal", StickTokens.PAD_X + 2, 2)


static func accent_hover() -> StyleBoxTexture:
	return _box(&"accent_hover", StickTokens.PAD_X + 2, 2)


static func accent_pressed() -> StyleBoxTexture:
	return _box(&"accent_pressed", StickTokens.PAD_X + 2, 2)


static func danger_normal() -> StyleBoxTexture:
	return _box(&"danger_normal", StickTokens.PAD_X + 2, 2)


static func danger_hover() -> StyleBoxTexture:
	return _box(&"danger_hover", StickTokens.PAD_X + 2, 2)


static func tab_normal() -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = StickTokens.PAD_X + 4
	s.content_margin_right = StickTokens.PAD_X + 4
	s.content_margin_top = StickTokens.PAD_Y + 2
	s.content_margin_bottom = StickTokens.PAD_Y + 2
	return s


static func tab_hover() -> StyleBoxTexture:
	return _box(&"tab_hover", StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


static func tab_selected() -> StyleBoxTexture:
	return _box(&"tab_selected", StickTokens.PAD_X + 4, StickTokens.PAD_Y + 2)


static func progress_bg() -> StyleBoxTexture:
	return _box(&"progress_bg", StickTokens.PAD_X, 2)


static func progress_fill() -> StyleBoxTexture:
	return _box(&"progress_fill", 3, 2)


static func separator() -> StyleBoxTexture:
	return _sep_box(&"sep_h")


static func vseparator() -> StyleBoxTexture:
	return _sep_box(&"sep_v")


static func _sep_box(slot: StringName) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	SketchTextures.register_box(sb, slot)
	if slot == &"sep_h":
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
	else:
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
		sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		sb.content_margin_left = 3
		sb.content_margin_right = 3
	return sb
