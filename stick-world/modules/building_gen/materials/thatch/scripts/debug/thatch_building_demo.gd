extends Node2D
## 茅草建筑演示场景
##
## 动态创建左、右两片屋顶，使用同一份 thatch shader，仅通过 uniform 区分角度和种子。
## 用于验证：建筑长度可变、左右屋顶对称、材质与几何耦合。

const SHADER_PATH := "res://modules/building_gen/materials/thatch/shaders/thatch.gdshader"
const WHITE_TEX_PATH := "res://modules/building_gen/assets/white_tex.png"

# 屋顶几何参数（像素单位）
const ROOF_RES := Vector2(920.0, 300.0)
const ROOF_BOUNDS := Vector4(300.0, 0.0, 700.0, 300.0)


func _ready() -> void:
	var shader := load(SHADER_PATH) as Shader
	var tex := load(WHITE_TEX_PATH) as Texture2D
	if shader == null or tex == null:
		push_error("[ThatchBuildingDemo] 缺少 shader 或 texture")
		return

	# 左屋顶：-60°，位置让右边缘与右屋顶左边缘在 x=40 相接
	_add_roof(shader, tex, "RoofLeft", -1.047, Vector2(-200.0, 0.0), 0)
	# 右屋顶：+60°
	_add_roof(shader, tex, "RoofRight", 1.047, Vector2(200.0, 0.0), 7)

	var cam := Camera2D.new()
	cam.name = "Camera2D"
	cam.enabled = true
	cam.zoom = Vector2(1.3, 1.3)
	cam.position = Vector2(40.0, 80.0)
	add_child(cam)


func _add_roof(shader: Shader, tex: Texture2D, name: String, angle: float, pos: Vector2, seed: int) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("resolution", ROOF_RES)
	mat.set_shader_parameter("bounds", ROOF_BOUNDS)
	mat.set_shader_parameter("blade_angle", angle)
	mat.set_shader_parameter("seed", seed)

	var sprite := Sprite2D.new()
	sprite.name = name
	sprite.texture = tex
	sprite.material = mat
	# white_tex.png 是 4x4，scale 用 resolution / 4
	sprite.scale = Vector2(ROOF_RES.x / 4.0, ROOF_RES.y / 4.0)
	sprite.position = pos
	add_child(sprite)
