class_name SketchSeparator
extends Control
## 手绘涂鸦分隔线 —— 水平/竖直波浪线（boiling 自绘），替代 HSeparator/VSeparator。

enum Dir { HORIZONTAL, VERTICAL }

@export var direction: Dir = Dir.HORIZONTAL:
	set(v):
		direction = v
		queue_redraw()

var _boil := SketchBoil.new()   # boiling 相位（种子+节拍公共件，_draw 读 _boil.phase）


func _ready() -> void:
	_boil.reset()
	if direction == Dir.HORIZONTAL:
		custom_minimum_size = Vector2(0, maxf(custom_minimum_size.y, 8.0))
	else:
		custom_minimum_size = Vector2(maxf(custom_minimum_size.x, 8.0), 0)
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	if is_visible_in_tree() and _boil.tick(delta):
		queue_redraw()


func _draw() -> void:
	var color := Color(StickTokens.BORDER.r, StickTokens.BORDER.g,
			StickTokens.BORDER.b, 0.35)
	if direction == Dir.HORIZONTAL:
		SketchDraw.draw_wavy_line(self, Vector2(2.0, size.y * 0.5),
				Vector2(size.x - 2.0, size.y * 0.5), _boil.phase, color)
	else:
		SketchDraw.draw_wavy_line(self, Vector2(size.x * 0.5, 2.0),
				Vector2(size.x * 0.5, size.y - 2.0), _boil.phase, color)
