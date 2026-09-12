## TownLife 模块公共接口契约
##
## 本模块承载"小镇生活"线：村民职业（ProfessionRegistry）→ 采集行为族
## （批次 2 BehaviorHarvest）→ 工作场所运转（批次 3 WorkSlots/节律）→
## 人口扩充与配比（批次 4）。愿景锚点：docs/设计/系统/12-小镇生活与美术.md §三。
##
## 外部模块通过本契约与模块交互：
##   - TownLifeAPI.assign_village_job(entity, index) -> String
##       村民职业**强制**分配（轮转 index % 职业数，不看配额）+ 着装应用，
##       返回职业 id（"" = 无职业/待业）。测试摆拍/调试用。
##   - TownLifeAPI.assign_village_jobs(entities) -> Dictionary
##       村庄批量**配比**分配（批次 4，spawn 正片入口）：各职业不超过
##       min(配置 quota, 工位容量)，配额满的村民待业。返回
##       {"jobs": {职业id: 人数}, "idle": 待业数}。
##       initial_content.spawn_npcs 是唯一调用点。
##   - TownLifeAPI.get_professions() -> Array
##       全部职业档案行（config/town_life/professions.tres）。
##   - TownLifeAPI.get_profession(id) -> Dictionary
##       按 id 查职业行（未命中 {}）。
##   - TownLifeAPI.get_placeholder_work_site_x(work_site_def) -> float
##       占位工位 X 坐标（未配置返回 NAN）。批次 3 起降级为 get_work_site
##       的兜底路径，外部一般不直调。
##   - TownLifeAPI.get_work_site(entity, work_site_def) -> Dictionary
##       村民工位寻位（批次 3）：建筑组 WorkSlots 真槽位优先（def_id 匹配 +
##       is_operational + 最近槽位），无匹配建筑降级占位工位。返回
##       {"pos": Vector2（y=NAN，调用方按实体地面线补齐）, "building": Node2D
##       或 null}；无可用工位返回 {}。
##   - TownLifeAPI.is_work_time(hour := NAN) -> bool
##       村民劳作节律判定（批次 3，[提案/待定] 7~19 时在岗）：缺省读
##       WorldState.game_time，hour 参数显式注入（单测/特殊场景）。
##
## 职业档案字段：见 profession_registry.gd 类头（id/name_zh/work_site_def/
## product/produce_amount/consume_res/consume_amount/cycle/tool/quota）。
##
## 职业状态协议（弱类型，实体侧零依赖本模块）：
##   - 实体 set_profession(id) / get_profession()：空串 = 待业，非空 = 在职。
##   - 批次 4 征用离岗：set_profession("")（编队征用互斥，回待业池）。
##   - 实体 is_villager 标志（批次 4）：村民身份与职业解耦——待业村民与
##     征用离岗村民仍是村民（AI wander 作用域），战斗/敌方单位无此标志。
##
## ⚠️ 契约说明：实现全部在 ProfessionRegistry（静态、无状态）；本文件是
## 契约声明层 + 转发，外部模块禁止直接 preload 模块内部脚本路径。
class_name TownLifeAPI
extends RefCounted

## 职业档案配置路径（BalanceResource 行数组）
const PROFESSIONS_CONFIG := "res://config/town_life/professions.tres"


## 村民职业强制分配（轮转 index % 职业数，不看配额）+ 着装应用，返回职业 id。
## 测试摆拍/调试用——正片 spawn 走 assign_village_jobs 配比分配。
static func assign_village_job(entity: Node, index: int) -> String:
	return ProfessionRegistry.assign_village_job(entity, index)


## 村庄批量配比分配（批次 4）：各职业不超过 min(quota, 工位容量)，
## 配额满待业。返回 {"jobs": {职业id: 人数}, "idle": 待业数}。
static func assign_village_jobs(entities: Array) -> Dictionary:
	return ProfessionRegistry.assign_village_jobs(entities)


## 全部职业档案行。
static func get_professions() -> Array:
	return ProfessionRegistry.get_professions()


## 按 id 查职业行（未命中 {}）。
static func get_profession(id: String) -> Dictionary:
	return ProfessionRegistry.get_profession(id)


## 占位工位 X 坐标（未配置返回 NAN）。
static func get_placeholder_work_site_x(work_site_def: String) -> float:
	return ProfessionRegistry.get_placeholder_work_site_x(work_site_def)


## 村民工位寻位：WorkSlots 真槽位优先，占位工位降级（细节见 profession_registry）。
static func get_work_site(entity: Node2D, work_site_def: String) -> Dictionary:
	return ProfessionRegistry.get_work_site(entity, work_site_def)


## 是否工作时段（劳作节律 [提案/待定]：7~19 时在岗；hour 注入缺省读全局时间）。
static func is_work_time(hour: float = NAN) -> bool:
	return ProfessionRegistry.is_work_time(hour)
