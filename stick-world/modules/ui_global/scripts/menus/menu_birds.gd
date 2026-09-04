class_name MenuBirds
extends Node2D
## 主菜单远空飞鸟 —— 与游戏内 world/sky_birds.gd 同视觉语言的菜单本地变体。
##
## 刻意不复用 world 模块脚本（ui_global 被 world 依赖，反向引用会成环）；
## 菜单无相机/昼夜环境，窗口中心直接取视口一半，恒为白昼强度。

const FLOCK_INTERVAL_MIN: float = 6.0
const FLOCK_INTERVAL_MAX: float = 14.0
const REDRAW_HZ: float = 15.0
const MARGIN: float = 200.0

## 当前鸟群 {dir, speed, y, x, birds:[{dx, dy, phase, flap, scale}]}；空=无鸟
var _flock: Dictionary = {}
var _next_flock: float = 3.0
var _time: float = 0.0
var _redraw_acc: float = 0.0


func _process(delta: float) -> void:
	_time += delta
	var half: float = get_viewport_rect().size.x * 0.5
	if _flock.is_empty():
		_next_flock -= delta
		if _next_flock <= 0.0:
			var d: float = 1.0 if randf() < 0.5 else -1.0
			_flock = _make_flock(d, -d * (half + MARGIN))
	else:
		_flock["x"] += _flock["speed"] * _flock["dir"] * delta
		for b in _flock["birds"]:
			b["phase"] += b["flap"] * delta
		var edge: float = half + MARGIN
		if (_flock["dir"] > 0.0 and _flock["x"] > edge) \
				or (_flock["dir"] < 0.0 and _flock["x"] < -edge):
			_flock = {}
			_next_flock = randf_range(FLOCK_INTERVAL_MIN, FLOCK_INTERVAL_MAX)
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


## 构造一群鸟：dir 方向斜纵队（前鸟高后鸟低）3-5 只
func _make_flock(dir: float, start_x: float) -> Dictionary:
	var count: int = randi_range(3, 5)
	var birds: Array = []
	for i in count:
		birds.append({
			"dx": -dir * float(i) * randf_range(24.0, 40.0),
			"dy": float(i) * randf_range(-4.0, 10.0) + randf_range(-8.0, 8.0),
			"phase": randf() * TAU,
			"flap": randf_range(7.0, 10.0),
			"scale": randf_range(0.8, 1.15),
		})
	return {
		"dir": dir,
		"speed": randf_range(60.0, 85.0),
		"y": randf_range(110.0, 330.0),
		"x": start_x,
		"birds": birds,
	}


## 立即生成一群鸟（快照脚本确定性触发）；in_view=true 从画面内侧边缘起飞
func spawn_now(in_view: bool = false) -> void:
	var half: float = get_viewport_rect().size.x * 0.5
	var d: float = 1.0 if randf() < 0.5 else -1.0
	var edge: float = half - 150.0 if in_view else half + MARGIN
	_flock = _make_flock(d, -d * edge)


func _draw() -> void:
	if _flock.is_empty():
		return
	var col := Color(0.22, 0.20, 0.24, 0.8)
	for b in _flock["birds"]:
		var s: float = b["scale"]
		var p := Vector2(_flock["x"] + b["dx"], _flock["y"] + b["dy"] + sin(_time * 1.7 + b["phase"]) * 3.0)
		var flap: float = sin(b["phase"])
		var wing := Vector2(8.0 * s, flap * 5.0 * s)
		draw_line(p, p + wing, col, 2.2 * s)
		draw_line(p, p + Vector2(-wing.x, wing.y), col, 2.2 * s)
		draw_circle(p, 1.5 * s, col)
