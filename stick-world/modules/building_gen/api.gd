extends Node
## 程序化建筑生成模块（building_gen）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 building_gen 内部脚本的方法。
##
## 公共类型契约：Building（scripts/building.gd，全局 class_name）为对外公共实体类型，
## construction/world 等模块可用 is/as 判型并读写 Building.State 状态；
## 除该类型外仍禁止引用本模块内部脚本（先例：combat/api.gd 的 TargetFinder 契约）。
##
## 材质纹理生成已迁移至 modules/texture_gen/，详见 TextureGenAPI。

# ===== 公共信号 =====

## 建筑生成完成
@warning_ignore("unused_signal")
signal building_generated(building_type: String, instance: Node)


# ===== 建筑场景模板注册表 =====

## building_gen 自有的建筑场景模板（def_id → 相对本模块的 .tscn 路径）。
## 命名约定：文件名 = def_id = 存档字段三者一致（详见 buildings/README.md），
## 故直接以 def_id 为键，零映射成本。
## 材质/模块分离后：房屋类建筑共用草棚外壳（placeholder.tscn），
## 兵营/仓库等 def 复用该外壳，材质与功能模块由 def 数据驱动（后续扩展）。
const _BUILDING_SCENE_PATHS := {
	"placeholder": "buildings/placeholder.tscn",
	"wall_tier1": "buildings/wall_tier1.tscn",
	"wall_tier2": "buildings/wall_tier2.tscn",
	"wall_tier3": "buildings/wall_tier3.tscn",
	"wall_gate": "buildings/wall_gate.tscn",
	# 2026-08-22：兵营/仓库脱离共用草棚外壳，各自程序化差异化外观（PLACEHOLDER 几何挂件）
	"barracks": "buildings/barracks.tscn",
	"warehouse": "buildings/warehouse.tscn",
	# 铁匠铺 Lv1：开放锻造棚（石炉/烟囱/铁砧/工作台挂件），参考图 buildings/reference/smithy_lv1.png
	"smithy_lv1": "buildings/smithy_lv1.tscn",
	# 石造仓库：纯石头建筑（垛口石墙/拱窗/石带/角石），批次 2 石头结构件化验收载体
	"stone_warehouse": "buildings/stone_warehouse.tscn",
	# 宅邸：二层半木悬挑建筑（外梯+阳台+穿坡烟囱），批次 3 多层建筑验收载体
	"manor": "buildings/manor.tscn",
	# 木骨石基民居：石基+半木+金茅草（v12 笔触），批次 5 多材质家族 T2 民居
	"timber_cottage": "buildings/timber_cottage.tscn",
	# 议事厅：地标级混合精修（石砌角石+半木悬挑+茅草坡+脊上钟楼+外梯阳台），批次 5 验收载体
	"grand_hall": "buildings/grand_hall.tscn",
}


## 加载本模块提供的建筑场景模板（def_id → PackedScene）。
## 场景模板归属本模块，路径映射只在模块内部维护，外部模块不得硬编码内部路径。
static func load_building_scene(def_id: String) -> PackedScene:
	if not _BUILDING_SCENE_PATHS.has(def_id):
		push_warning("[BuildingGen] 未知建筑 def_id: %s" % def_id)
		return null
	return load("res://modules/building_gen/" + _BUILDING_SCENE_PATHS[def_id]) as PackedScene


## 返回本模块提供的默认建筑 def_id 列表（可供构造系统注册为可建造建筑）。
static func get_default_building_def_ids() -> Array:
	return _BUILDING_SCENE_PATHS.keys()


# ===== 管线 def ↔ 运行时 def 映射（INT-4） =====

## 管线 def（CityGen 卡名去 `_wN` 宽度后缀，如 smithy2_w8 → smithy2）到运行时
## def_id（本模块场景表口径）的映射。键 = 运行时 def_id，值 = 管线 def 名单 +
## 首选宽度档（格，供 DYN 动态宽度与建造端落表参考）。
## 未收录的管线 def 无运行时实体——3D 烘卡照常摆（纯视觉），物化层跳过。
## stone_warehouse 为 city+ 仓储的备选壳（warehouse 的石头变体），启用时在
## warehouse 的名单里择档替换。
const _PIPELINE_DEF_MAP := {
	"smithy_lv1": {"defs": ["smithy1", "smithy2", "smithy3", "smithy4"], "width": 8},
	"warehouse": {"defs": ["warehouse"], "width": 16},
	"barracks": {"defs": ["barracks"], "width": 12},
	"grand_hall": {"defs": ["guildhall", "council_hall", "governor_palace",
			"imperial_palace"], "width": 12},
	"timber_cottage": {"defs": ["house", "townhouse", "rowhouse"], "width": 10},
	"placeholder": {"defs": ["cottage", "hayloft", "shelter", "inn_post"], "width": 8},
}


## 反查：管线 def → 运行时 def_id（未收录返回空串）。
## CityGen plan 物化（ConstructionManager）与内景底图加载（INT-3，后续）共用。
static func runtime_def_for_pipeline(pipeline_def: String) -> String:
	for runtime_id: String in _PIPELINE_DEF_MAP.keys():
		if pipeline_def in _PIPELINE_DEF_MAP[runtime_id]["defs"]:
			return runtime_id
	return ""


## 映射表整体导出（键=运行时 def、值=管线 def 名单+首选宽度档）——INT-4 落表
## 与审计用；运行时消费走 runtime_def_for_pipeline 单口。
static func pipeline_def_map() -> Dictionary:
	return _PIPELINE_DEF_MAP.duplicate(true)
