class_name SketchButton
extends Button
## 手绘涂鸦按钮 —— 底色走 Flat stylebox（引擎画、文字之下），
## boiling 手绘描边由 _draw() 叠加（血条同源算法，边缘区不碰文字）。
##
## 层级原理：native NOTIFICATION_DRAW 先画 stylebox 底 + 文字，
## 脚本 _draw() 后执行——只画边缘描边线（1.6px）就不会盖文字。
## hover 微缩放/音效/信号行为全部继承（与 StickKit.button 交互一致）。

enum Kind { NORMAL, ACCENT, DANGER }

@export var kind: Kind = Kind.NORMAL:
	set(v):
		kind = v
		_apply_flats()
		queue_redraw()
## 深墨描边（亮背景用，血条黑墨同思路）：非透明时覆盖常规白描边。
## 主菜单浮在暖金天空上的按钮用它，描边才醒目。
@export var ink := Color.TRANSPARENT

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_apply_flats()
	_apply_text_colors()
	resized.connect(queue_redraw)
	mouse_entered.connect(_apply_text_colors)
	mouse_exited.connect(_apply_text_colors)


## hover 反黑只对 NORMAL（底变白 10% 后白字失对比）；ACCENT/DANGER 字色恒定
func _apply_text_colors() -> void:
	var hovering := is_hovered()
	var dark := ink.a > 0.0 or (kind == Kind.NORMAL and hovering)
	var c := Color(0.05, 0.04, 0.03) if dark else StickTokens.TEXT
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		add_theme_color_override(state, c)


## 四态贴图（kind 映射槽位；沸腾由 SketchTextures 帧驱动）
func _apply_flats() -> void:
	var base := "btn"
	match kind:
		Kind.ACCENT: base = "accent"
		Kind.DANGER: base = "danger"
	for state in ["normal", "hover", "pressed", "disabled"]:
		var slot := StringName("%s_%s" % [base, state])
		if SketchTextures._frame_sets.is_empty():
			SketchTextures._load_all()
		if not SketchTextures._frame_sets.has(slot):
			slot = &"btn_normal"
		add_theme_stylebox_override(state, _box(slot))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static var _box_cache: Dictionary = {}


static func _box(slot: StringName) -> StyleBoxTexture:
	if not _box_cache.has(slot):
		_box_cache[slot] = SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
	return _box_cache[slot]
