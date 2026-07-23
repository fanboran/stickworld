extends Node
## 铁匠铺预览场景茅草屋顶适配器
##
## 关键发现：thatch.gdshader 内部的 blade 参数（row_spacing、blade_spacing、blade_length）
## 是基于 `resolution` 像素单位的硬编码值（如 spacing=32、length=110）。
## 铁匠铺屋顶在屏幕上只占 100 像素级别，会让 blade 长度 = 110% 屋顶高度 → 整张全黑。
##
## 修正方案：
## - 不重映射 UV，shader 直接使用 world-to-screen 坐标
## - `resolution` 传屋顶在世界坐标下的实际尺寸
## - 把 blade 参数改为**相对屋顶分辨率的比率**（除以 max(resolution.x, resolution.y)）

const SHADER_PATH := "res://modules/building_gen/materials/thatch/shaders/thatch.gdshader"
const WHITE_TEX_PATH := "res://modules/building_gen/assets/white_tex.png"

@export var roof_paths: Array[NodePath] = []

# 注意：这些单位是"屋顶像素"。spacing = 3.0 意味 3 屋顶像素/笔触间距。
# 实际渲染尺寸 = spacing / resolution.y * 屋顶实际高度
@export var row_spacing: float = 0.04    # 相对屋顶高度的笔触行间距 (4%)
@export var blade_spacing: float = 0.05  # 相对屋顶宽度的笔触列间距 (5%)
@export var blade_length_base: float = 0.5  # 相对屋顶高度的叶片长度
@export var blade_length_var: float = 0.08
@export var blade_width_base: float = 0.025
@export var blade_width_var: float = 0.005
@export var root_width_mul: float = 1.6
@export var tip_width_mul: float = 0.25
@export var width_noise: float = 0.45
@export var oil_roughness: float = 0.40

@export var margin_bottom: float = 0.15  # 相对屋顶高度
@export var edge_noise: float = 1.6

@export var angle_var: float = 0.08
@export var curve_amount: float = 0.18
@export var root_jitter: float = 0.02  # 相对屋顶宽度
@export var row_jitter: float = 0.02   # 相对屋顶高度
@export var seed_offset: int = 0

@export var base_color: Color = Color(0.35, 0.20, 0.08)

@export var blade_angle_deg: float = -30.0
@export var alternate_angle_per_roof: bool = true
@export var match_angle_to_slope: bool = true

@export var debug_mode: int = 0
@export var show_bounds: bool = false

var _shader: Shader
var _white_tex: Texture2D


func _ready() -> void:
	print("[SmithyThatchApplier] _ready called, editor_hint=", Engine.is_editor_hint())
	if Engine.is_editor_hint():
		return

	_shader = load(SHADER_PATH) as Shader
	_white_tex = load(WHITE_TEX_PATH) as Texture2D
	if _shader == null or _white_tex == null:
		push_error("[SmithyThatchApplier] 缺少 shader 或白色纹理")
		return

	print("[SmithyThatchApplier] shader loaded, code length=", _shader.code.length())

	for i in range(roof_paths.size()):
		var poly := get_node_or_null(roof_paths[i]) as Polygon2D
		if poly == null:
			continue
		_apply_thatch_to_polygon(poly, i)


func _apply_thatch_to_polygon(poly: Polygon2D, index: int) -> void:
	var pts := poly.polygon
	if pts.size() < 3:
		return

	# 1. 计算多边形本地坐标的轴对齐包围盒
	var min_pt := pts[0]
	var max_pt := pts[0]
	for p in pts:
		min_pt = min_pt.min(p)
		max_pt = max_pt.max(p)

	var size := max_pt - min_pt
	if size.x <= 0.0 or size.y <= 0.0:
		return

	# 2. 重要：传 screen-pixel 尺寸作为 resolution。
	#    Godot Polygon2D 在 Camera2D.zoom=1 时，1 世界单位 = 1 屏幕像素。
	#    父节点可能有 transform scale，需要乘上去得到真实屏幕像素。
	var xform := poly.get_global_transform()
	var scale: Vector2 = xform.get_scale()
	var res_x: float = size.x * absf(scale.x)
	var res_y: float = size.y * absf(scale.y)
	if res_x < 1.0:
		res_x = 1.0
	if res_y < 1.0:
		res_y = 1.0

	print("[SmithyThatchApplier] poly=", poly.name,
		" local size=", size, " global_scale=", scale,
		" screen_size=", Vector2(res_x, res_y),
		" pos=", poly.global_position)

	# 3. UV 重映射到 [0,1]
	var uvs := PackedVector2Array()
	uvs.resize(pts.size())
	for i in range(pts.size()):
		uvs[i] = (pts[i] - min_pt) / size

	# 4. 计算屋顶梯形边界
	var trap := _compute_trapezoid_bounds(pts, min_pt, max_pt, size)

	# 5. 叶片方向
	var effective_angle_deg: float = blade_angle_deg
	if alternate_angle_per_roof and (index % 2) == 0:
		effective_angle_deg = -effective_angle_deg
	if match_angle_to_slope:
		var top_center_x: float = (trap.bounds.x + trap.bounds.z) * 0.5
		var bottom_center_x: float = (trap.bounds_bottom.x + trap.bounds_bottom.y) * 0.5
		var slope_sign: int = sign(bottom_center_x - top_center_x)
		if slope_sign != 0:
			effective_angle_deg = absf(effective_angle_deg) * slope_sign
	var angle: float = deg_to_rad(effective_angle_deg)

	# 6. blade 参数：转换成世界单位
	#    eff_blade_length = size.y * 0.5 = 50% 屋顶高度
	#    eff_blade_width  = size.x * 0.025 = 2.5% 屋顶宽度
	var eff_row_spacing: float = row_spacing * res_y
	var eff_blade_spacing: float = blade_spacing * res_x
	var eff_blade_length: float = blade_length_base * res_y
	var eff_blade_width: float = maxf(blade_width_base * res_x, 1.0)
	var eff_margin_bottom: float = margin_bottom * res_y
	var eff_root_jitter: float = root_jitter * res_x
	var eff_row_jitter: float = row_jitter * res_y

	# 7. 行列数
	var cos_a: float = absf(cos(angle))
	if cos_a < 0.01:
		cos_a = 0.01
	var rows_count: int = maxi(1, int(res_y / (eff_row_spacing * cos_a)))
	var blades_count: int = maxi(1, int(res_x / (eff_blade_spacing * cos_a)))
	rows_count = mini(rows_count, 64)
	blades_count = mini(blades_count, 32)

	# 8. 创建材质
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("resolution", Vector2(res_x, res_y))
	mat.set_shader_parameter("bounds", trap.bounds)
	mat.set_shader_parameter("bounds_bottom", trap.bounds_bottom)
	mat.set_shader_parameter("blade_angle", angle)
	mat.set_shader_parameter("angle_var", angle_var)
	mat.set_shader_parameter("curve_amount", curve_amount)
	mat.set_shader_parameter("rows", rows_count)
	mat.set_shader_parameter("blades_per_row", blades_count)
	mat.set_shader_parameter("row_spacing", eff_row_spacing)
	mat.set_shader_parameter("blade_spacing", eff_blade_spacing)
	mat.set_shader_parameter("blade_length_base", eff_blade_length)
	mat.set_shader_parameter("blade_length_var", eff_blade_length * 0.2)
	mat.set_shader_parameter("blade_width_base", eff_blade_width)
	mat.set_shader_parameter("blade_width_var", eff_blade_width * 0.3)
	mat.set_shader_parameter("root_width_mul", root_width_mul)
	mat.set_shader_parameter("tip_width_mul", tip_width_mul)
	mat.set_shader_parameter("width_noise", width_noise)
	mat.set_shader_parameter("oil_roughness", oil_roughness)
	mat.set_shader_parameter("margin_bottom", eff_margin_bottom)
	mat.set_shader_parameter("edge_noise", edge_noise)
	mat.set_shader_parameter("root_jitter", eff_root_jitter)
	mat.set_shader_parameter("row_jitter", eff_row_jitter)
	mat.set_shader_parameter("seed", seed_offset + index * 7)
	mat.set_shader_parameter("base_color", Vector3(base_color.r, base_color.g, base_color.b))
	mat.set_shader_parameter("show_bounds", show_bounds)
	mat.set_shader_parameter("debug_mode", debug_mode)

	poly.material = mat
	poly.texture = _white_tex
	poly.uv = uvs
	print("[SmithyThatchApplier] applied to ", poly.name,
		" rows=", rows_count, " blades=", blades_count,
		" row_spacing=", eff_row_spacing, " blade_length=", eff_blade_length,
		" blade_width=", eff_blade_width, " angle=", effective_angle_deg)


func _compute_trapezoid_bounds(pts: PackedVector2Array, min_pt: Vector2, max_pt: Vector2, size: Vector2) -> Dictionary:
	var min_y: float = min_pt.y
	var max_y: float = max_pt.y
	var xs_top: Array[float] = []
	var xs_bottom: Array[float] = []
	var n: int = pts.size()

	for i in range(n):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]

		if absf(a.y - b.y) < 0.001:
			if absf(a.y - min_y) < 0.001:
				xs_top.append(a.x)
				xs_top.append(b.x)
			if absf(a.y - max_y) < 0.001:
				xs_bottom.append(a.x)
				xs_bottom.append(b.x)
			continue

		if (a.y <= min_y and b.y >= min_y) or (a.y >= min_y and b.y <= min_y):
			if absf(a.y - min_y) > 0.001 and absf(b.y - min_y) > 0.001:
				var t: float = (min_y - a.y) / (b.y - a.y)
				xs_top.append(lerpf(a.x, b.x, t))
		if (a.y <= max_y and b.y >= max_y) or (a.y >= max_y and b.y <= max_y):
			if absf(a.y - max_y) > 0.001 and absf(b.y - max_y) > 0.001:
				var t: float = (max_y - a.y) / (b.y - a.y)
				xs_bottom.append(lerpf(a.x, b.x, t))

	for p in pts:
		if absf(p.y - min_y) < 0.001:
			xs_top.append(p.x)
		if absf(p.y - max_y) < 0.001:
			xs_bottom.append(p.x)

	var x_min_top: float = min_pt.x
	var x_max_top: float = max_pt.x
	var x_min_bottom: float = min_pt.x
	var x_max_bottom: float = max_pt.x

	if xs_top.size() >= 2:
		xs_top.sort()
		x_min_top = xs_top[0]
		x_max_top = xs_top[xs_top.size() - 1]
	if xs_bottom.size() >= 2:
		xs_bottom.sort()
		x_min_bottom = xs_bottom[0]
		x_max_bottom = xs_bottom[xs_bottom.size() - 1]

	return {
		"bounds": Vector4(x_min_top - min_pt.x, 0.0, x_max_top - min_pt.x, size.y),
		"bounds_bottom": Vector2(x_min_bottom - min_pt.x, x_max_bottom - min_pt.x)
	}
