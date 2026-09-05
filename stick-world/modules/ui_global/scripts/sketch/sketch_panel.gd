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
@export var compact := false

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	# 贴图皮肤：九宫格沸腾贴图（SketchTextures 全局帧驱动轮换）
	var slot := &"panel_light" if tone == Tone.LIGHT else &"panel"
	var pad_x := 12 if compact else (PANEL_PAD_X if tone == Tone.DARK else PAD_LIGHT_X)
	var pad_y := 7 if compact else (PANEL_PAD_Y if tone == Tone.DARK else PAD_LIGHT_Y)
	add_theme_stylebox_override("panel", _box(slot, pad_x, pad_y))


static var _box_cache: Dictionary = {}


static func _box(slot: StringName, pad_x: int, pad_y: int) -> StyleBoxTexture:
	var key := "%s|%d|%d" % [slot, pad_x, pad_y]
	if not _box_cache.has(key):
		_box_cache[key] = SketchStyle._box(slot, pad_x, pad_y)
	return _box_cache[key]


const PANEL_PAD_X := 16
const PANEL_PAD_Y := 12
const PAD_LIGHT_X := 16
const PAD_LIGHT_Y := 9
