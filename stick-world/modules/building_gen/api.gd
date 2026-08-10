extends Node
## 程序化建筑生成模块（building_gen）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 building_gen 内部脚本的方法。
##
## 材质纹理生成已迁移至 modules/texture_gen/，详见 TextureGenApi。

# ===== 公共信号 =====

## 建筑生成完成
@warning_ignore("unused_signal")
signal building_generated(building_type: String, instance: Node)


# ===== 建筑场景模板注册表 =====

## building_gen 自有的建筑场景模板（def_id → 相对本模块的 .tscn 路径）。
## 命名约定：文件名 = def_id = 存档字段三者一致（详见 buildings/README.md），
## 故直接以 def_id 为键，零映射成本。
const _BUILDING_SCENE_PATHS := {
	"bld_placeholder": "buildings/bld_placeholder.tscn",
	"bld_wall_tier1": "buildings/bld_wall_tier1.tscn",
	"bld_wall_tier2": "buildings/bld_wall_tier2.tscn",
	"bld_wall_tier3": "buildings/bld_wall_tier3.tscn",
	"bld_wall_gate": "buildings/bld_wall_gate.tscn",
	"bld_barracks": "buildings/bld_barracks.tscn",
	"bld_warehouse": "buildings/bld_warehouse.tscn",
}


## 加载本模块提供的建筑场景模板（def_id → PackedScene）。
## 场景模板归属本模块，路径映射只在模块内部维护，外部模块不得硬编码内部路径。
static func load_building_scene(def_id: String) -> PackedScene:
	if not _BUILDING_SCENE_PATHS.has(def_id):
		return null
	return load("res://modules/building_gen/" + _BUILDING_SCENE_PATHS[def_id]) as PackedScene


## 返回本模块提供的默认建筑 def_id 列表（可供构造系统注册为可建造建筑）。
static func get_default_building_def_ids() -> Array:
	return _BUILDING_SCENE_PATHS.keys()
