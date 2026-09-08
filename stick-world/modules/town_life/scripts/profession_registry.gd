class_name ProfessionRegistry
extends RefCounted
## 村民职业注册表 —— 职业档案读取、spawn 分配、职业着装。
##
## 职业愿景锚点：docs/设计/系统/12-小镇生活与美术.md §三（"每个火柴人都在真实生活"）。
## 职业档案配置：config/town_life/professions.tres（BalanceResource 行数组，
## 同步装载进 BalanceConfig 类型路径 town_life.professions；读取照 formation_system
## 先例直读 .tres，不依赖 autoload 顺序，单测/直跑场景可用）。
##
## 字段契约（批次 1 消费 id/name_zh/tool/uniform；work_site_def/product/cycle
## 由批次 2 采集行为族、批次 3 工作场所消费，本批只落配置不强校验）：
##   id            职业唯一 id（写入实体 set_profession；空串 = 待业）
##   name_zh       中文名（调试与将来 UI 用）
##   work_site_def 绑定工作建筑 def_id（空 = 野外资源点，批次 2 细化）[提案/待定]
##   product       产出资源 id（resources.tres 的 id）[提案/待定]
##   cycle         工作节拍（秒）[提案/待定]
##   tool          工具/武器变体（TOOL_WEAPONS 的 key；缺省 = 不换武器）
##   uniform       职业着装色（身体色，html 颜色串如 "#7a4a21"）
##
## 着装通道（批次 1 验收核心"职业可见"）：
##   - 身体色 entity.rig.body_color（阵营识别走血条圆点/横条，body_color
##     不承担阵营语义，改色安全；setter 置 rebuild 标记由 rig 下一帧重建）
##   - 工具 entity.weapon_mount.weapon_type（garrison_spawner 先例：
##     spawn 后设置安全，setter call_deferred 重挂）
##
## 待业/在职状态：实体 _profession_id 空串 = 待业，非空 = 在职（职业 id）。
## 批次 4 征兵离岗走 set_profession("") 回待业池。

## 职业档案配置路径（BalanceResource 行数组，字段契约见类头）
const CONFIG_PATH := "res://config/town_life/professions.tres"

## tool 字段 → WeaponMount.WeaponType 映射（"none" = 徒手不挂武器场景）；
## 矿工 PICKAXE 正装，铁匠/伐木工暂用现有变体（pickaxe 代锤 / sword 代斧，
## 专属工具模型批次 2 随劳作动画一起评估）
const TOOL_WEAPONS: Dictionary = {
	"sword": WeaponMount.WeaponType.SWORD,
	"spear": WeaponMount.WeaponType.SPEAR,
	"bow": WeaponMount.WeaponType.BOW,
	"pickaxe": WeaponMount.WeaponType.PICKAXE,
	"staff": WeaponMount.WeaponType.STAFF,
	"meric": WeaponMount.WeaponType.MERIC,
	"none": WeaponMount.WeaponType.NONE,
}

## 档案缓存（load 一次；.tres 编辑热重载不追，静态职业配置无需热更）
static var _cached: Array = []


## 读取全部职业行（配置缺失/为空返回 []，调用方按"无职业可分配"降级）。
static func get_professions() -> Array:
	if not _cached.is_empty():
		return _cached
	if not ResourceLoader.exists(CONFIG_PATH):
		push_warning("[ProfessionRegistry] 职业配置不存在: %s" % CONFIG_PATH)
		return []
	var res: Resource = load(CONFIG_PATH)
	if res == null or not (res is BalanceResource):
		push_warning("[ProfessionRegistry] 职业配置加载失败: %s" % CONFIG_PATH)
		return []
	_cached = BalanceResource.sanitized_rows(res)
	return _cached


## 按 id 查职业行（未命中返回 {}）。
static func get_profession(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for row in get_professions():
		if row is Dictionary and String(row.get("id", "")) == id:
			return row
	return {}


## 村民 spawn 职业分配（initial_content 唯一调用点）：按村中轮转顺序
## index % 职业数 分配职业并应用着装，返回分配的职业 id。
## 实体经 duck 协议注入（set_profession/rig/weapon_mount，缺什么跳什么，
## 测试桩与直生实体安全降级）。无职业配置时返回 ""（实体保持待业）。
static func assign_village_job(entity: Node, index: int) -> String:
	var profs := get_professions()
	if profs.is_empty() or entity == null or not is_instance_valid(entity):
		return ""
	var row: Variant = profs[index % profs.size()]
	var prof: Dictionary = row if row is Dictionary else {}
	var id := String(prof.get("id", ""))
	if id.is_empty():
		return ""
	# duck 协议：实体必须接得住职业（set_profession），否则视为未分配
	if not entity.has_method("set_profession"):
		return ""
	entity.set_profession(id)
	apply_appearance(entity, prof)
	return id


## 应用职业着装：uniform 身体色 + tool 武器变体（缺字段跳对应项）。
static func apply_appearance(entity: Node, prof: Dictionary) -> void:
	if entity == null or not is_instance_valid(entity) or prof.is_empty():
		return
	# 着装色（rig.body_color；rig 未就绪/无此属性则跳过）
	var rig: Variant = entity.get("rig")
	if rig != null and is_instance_valid(rig) and "body_color" in rig \
			and not String(prof.get("uniform", "")).is_empty():
		rig.set("body_color", Color(String(prof["uniform"])))
	# 工具（weapon_mount.weapon_type；未知 tool 值不换装，保持默认剑）
	var tool_id := String(prof.get("tool", ""))
	if not tool_id.is_empty() and TOOL_WEAPONS.has(tool_id):
		var mount: Variant = entity.get("weapon_mount")
		if mount != null and is_instance_valid(mount) and "weapon_type" in mount:
			mount.set("weapon_type", TOOL_WEAPONS[tool_id])
