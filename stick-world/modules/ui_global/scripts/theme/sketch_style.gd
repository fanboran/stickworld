class_name SketchStyle
extends RefCounted
## 手绘贴图 StyleBox 生成器 —— SketchTextures 沸腾贴图组装成九宫格 StyleBoxTexture。
##
## MARGIN=10：矮按钮（30px）上下边带只占 20px，中心内容区剩 10px 不挤压。
## 边 TILE 平铺（cos 周期噪声无缝）、角固定、中心纯色拉伸。

const PANEL_PAD_X := 16
const PANEL_PAD_Y := 12


# ───────────────────────── 按钮变体表（UI优化C）─────────────────────────
##
## 变体 = 全属性集，一处定义；调用点零 override——要新观感 = 加变体，
## 且先进 sketch_compare 陈列评审再入表（防变体表膨胀）。
## SketchButton.kind 直接索引本表，_apply_flats 一次查表应用
## （底 / 五态字色 / 描边 / 伪粗 / 图标模式 / 底透明度全从变体取）。
##
## 字段：
##   base          四态贴图槽位前缀（slot = base + "_normal/hover/pressed/disabled"）
##   fonts         五态字色 {normal / hover / pressed / focus / disabled}
##   outline       文字描边宽 px：3 = 时间戳式墨边（半透明底晒在任意亮度场景
##                 上仍可读）；0 = 无（亮底深墨字再加墨描边 = 笔画膨胀糊死，
##                 主菜单纸面按钮教训）
##   outline_color 描边色
##   bold          伪粗手绘体（主行动 / 强调笔画加重）
##   icon_mode     图标呈现（IconMode）
##   bg_alpha      底透明度默认（实例 bg_alpha >= 0 时覆盖）
##   self_draw     true = 组件自绘（icon_square 方底），不走贴图四态

## 图标呈现模式（把 motif_badge 的教训制度化：居中文字按钮一律 badge_left
## 左缘角标不占排版位，列表按钮 inline_left 行内，纯图标钮 center 撑满）
enum IconMode { NONE, BADGE_LEFT, INLINE_LEFT, CENTER }

## 列表行内图标宽度上限（inline_left 由组件自管，调用点不得 override）
const ICON_INLINE_MAX_WIDTH := 18

## 变体键 = SketchButton.Kind 序号（与 StickKit.ButtonKind 同名同序直转；
## ButtonKind.NORMAL(0) → DARK 暗底默认档）
const K_DARK := 0
const K_ACCENT := 1
const K_PRIMARY := 2
const K_DANGER := 3
const K_PAPER := 4
const K_ICON_SQUARE := 5

static var _variants: Dictionary = {}


## 按 SketchButton.Kind 取变体属性集（懒构建，跨类 const 引用不参与常量折叠）
static func button_variant(kind: int) -> Dictionary:
	if _variants.is_empty():
		_build_variants()
	return _variants[kind]


static func _build_variants() -> void:
	var warm_ink: Color = StickTokens.ACCENT_TEXT
	# DARK：btn 贴图暗底 / 四态字全白 / 3px 墨描边——游戏内面板与场景按钮
	# （时间戳式高对比，晒在任意亮度场景上可读）
	_variants[K_DARK] = {
		"base": &"btn",
		"fonts": {"normal": StickTokens.TEXT, "hover": StickTokens.TEXT,
			"pressed": StickTokens.TEXT, "focus": StickTokens.TEXT,
			"disabled": StickTokens.TEXT_DISABLED},
		"outline": 3, "outline_color": StickTokens.INK,
		"bold": false, "icon_mode": IconMode.BADGE_LEFT, "bg_alpha": 1.0,
	}
	# PAPER：btn_ink 纸面 / 暖墨四态 / 无描边——主菜单等亮底
	_variants[K_PAPER] = {
		"base": &"btn_ink",
		"fonts": {"normal": warm_ink, "hover": warm_ink, "pressed": warm_ink,
			"focus": warm_ink, "disabled": Color(warm_ink, 0.45)},
		"outline": 0, "outline_color": StickTokens.INK,
		"bold": false, "icon_mode": IconMode.BADGE_LEFT, "bg_alpha": 1.0,
	}
	# PRIMARY：实底琥珀 / 暖墨四态 / 无描边 / 伪粗——主行动点
	_variants[K_PRIMARY] = {
		"base": &"btn_primary",
		"fonts": {"normal": warm_ink, "hover": warm_ink, "pressed": warm_ink,
			"focus": warm_ink, "disabled": StickTokens.TEXT_DISABLED},
		"outline": 0, "outline_color": StickTokens.INK,
		"bold": true, "icon_mode": IconMode.BADGE_LEFT, "bg_alpha": 1.0,
	}
	# ACCENT：琥珀描边档 / 白 + 暖墨三态（normal 14% 琥珀暗面白字，
	# hover/pressed 亮面暖墨字）/ 伪粗——选中态 / 强调
	_variants[K_ACCENT] = {
		"base": &"accent",
		"fonts": {"normal": StickTokens.TEXT, "hover": warm_ink,
			"pressed": warm_ink, "focus": StickTokens.TEXT,
			"disabled": StickTokens.TEXT_DISABLED},
		"outline": 0, "outline_color": StickTokens.INK,
		"bold": true, "icon_mode": IconMode.BADGE_LEFT, "bg_alpha": 1.0,
	}
	# DANGER：红档 / 红系字 / 3px 墨描边——危险确认
	_variants[K_DANGER] = {
		"base": &"danger",
		"fonts": {"normal": StickTokens.DANGER, "hover": StickTokens.DANGER.lightened(0.15),
			"pressed": StickTokens.DANGER.lightened(0.3), "focus": StickTokens.DANGER,
			"disabled": StickTokens.TEXT_DISABLED},
		"outline": 3, "outline_color": StickTokens.INK,
		"bold": false, "icon_mode": IconMode.BADGE_LEFT, "bg_alpha": 1.0,
	}
	# ICON_SQUARE：自绘沸腾方底 / 无文字 / 沸腾描边 / center 图标——纯图标钮
	#（设置齿轮；底与描边由 SketchGearButton._draw 绘制）
	_variants[K_ICON_SQUARE] = {
		"base": &"",
		"fonts": {"normal": StickTokens.TEXT, "hover": StickTokens.TEXT,
			"pressed": StickTokens.TEXT, "focus": StickTokens.TEXT,
			"disabled": StickTokens.TEXT_DISABLED},
		"outline": 0, "outline_color": StickTokens.INK,
		"bold": false, "icon_mode": IconMode.CENTER, "bg_alpha": 1.0,
		"self_draw": true,
	}


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


## 主行动点（实底琥珀 + 深墨描边）：黑玻璃上是琥珀实体，亮天空上也读得清
## 「琥珀只上底不上字」（§1.5）的实体形态——14% 琥珀底只在暗底可读
static func primary_normal() -> StyleBoxTexture:
	return _box(&"btn_primary_normal", StickTokens.PAD_X + 2, 2)


static func primary_hover() -> StyleBoxTexture:
	return _box(&"btn_primary_hover", StickTokens.PAD_X + 2, 2)


static func primary_pressed() -> StyleBoxTexture:
	return _box(&"btn_primary_pressed", StickTokens.PAD_X + 2, 2)


static func primary_disabled() -> StyleBoxTexture:
	return _box(&"btn_primary_disabled", StickTokens.PAD_X + 2, 2)


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
