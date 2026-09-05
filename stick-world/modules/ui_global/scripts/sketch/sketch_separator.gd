class_name SketchSeparator
extends Control
## 手绘涂鸦分隔线 —— 水平/竖直波浪线（boiling 自绘），替代 HSeparator/VSeparator。

enum Dir { HORIZONTAL, VERTICAL }

@export var direction: Dir = Dir.HORIZONTAL:
	set(v):
		direction = v
		queue_redraw()

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	if direction == Dir.HORIZONTAL:
		custom_minimum_size = Vector2(0, maxf(custom_minimum_size.y, 8.0))
	else:
		custom_minimum_size = Vector2(maxf(custom_minimum_size.x, 8.0), 0)
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	var color := Color(StickTokens.BORDER.r, StickTokens.BORDER.g,
			StickTokens.BORDER.b, 0.35)
	if direction == Dir.HORIZONTAL:
		SketchDraw.draw_wavy_line(self, Vector2(2.0, size.y * 0.5),
				Vector2(size.x - 2.0, size.y * 0.5), _seed, color)
	else:
		SketchDraw.draw_wavy_line(self, Vector2(size.x * 0.5, 2.0),
				Vector2(size.x * 0.5, size.y - 2.0), _seed, color)
