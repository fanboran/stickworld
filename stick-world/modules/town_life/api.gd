## TownLife 模块公共接口契约
##
## 本模块承载"小镇生活"线：村民职业（ProfessionRegistry）→ 采集行为族
## （批次 2 BehaviorHarvest）→ 工作场所运转（批次 3 WorkSlots/节律）→
## 人口扩充与配比（批次 4）。愿景锚点：docs/设计/系统/12-小镇生活与美术.md §三。
##
## 外部模块通过本契约与模块交互：
##   - TownLifeAPI.assign_village_job(entity, index) -> String
##       村民 spawn 职业分配（轮转）+ 着装应用，返回职业 id（"" = 无职业/待业）。
##       initial_content.spawn_npcs 是唯一调用点。
##   - TownLifeAPI.get_professions() -> Array
##       全部职业档案行（config/town_life/professions.tres）。
##   - TownLifeAPI.get_profession(id) -> Dictionary
##       按 id 查职业行（未命中 {}）。
##   - TownLifeAPI.get_placeholder_work_site_x(work_site_def) -> float
##       占位工位 X 坐标（A 线铁匠铺到位前的过渡；未配置返回 NAN）。
##       批次 3 WorkSlots 消费到位后退役。
##
## 职业档案字段：见 profession_registry.gd 类头（id/name_zh/work_site_def/
## product/produce_amount/consume_res/consume_amount/cycle/tool/uniform）。
##
## 职业状态协议（弱类型，实体侧零依赖本模块）：
##   - 实体 set_profession(id) / get_profession()：空串 = 待业，非空 = 在职。
##   - 批次 4 征兵离岗：set_profession("") 回待业池。
##
## ⚠️ 契约说明：实现全部在 ProfessionRegistry（静态、无状态）；本文件是
## 契约声明层 + 转发，外部模块禁止直接 preload 模块内部脚本路径。
class_name TownLifeAPI
extends RefCounted

## 职业档案配置路径（BalanceResource 行数组）
const PROFESSIONS_CONFIG := "res://config/town_life/professions.tres"


## 村民 spawn 职业分配（轮转 index % 职业数）+ 着装应用，返回职业 id。
static func assign_village_job(entity: Node, index: int) -> String:
	return ProfessionRegistry.assign_village_job(entity, index)


## 全部职业档案行。
static func get_professions() -> Array:
	return ProfessionRegistry.get_professions()


## 按 id 查职业行（未命中 {}）。
static func get_profession(id: String) -> Dictionary:
	return ProfessionRegistry.get_profession(id)


## 占位工位 X 坐标（未配置返回 NAN）。
static func get_placeholder_work_site_x(work_site_def: String) -> float:
	return ProfessionRegistry.get_placeholder_work_site_x(work_site_def)
