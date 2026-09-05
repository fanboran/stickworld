class_name SketchPanel
extends PanelContainer
## 手绘涂鸦面板 —— 血条同源 boiling 自绘底（实心扰动多边形 + 粗描边）。
##
## 替代「PanelContainer + StickStyle.window_panel() override」组合：
## 面板底与描边由 _draw() 直接画在控件边缘（标准圆角矩形 + 小幅扰动），
## Theme stylebox 置空，content_margin 独立保留——边框不吃内容区。

enum Tone { DARK, LIGHT }

## 深浅底预设：DARK = 大弹窗主底；LIGHT = HUD 横条/内嵌区块
@export var tone: Tone = Tone.DARK:
	set(v):
		tone = v
		queue_redraw()
## 自定义底色（非透明时覆盖 tone 预设）
@export var fill_override := Color.TRANSPARENT
## 自定义描边（非透明时覆盖 tone 预设）
@export var outline_override := Color.TRANSPARENT
## 圆角半径（自动钳到不塌陷）
@export var corner_radius: float = SketchDraw.CORNER_R
## 紧凑内边距（小对话框：内容有多少占多少，不摆大面板的架子）
@export var compact := false:
	set(v):
		compact = v
		_apply_padding()

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	_apply_padding()
	resized.connect(queue_redraw)


## 内边距档位：紧凑 12/7（对话框）；常规 DARK 24/12（大弹窗）、LIGHT 16/9（HUD 条）
func _apply_padding() -> void:
	var sb := StyleBoxEmpty.new()
	if compact:
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 7
		sb.content_margin_bottom = 7
	elif tone == Tone.DARK:
		sb.content_margin_left = StickTokens.PAD_X * 2
		sb.content_margin_right = StickTokens.PAD_X * 2
		sb.content_margin_top = StickTokens.PAD_Y * 2
		sb.content_margin_bottom = StickTokens.PAD_Y * 2
	else:
		sb.content_margin_left = StickTokens.PAD_X + 4
		sb.content_margin_right = StickTokens.PAD_X + 4
		sb.content_margin_top = StickTokens.PAD_Y + 3
		sb.content_margin_bottom = StickTokens.PAD_Y + 3
	add_theme_stylebox_override("panel", sb)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	# boiling：与血条同节拍重掷相位
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	var fill := fill_override
	var outline := outline_override
	if fill == Color.TRANSPARENT:
		fill = StickTokens.WINDOW_BG if tone == Tone.DARK else StickTokens.WINDOW_BG_LIGHT
	if outline == Color.TRANSPARENT:
		outline = StickTokens.BORDER
	SketchDraw.draw_panel(self, Rect2(Vector2.ZERO, size), _seed, fill, outline,
			SketchDraw.OUTLINE_WIDTH, corner_radius)
