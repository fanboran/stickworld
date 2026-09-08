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
		add_theme_stylebox_override(state, _box(slot))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static var _box_cache: Dictionary = {}


static func _box(slot: StringName) -> StyleBoxTexture:
	if not _box_cache.has(slot):
		_box_cache[slot] = SketchStyle._box(slot, StickTokens.PAD_X + 2, 2)
	return _box_cache[slot]
