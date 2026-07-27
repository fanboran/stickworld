extends Node
## 程序化建筑生成模块（building_gen）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 building_gen 内部脚本的方法。
##
## 材质配方子模块（thatch/stone_wall/stone_band/stone_window/wood）各自独立，
## 通过 Shader fragment 实时渲染，详见 docs/技术/教程/程序化材质系统.md。
##
## 使用示例：
## ```gdscript
## var tex = BuildingGenApi.make_wood_pillar(64, 128)
## var building = BuildingGenApi.create_smithy_lv1()
## add_child(building)
## ```


# ===== 公共信号 =====

## 材质参数变更（调试面板调整时触发）
signal material_param_changed(material_name: String, param_name: String, value: Variant)

## 建筑生成完成
signal building_generated(building_type: String, instance: Node)


# ===== 材质生成（委托 ProceduralMaterials）=====

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


# ===== 建筑实例化 =====

## 创建铁匠铺 Lv1 场景实例
## 返回 pg_smithy_lv1.tscn 的实例，内含程序化生成的纹理和碰撞
static func create_smithy_lv1() -> Node:
	var scene = preload("res://modules/building_gen/buildings/pg_smithy_lv1.tscn")
	return scene.instantiate()