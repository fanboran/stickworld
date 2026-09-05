class_name Pond
extends Node2D
## 水面 —— Kingdom Two Crowns 布局（镜像倒影 + 水线白沫，pond_reflection.gdshader）。
##
## 挂 village_map 可行走区域**正下方**横贯全图（K2C 语义：单位站堤岸、水在
## 脚下），z=DECORATION（地面之上、建筑与单位之前——地面多边形 z=0 不透明
## 会盖住更低的层）。倒影映绘制序在水之前的天景（星月/极光/云/远山/建筑），
## 岸沫为沿水线滚动的白色条带（K2C 调研结论）。
## 水面线屏幕 uv 每帧由本脚本写入 shader（相机移动/变焦自动跟随）；
## 昼夜压暗与 SkyStars/PostProcessLayer 同式。

const PondShader: Shader = preload("res://modules/environment/shaders/pond_reflection.gdshader")

## 水面几何（由 village_map 挂载时按地图参数设置）
var pond_width: float = 1500.0
var pond_depth: float = 110.0

var _mat: ShaderMaterial = null
var _quad: Polygon2D = null
var _env: Node = null
var _time: float = 0.0
var _night: float = 0.0


func _ready() -> void:
	z_index = WorldZ.DECORATION
	# 四边形水面（水面线 = 本节点原点，向下 pond_depth）
	_quad = Polygon2D.new()
	_quad.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(pond_width, 0),
		Vector2(pond_width, pond_depth), Vector2(0, pond_depth),
	])
	_mat = ShaderMaterial.new()
	_mat.shader = PondShader
	_mat.set_shader_parameter("line_uv_y", 0.7)
	_mat.set_shader_parameter("width_px", pond_width)
	_quad.material = _mat
	add_child(_quad)


func _process(delta: float) -> void:
	_time += delta
	_night = lerpf(_night, 1.0 - _day_factor(), clampf(delta * 2.0, 0.0, 1.0))
	_mat.set_shader_parameter("time_seed", _time)
	_mat.set_shader_parameter("night_mix", _night)
	# 水面线 → 屏幕 uv（相机移动/变焦跟随）
	var vp := get_viewport()
	var screen_pos: Vector2 = vp.get_canvas_transform() * global_position
	var vp_size: Vector2 = vp.get_visible_rect().size
	if vp_size.y > 0.0:
		_mat.set_shader_parameter("line_uv_y", screen_pos.y / vp_size.y)


## 昼夜因子（与 SkyStars 同式：生产路径 → 祖先链兜底）
func _day_factor() -> float:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return 1.0
	if not _env.has_method("get_current_light_color"):
		return 1.0
	var lum: float = _env.get_current_light_color().get_luminance()
	return clampf((lum - 0.55) / 0.35, 0.0, 1.0)


func _find_env() -> Node:
	var env := get_tree().root.get_node_or_null("GameRoot/EnvironmentSystem")
	if env != null:
		return env
	var a := get_parent()
	while a != null:
		var e := a.get_node_or_null("EnvironmentSystem")
		if e != null:
			return e
		a = a.get_parent()
	return null
