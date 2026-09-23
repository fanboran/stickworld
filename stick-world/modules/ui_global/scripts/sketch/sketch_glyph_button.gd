class_name SketchGlyphButton
extends SketchGearButton
## 手绘方形图形钮 —— ICON_SQUARE 变体的"自绘图形"档。
##
## 与 SketchGearButton 的分工：那个方钮的图标来自场景 icon 属性（图标管线成品），
## 这个的图标由 SketchDraw 矢量自绘（Glyph）。用在贴图管线没有母题、字体也没有
## 对应符号的地方——音乐播放器的走带键（播放/暂停/上一曲/下一曲/循环）与音符角标：
## StickHand 字体实测不含 ▶ ⏸ ⏮ ⏭ ♪（has_char 全 false），只能画。
##
## 方底与沸腾描边继承 SketchGearButton（贴图态、状态色一致），本类只叠图形。
## 用法：`var b := SketchGlyphButton.new(); b.glyph = SketchDraw.Glyph.NOTE`

## 图形（SketchDraw.Glyph）
var glyph: int = SketchDraw.Glyph.NOTE:
	set(v):
		glyph = v
		queue_redraw()

## 方钮边长（px）：默认对齐菜单大按钮行高，方钮与同行文字钮等高
var square_size: float = StickTokens.BTN_H_LG:
	set(v):
		square_size = v
		custom_minimum_size = Vector2(v, v)

## 激活态（如「循环」开关打开）：常态图形转琥珀，一眼看出开关状态
var active := false:
	set(v):
		active = v
		queue_redraw()

## 图形外接半径 = 短边 × 该系数（留出方底边距，图形不顶到沸腾描边）
const GLYPH_RATIO := 0.25


func _ready() -> void:
	super._ready()  # ICON_SQUARE 变体 + 初始 30×30 + 沸腾重掷（父类契约）
	custom_minimum_size = Vector2(square_size, square_size)


func _draw() -> void:
	super._draw()   # 方底 + 沸腾方框描边（状态色见 SketchGearButton._draw）
	SketchDraw.draw_glyph(self, glyph, size * 0.5,
			minf(size.x, size.y) * GLYPH_RATIO, _seed, _glyph_color())


## 图形状态色（方底的态色在父类 _draw 里画，这里只管图形本身）。
## ink_skin（亮背景纸面形态）时图形也走深墨——与同排纸面按钮的文字同色；
## 白图形铺在亮天空上会糊掉（主菜单原声带方钮实测反差不足）。
func _glyph_color() -> Color:
	var ink := StickTokens.ACCENT_TEXT
	var hot := Color(1.0, 1.0, 1.0, 0.95)
	match get_draw_mode():
		BaseButton.DRAW_DISABLED:
			return Color(ink, 0.45) if ink_skin else Color(1.0, 1.0, 1.0, 0.25)
		BaseButton.DRAW_PRESSED:
			return StickTokens.ACCENT
		BaseButton.DRAW_HOVER:
			if active:
				return StickTokens.ACCENT.lightened(0.25)
			return ink if ink_skin else hot
		_:
			if active:
				return StickTokens.ACCENT
			return ink if ink_skin else Color(1.0, 1.0, 1.0, 0.88)
