class_name SketchButton
extends Button
## 手绘涂鸦按钮 —— 视觉全由 SketchStyle 按钮变体表驱动（UI优化C）：
## kind 索引变体，_apply_flats 一次查表应用（底 / 五态字色 / 描边 / 伪粗 /
## 图标模式 / 底透明度），调用点零 add_theme_*_override——要新观感 = 加变体。
##
## 层级原理：native NOTIFICATION_DRAW 先画 stylebox 底 + 文字（Flat stylebox
## 走 SketchTextures 沸腾贴图，帧驱动），脚本 _draw()（子类如 SketchGearButton）
## 后执行叠加自绘描边。hover 微缩放/音效/信号行为由 StickKit 装配
## （与 StickKit.button 交互一致）。

## 变体键：与 SketchStyle.BUTTON_VARIANTS 键一致（同名同序，StickKit.ButtonKind
## 直转；NORMAL(0) → DARK 暗底默认档）
enum Kind { DARK = 0, ACCENT = 1, PRIMARY = 2, DANGER = 3, PAPER = 4, ICON_SQUARE = 5 }

@export var kind: Kind = Kind.DARK:
	set(v):
		kind = v
		_apply_flats()
		queue_redraw()
## 【废弃】亮背景纸面形态 → 用 kind = Kind.PAPER。保留兼容：置 true 等价切
## PAPER 变体；SketchGearButton 亮背景描边分支仍读它。
@export var ink_skin := false:
	set(v):
		ink_skin = v
		if v and kind != Kind.ICON_SQUARE:
			kind = Kind.PAPER
## 底透明度（-1 = 跟随变体默认；0~1 实例覆盖）。<1 时四态走独立盒（绕开静态
## 缓存，避免污染同槽位其他按钮）并降低盒 modulate alpha——新盒经
## SketchStyle._box 注册进帧轮换仍保持沸腾；文字/描边语义不变，只有纸底
## 透出背后场景。
@export_range(-1.0, 1.0) var bg_alpha := -1.0:
	set(v):
		bg_alpha = v
		_apply_flats()
		queue_redraw()
## 字号（0 = 主题默认）。随排版走（与按钮高度同类：实例管尺寸，变体管皮肤）。
@export var font_size := 0:
	set(v):
		font_size = v
		if font_size > 0:
			add_theme_font_size_override("font_size", font_size)
		else:
			remove_theme_font_size_override("font_size")
## 图标呈现模式（NONE = 跟随变体）。badge_left 走 StickKit.motif_badge 左缘
## 角标（不占排版位），inline_left 走 set_list_icon 行内（列表按钮），
## center 纯图标撑满（icon_square）。
var icon_mode: int = SketchStyle.IconMode.NONE:
	set(v):
		icon_mode = v
		_apply_flats()
		queue_redraw()

var _seed: int = 0
var _timer: float = 0.0


var _last_dark: bool = false

func _ready() -> void:
	_apply_flats()
	resized.connect(queue_redraw)


## 变体查表应用（底/字色/描边/内衬/图标/透明度一次取齐）。kind 运行时可切
## （设置分类选中态），每次重挂——创建路径与切换路径是同一份代码。
func _apply_flats() -> void:
	var v: Dictionary = SketchStyle.button_variant(kind)
	if v.get("self_draw", false):
		_apply_self_draw(v)
		return
	var base: StringName = v["base"]
	var alpha := _effective_bg_alpha(v)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var slot := StringName("%s_%s" % [base, state])
		if SketchTextures._frame_sets.is_empty():
			SketchTextures._load_all()
		if not SketchTextures._frame_sets.has(slot):
			slot = &"btn_normal"  # 缺档回退（accent/danger 无 disabled 档等）
		# 不透明走共享缓存；半透明每按钮独立盒（modulate 是盒级属性，
		# 共享缓存会把透明度串到所有同槽位按钮上）
		var sb := _box(slot) if alpha >= 1.0 else SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
		if alpha < 1.0:
			sb.modulate_color = Color(1, 1, 1, alpha)
		add_theme_stylebox_override(state, sb)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# 五态字色全从变体取（含 disabled——纸面亮底上主题白字禁用态不可读）
	var f: Dictionary = v["fonts"]
	add_theme_color_override("font_color", f["normal"])
	add_theme_color_override("font_hover_color", f["hover"])
	add_theme_color_override("font_pressed_color", f["pressed"])
	add_theme_color_override("font_focus_color", f["focus"])
	add_theme_color_override("font_disabled_color", f["disabled"])
	# 描边随变体：暗底白字靠 3px 墨边时间戳式高对比；亮底深墨字一律 0
	# （再加墨描边 = 笔画膨胀糊死，主菜单纸面按钮教训）
	var outline: int = v["outline"]
	add_theme_constant_override("outline_size", outline)
	if outline > 0:
		add_theme_color_override("font_outline_color", v["outline_color"])
	else:
		remove_theme_color_override("font_outline_color")
	# 伪粗随变体（主行动/强调笔画加重），无 bold 字体时还原主题手绘体
	var bold: Font = SketchFonts.bold() if v.get("bold", false) else null
	if bold != null:
		add_theme_font_override("font", bold)
	else:
		remove_theme_font_override("font")
	_apply_icon_mode(v)


func _effective_bg_alpha(v: Dictionary) -> float:
	return bg_alpha if bg_alpha >= 0.0 else float(v["bg_alpha"])


## 自绘档（icon_square）：底与沸腾描边由子类 _draw 绘制，这里只清贴图四态、
## 留内衬防贴沸腾描边、图标居中撑满
func _apply_self_draw(v: Dictionary) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxEmpty.new()
		for m in ["content_margin_left", "content_margin_right",
				"content_margin_top", "content_margin_bottom"]:
			sb.set(m, 2.0)
		add_theme_stylebox_override(state, sb)
	_apply_icon_mode(v)


## 图标呈现归变体管（icon_mode）：居中文字按钮一律 badge_left（左缘角标不占
## 排版，StickKit.motif_badge）；列表按钮 inline_left（行内，icon_max_width
## 组件自管——调用点禁止 add_theme_*_override）；center 纯图标撑满。
func _apply_icon_mode(v: Dictionary) -> void:
	var mode := icon_mode if icon_mode != SketchStyle.IconMode.NONE \
			else int(v.get("icon_mode", SketchStyle.IconMode.BADGE_LEFT))
	match mode:
		SketchStyle.IconMode.INLINE_LEFT:
			icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
			add_theme_constant_override("icon_max_width", SketchStyle.ICON_INLINE_MAX_WIDTH)
		SketchStyle.IconMode.CENTER:
			icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			expand_icon = true
		_:
			pass  # badge_left / none：角标机制在 StickKit.motif_badge，组件不参与排版


## 列表按钮行内图标入口（inline_left）：icon_max_width 由组件接管，
## 调用点不写 add_theme_constant_override
func set_list_icon(tex: Texture2D, max_width: int = SketchStyle.ICON_INLINE_MAX_WIDTH) -> void:
	icon_mode = SketchStyle.IconMode.INLINE_LEFT
	icon = tex
	icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_constant_override("icon_max_width", max_width)


static var _box_cache: Dictionary = {}


static func _box(slot: StringName) -> StyleBoxTexture:
	if not _box_cache.has(slot):
		_box_cache[slot] = SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
	return _box_cache[slot]
