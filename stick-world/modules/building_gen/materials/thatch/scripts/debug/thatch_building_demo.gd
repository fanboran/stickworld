extends Node2D
## 茅草建筑演示场景
##
## 动态创建左、右两片屋顶，使用同一份 thatch shader，仅通过 uniform 区分角度和种子。
## 用于验证：建筑长度可变、左右屋顶对称、材质与几何耦合。

const SHADER_PATH := "res://modules/building_gen/materials/thatch/shaders/thatch.gdshader"
const WHITE_TEX_PATH := "res://modules/building_gen/assets/white_tex.png"

# 屋顶几何参数（像素单位）
const ROOF_RES := Vector2(920.0, 300.0)
# bounds: x_min_top, y_min, x_max_top, y_max
const ROOF_BOUNDS := Vector4(0.0, 0.0, 920.0, 300.0)
# 左屋顶底部左侧内收，右侧屋脊线保持垂直
const ROOF_BOUNDS_BOTTOM_LEFT := Vector2(170.0, 920.0)
# 右屋顶底部右侧内收，左侧屋脊线保持垂直
const ROOF_BOUNDS_BOTTOM_RIGHT := Vector2(0.0, 750.0)


func _ready() -> void:
	var shader := load(SHADER_PATH) as Shader
	var tex := load(WHITE_TEX_PATH) as Texture2D
	if shader == null or tex == null:
		push_error("[ThatchBuildingDemo] 缺少 shader 或 texture")
		return

	# 左屋顶：-60°，屋脊线在右侧；右屋顶：+60°，屋脊线在左侧。
	# 两片屋顶的屋脊线在 x=0 处相接。
	_add_roof(shader, tex, "RoofLeft", -1.047, Vector2(-115.0, 0.0), ROOF_BOUNDS_BOTTOM_LEFT, 0)
	_add_roof(shader, tex, "RoofRight", 1.047, Vector2(115.0, 0.0), ROOF_BOUNDS_BOTTOM_RIGHT, 7)

	var cam := Camera2D.new()
	cam.name = "Camera2D"
	cam.enabled = true
	cam.zoom = Vector2(1.3, 1.3)
	cam.position = Vector2(0.0, 80.0)
	add_child(cam)


func _add_roof(shader: Shader, tex: Texture2D, name: String, angle: float, pos: Vector2, bounds_bottom: Vector2, seed: int) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("resolution", ROOF_RES)
	mat.set_shader_parameter("bounds", ROOF_BOUNDS)
	mat.set_shader_parameter("bounds_bottom", bounds_bottom)
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
