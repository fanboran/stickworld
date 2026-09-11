class_name SketchButton
extends Button
## 手绘涂鸦按钮 —— 底色走 Flat stylebox（引擎画、文字之下），
## boiling 手绘描边由 _draw() 叠加（血条同源算法，边缘区不碰文字）。
##
## 层级原理：native NOTIFICATION_DRAW 先画 stylebox 底 + 文字，
## 脚本 _draw() 后执行——只画边缘描边线（1.6px）就不会盖文字。
## hover 微缩放/音效/信号行为全部继承（与 StickKit.button 交互一致）。

enum Kind { NORMAL, ACCENT, PRIMARY, DANGER }

@export var kind: Kind = Kind.NORMAL:
	set(v):
		kind = v
		_apply_flats()
		queue_redraw()
## 亮背景纸面形态：奶油纸底 + 深墨描边贴图（主菜单浮在暖金天空上的次级按钮）。
## 白 16% 描边贴图在亮底不可见，深墨描边与血条黑墨同思路（§1.0 墨色规则）。
@export var ink_skin := false:
	set(v):
		ink_skin = v
		_apply_flats()
		queue_redraw()
## 半透明底（1.0=不透明）。<1 时四态走独立盒（绕开静态缓存，避免污染同槽位
## 其他按钮）并降低盒 modulate alpha——新盒经 SketchStyle._box 注册进帧轮换
## 仍保持沸腾；文字/描边语义不变，只有纸底透出背后场景。
@export_range(0.0, 1.0) var bg_alpha := 1.0:
	set(v):
		bg_alpha = v
		_apply_flats()
		queue_redraw()

var _seed: int = 0
var _timer: float = 0.0


var _last_dark: bool = false

func _ready() -> void:
	_apply_flats()
	resized.connect(queue_redraw)


## 四态贴图（kind/ink_skin 映射槽位；沸腾由 SketchTextures 帧驱动）
func _apply_flats() -> void:
	var base := "btn"
	if kind == Kind.PRIMARY:
		base = "btn_primary"  # 实底琥珀已含墨描边，优先于纸面形态
	elif ink_skin:
		base = "btn_ink"
	else:
		match kind:
			Kind.ACCENT: base = "accent"
			Kind.DANGER: base = "danger"
	for state in ["normal", "hover", "pressed", "disabled"]:
		var slot := StringName("%s_%s" % [base, state])
		if SketchTextures._frame_sets.is_empty():
			SketchTextures._load_all()
		if not SketchTextures._frame_sets.has(slot):
			slot = &"btn_normal"
		# 不透明走共享缓存；半透明每按钮独立盒（modulate 是盒级属性，
		# 共享缓存会把透明度串到所有同槽位按钮上）
		var sb := _box(slot) if bg_alpha >= 1.0 else SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
		if bg_alpha < 1.0:
			sb.modulate_color = Color(1, 1, 1, bg_alpha)
		add_theme_stylebox_override(state, sb)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_apply_font_colors(base)


## 字色随贴图亮度走：琥珀系亮底（primary 实底 / accent 的 hover/pressed 亮面）
## 配深墨，深底配白。kind 可运行时切换（设置分类选中态），所以每次 _apply_flats
## 重设：亮底槽位 override，其余清除还原主题——创建路径与切换路径都覆盖。
func _apply_font_colors(base: String) -> void:
	for col_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		var on_bright: bool = base == "btn_primary" \
				or (base == "accent" and col_name != "font_color")
		if on_bright:
			add_theme_color_override(col_name, StickTokens.ACCENT_TEXT)
		else:
			remove_theme_color_override(col_name)
	# 描边只服务「暗底白字」的时间戳高对比（主题层 3px 墨边）；亮底深墨字
	# 再加墨描边=笔画膨胀糊死（主菜单纸面按钮教训）——亮底档一律归零
	if base == "btn":
		remove_theme_constant_override("outline_size")
		remove_theme_color_override("font_outline_color")
	else:
		add_theme_constant_override("outline_size", 0)


static var _box_cache: Dictionary = {}


static func _box(slot: StringName) -> StyleBoxTexture:
	if not _box_cache.has(slot):
		_box_cache[slot] = SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
	return _box_cache[slot]
