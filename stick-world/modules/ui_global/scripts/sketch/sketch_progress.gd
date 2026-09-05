class_name SketchProgress
extends ProgressBar
## 手绘涂鸦进度条 —— 轨道 + 填充均 _draw 自绘（boiling 圆角条），文字由引擎画。


var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	add_theme_stylebox_override("background", StyleBoxEmpty.new())
	add_theme_stylebox_override("fill", StyleBoxEmpty.new())
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
	var ratio: float = 1.0
	if max_value > min_value:
		ratio = clampf((value - min_value) / (max_value - min_value), 0.0, 1.0)
	SketchDraw.draw_progress(self, Rect2(Vector2.ZERO, size), ratio, _seed,
			StickTokens.ACCENT, StickTokens.GROOVE_BG)
