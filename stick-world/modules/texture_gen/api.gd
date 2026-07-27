extends Node
## 纹理生成模块（texture_gen）公共接口契约
##
## 提供程序化 CPU 贴图 + GPU Shader 材质。
## 外部模块只能通过本文件定义的方法与本模块交互，禁止跨模块引用内部脚本。
##
## 使用示例：
## ```gdscript
## # CPU 程序化贴图
## var tex = TextureGenApi.make_wood_pillar(64, 128)
## var mat = TextureGenApi.create_thatch_material(tex)
##
## # GPU Shader 材质
## var shader_mat = TextureGenApi.load_shader_material("stone_wall")
## some_sprite.material = shader_mat
## shader_mat.set_shader_parameter("seed", 42)
## ```

# ===== 公共信号（转发到 EventBus）=====

## 材质参数变更（调试面板调整时触发）
signal material_param_changed(material_name: String, param_name: String, value: Variant)

## 材质截图完成
signal texture_captured(material_name: String, output_path: String)


# ===== 材质查询 =====

## 列出所有已注册的材质 ID
static func list_materials() -> Array[StringName]:
	return [&"thatch", &"stone_wall", &"stone_band", &"stone_window"]

## 检查材质 ID 是否已注册
static func has_material(material_id: StringName) -> bool:
	return list_materials().has(material_id)


# ===== CPU 程序化贴图（委托 ProceduralMaterials）=====

## 生成竖纹木柱贴图（w × h）
static func make_wood_pillar(w: int, h: int, base_color: Color = Color(0.45, 0.30, 0.15)) -> ImageTexture:
	return ProceduralMaterials.make_wood_pillar(w, h, base_color)

## 生成横纹木板贴图（w × h，用于内部物体）
static func make_wood_plank(w: int, h: int, base_color: Color = Color(0.50, 0.33, 0.18)) -> ImageTexture:
	return ProceduralMaterials.make_wood_plank(w, h, base_color)

## 生成稻草顶棚贴图（w × h，纤维质感）
static func make_straw_thatch(w: int, h: int, base_color: Color = Color(0.72, 0.60, 0.30)) -> ImageTexture:
	return ProceduralMaterials.make_straw_thatch(w, h, base_color)

## 生成层叠茅草屋顶贴图（横向 tileable）
static func make_thatch_layered(w: int, h: int, seed: int = 0) -> ImageTexture:
	return ProceduralMaterials.make_thatch_layered(w, h, seed)

## 为多边形生成指定尺寸的茅草贴图（带 seed 控制随机性）
static func make_thatch_for_polygon(w: int, h: int, seed: int = 0) -> ImageTexture:
	return ProceduralMaterials.make_thatch_for_polygon(w, h, seed)

## 用纹理创建茅草 ShaderMaterial
static func create_thatch_material(tex: ImageTexture) -> ShaderMaterial:
	return ProceduralMaterials.create_thatch_material(tex)

## 生成深色石质贴图（高炉用）
static func make_stone_dark(w: int, h: int, base_color: Color = Color(0.25, 0.22, 0.20)) -> ImageTexture:
	return ProceduralMaterials.make_stone_dark(w, h, base_color)

## 生成铁色贴图（铁砧用）
static func make_metal_iron(w: int, h: int) -> ImageTexture:
	return ProceduralMaterials.make_metal_iron(w, h)

## 生成纯色矩形贴图
static func make_solid(w: int, h: int, color: Color) -> ImageTexture:
	return ProceduralMaterials.make_solid(w, h, color)


# ===== GPU Shader 材质 =====

## 加载指定材质的 ShaderMaterial
## [P] material_id 已注册（见 list_materials）
## [Q] 返回 ShaderMaterial（未设置 uniform，调用方按需配置）
static func load_shader_material(material_id: StringName) -> ShaderMaterial:
	var shader_path := "res://modules/texture_gen/materials/%s/shaders/%s.gdshader" % [material_id, material_id]
	var shader: Shader = load(shader_path)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

## 应用指定材质到目标 CanvasItem
## [P] target is CanvasItem, material_id 已注册
## [Q] target.material 被替换，返回新 ShaderMaterial 供调用方设置 uniform
static func apply_material(target: CanvasItem, material_id: StringName) -> ShaderMaterial:
	var mat := load_shader_material(material_id)
	target.material = mat
	return mat

## 茅草专用：CPU 笔迹应用到 Polygon2D（@tool 场景用）
## 因为 thatch.gdshader 还在占位阶段，运行时由 Shader 替代
## [P] polygon is Polygon2D 且 polygon.polygon.size() >= 3
static func apply_thatch_cpu(polygon: Polygon2D) -> void:
	var applier_script := preload("res://modules/texture_gen/materials/thatch/scripts/thatch_applier.gd")
	var applier := applier_script.new()
	applier.roof_paths = [polygon.get_path()]
	polygon.get_parent().add_child(applier)