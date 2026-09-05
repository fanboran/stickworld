class_name AmbientMotes
extends Node2D
## 环境浮尘 —— 空气中的微光尘粒（慢速漂浮 + 呼吸明暗），给世界"空气感"。
##
## 挂地图（z 介于世界与 UI 间）；粒子在相机视野范围内生成/回绕，
## 每帧自绘（60 粒 O(n) 绘制开销可忽略）。Godot 4 _draw 每帧重绘由 queue_redraw 驱动。

const COUNT: int = 56
const AREA_HALF: Vector2 = Vector2(1400.0, 500.0)
## 重绘节流：尘粒漂移缓慢，30Hz 与逐帧视觉无差（对齐 fireflies 的节流做法）
const REDRAW_HZ: float = 30.0
## 相机引用（粒子分布在相机中心周围）
var _cam: Camera2D = null
var _seeds: Array = []
var _t: float = 0.0
var _redraw_acc: float = 99.0  # 首帧必重绘


func _ready() -> void:
	z_index = 40  # 世界之上、UI 之下
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260905
	for i in COUNT:
		_seeds.append({
			"ox": rng.randf_range(-AREA_HALF.x, AREA_HALF.x),
			"oy": rng.randf_range(-AREA_HALF.y, AREA_HALF.y),
			"phase": rng.randf() * TAU,
			"speed": rng.randf_range(0.25, 0.7),
			"size": rng.randf_range(1.2, 2.6),
			"drift": rng.randf_range(4.0, 14.0),
		})
	call_deferred("_find_camera")


func _find_camera() -> void:
	_cam = get_viewport().get_camera_2d()


func _process(delta: float) -> void:
	_t += delta
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


func _draw() -> void:
	if _cam == null:
		return
	var center: Vector2 = _cam.get_screen_center_position()
	for sd in _seeds:
		var p := Vector2(
			center.x + sd["ox"] + sin(_t * sd["speed"] + sd["phase"]) * sd["drift"],
			center.y + sd["oy"] + cos(_t * sd["speed"] * 0.8 + sd["phase"] * 1.7) * sd["drift"] * 0.6)
		var tw: float = 0.35 + 0.3 * sin(_t * 1.4 + sd["phase"] * 2.3)
		var c := Color(1.0, 0.96, 0.86, 0.16 * tw)
		draw_circle(p, sd["size"], c)
