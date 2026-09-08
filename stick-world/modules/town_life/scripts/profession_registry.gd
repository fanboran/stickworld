class_name ProfessionRegistry
extends RefCounted
## 村民职业注册表 —— 职业档案读取、spawn 分配、职业着装。
##
## 职业愿景锚点：docs/设计/系统/12-小镇生活与美术.md §三（"每个火柴人都在真实生活"）。
## 职业档案配置：config/town_life/professions.tres（BalanceResource 行数组，
## 同步装载进 BalanceConfig 类型路径 town_life.professions；读取照 formation_system
## 先例直读 .tres，不依赖 autoload 顺序，单测/直跑场景可用）。
##
## 字段契约（批次 1 消费 id/name_zh/tool/uniform；批次 2 消费 product/
## produce_amount/consume_res/consume_amount/cycle；批次 3 消费 work_site_def）：
##   id             职业唯一 id（写入实体 set_profession；空串 = 待业）
##   name_zh        中文名（调试与将来 UI 用）
##   work_site_def  绑定工作建筑 def_id（空 = 野外资源点采集模式；
##                  非空 = 工位模式：建筑 WorkSlots 真槽位优先，占位定点降级）
##                  [提案/待定]
##   product        产出资源 id（resources.tres 的 id）[提案/待定]
##   produce_amount 每拍产出量（资源点模式实际量以资源点 harvest 返回为准）
##                  [提案/待定]
##   consume_res    每拍消耗资源 id（空 = 无消耗；铁匠 = res_metal_ore，
##                  "矿→锭"转化链语义）[提案/待定]
##   consume_amount 每拍消耗量（0 = 无消耗）[提案/待定]
##   cycle          工作节拍（秒/拍）[提案/待定]
##   tool           工具/武器变体（TOOL_WEAPONS 的 key；缺省 = 不换武器）
##   uniform        职业着装色（身体色，html 颜色串如 "#7a4a21"）
##   quota          村庄该职业最大在职数（批次 4 配比；缺省 1）[提案/待定]
##                  工位职业实际配额 = min(quota, 工位容量)，见 count_work_capacity
##
## 数值口径（[提案/待定]，待实测定稿）：采集 20/拍与玩家手采同速（HARVEST_PER_ACTION）；
## 打铁 consume 10 矿 → produce 6 锭/拍（熔炼损耗），节拍 4s 略快于采集 5s，
## 全链矿净增速为正（矿工 4/s vs 铁匠 2.5/s），三资源库存可同时增长。
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

## 占位工位定点（X 坐标，Y 由行为运行时取实体地面线）[提案/待定]
## 批次 3 起 WorkSlots 真槽位优先（get_work_site 扫 building 组），本表降级为
## "无匹配建筑槽位时"的兜底（A 线铁匠铺场景未到位 / 建筑被毁 / 测试桩环境的
## 降级路径）——A 线铁匠铺落地注册后无需改本表即自动切到真建筑。
## 1120 = 仓库（cell 15~31，X 480~992）右侧、村民聚居区（X 1050/1250）之间的村道口。
const PLACEHOLDER_WORK_SITES: Dictionary = {
	"smithy_lv1": 1120.0,
}

## 工作时段（游戏小时，0~24）[提案/待定]
## 对齐 EnvironmentAPI.LIGHT_KEYFRAMES 的日照感（早晨 7 点亮 / 黄昏 19 点暗）：
## 7~19 在岗劳作，其余休息（P0 两态节律，完整日夜系统不做）。
const WORK_HOUR_START: float = 7.0
const WORK_HOUR_END: float = 19.0


## 查占位工位 X 坐标（未配置返回 NAN，调用方视为无工位可用）。
static func get_placeholder_work_site_x(work_site_def: String) -> float:
	return float(PLACEHOLDER_WORK_SITES.get(work_site_def, NAN))


## 为村民寻找工位点（批次 3 WorkSlots 消费入口）：
##   1) 扫 "building" 组：def_id 匹配 work_site_def 且 is_operational()（被毁/
##      建造中跳过）且有 WorkSlot 槽位 → 取最近建筑的最近槽位；
##   2) 无匹配建筑（A 线场景未到位 / 建筑被毁 / 桩环境）→ 降级占位工位表。
## 返回 {"pos": Vector2, "building": Node2D}；building = null 表示占位工位；
## 无任何可用工位返回 {}（调用方视为寻位失败）。
## pos.y 恒为 NAN：槽位 marker 只消费 X（横向工位），Y 由调用方按实体地面线
## 补齐（同 BehaviorHaul 取货点口径——卷轴地图工作站位全在地面带内，可达）。
## 建筑侧走鸭子协议（get("def_id") / is_operational / get_work_slot_positions），
## 不依赖 building_gen 类型，测试桩可注入。
static func get_work_site(entity: Node2D, work_site_def: String) -> Dictionary:
	if work_site_def.is_empty() or entity == null or not is_instance_valid(entity):
		return {}
	var tree := entity.get_tree() if entity.is_inside_tree() else null
	if tree != null:
		var best_building: Node2D = null
		var best_slot_x: float = 0.0
		var best_dist: float = INF
		for node in tree.get_nodes_in_group("building"):
			var b := node as Node2D
			if b == null or not is_instance_valid(b) or not b.is_inside_tree():
				continue
			if String(b.get("def_id")) != work_site_def:
				continue
			if b.has_method("is_operational") and not b.is_operational():
				continue
			if not b.has_method("get_work_slot_positions"):
				continue
			for slot_v in b.get_work_slot_positions():
				var slot: Vector2 = slot_v if slot_v is Vector2 else Vector2.ZERO
				var d: float = slot.distance_to(entity.global_position)
				if d < best_dist:
					best_dist = d
					best_building = b
					best_slot_x = slot.x
		if best_building != null:
			return {"pos": Vector2(best_slot_x, NAN), "building": best_building}
	var px := get_placeholder_work_site_x(work_site_def)
	if not is_nan(px):
		return {"pos": Vector2(px, NAN), "building": null}
	return {}


## 是否工作时段（村民劳作节律判定，读 WorldState.game_time——EnvironmentSystem
## 每帧推进/恢复的全局小时数，autoload 直读无场景树依赖，单测可直接赋值注入）。
## game_time <= 0 = 时间未初始化（无 EnvironmentSystem 的测试/桩环境）→
## 视为全天工作（无节律数据就没有节律，对既有路径零扰动）。
## 单测/特殊场景经 hour 参数显式注入可绕过全局时间。
static func is_work_time(hour: float = NAN) -> bool:
	if not is_nan(hour):
		var h := fposmod(hour, 24.0)
		return h >= WORK_HOUR_START and h < WORK_HOUR_END
	if WorldState == null or WorldState.game_time <= 0.0:
		return true
	var t := fposmod(WorldState.game_time, 24.0)
	# 7~19 在岗；跨零点休息段（19→7）自然落在取值域外，端点含头不含尾防浮点抖动
	return t >= WORK_HOUR_START and t < WORK_HOUR_END

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
##
## ⚠️ 本函数是**强制分配**入口（不看配额，index 定职业）——测试摆拍/
## 调试用（如集成套件补 spawn 指定职业）；正片 spawn 走 assign_village_jobs
## 配比分配（批次 4）。
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


# ─────────────────────────── 批次 4：村庄职业配比 ────────────────────────────

## quota 字段缺省值（professions.tres 行未写 quota 时的村庄该职业最大在职数）
const DEFAULT_QUOTA: int = 1


## 数村庄某职业的工位容量：
##   - 扫 "building" 组累计匹配 def_id + is_operational 建筑的 WorkSlot 槽位数
##     （复用 get_work_site 的真建筑语义）；
##   - 无匹配真建筑但占位表覆盖该 def → 容量 1（占位工位语义 = "村子有该
##     需求"的最低配比兜底，[提案/待定]：A 线铁匠铺落地前保持铁匠可见）；
##   - 都无 → 0（该职业不参与本次配比分配）。
## ref_entity 仅用于取场景树（容量计数与位置无关）；不可用返回 0。
static func count_work_capacity(ref_entity: Node, work_site_def: String) -> int:
	if work_site_def.is_empty() or ref_entity == null or not is_instance_valid(ref_entity):
		return 0
	var tree := ref_entity.get_tree() if ref_entity.is_inside_tree() else null
	var total: int = 0
	if tree != null:
		for node in tree.get_nodes_in_group("building"):
			var b := node as Node2D
			if b == null or not is_instance_valid(b) or not b.is_inside_tree():
				continue
			if String(b.get("def_id")) != work_site_def:
				continue
			if b.has_method("is_operational") and not b.is_operational():
				continue
			if b.has_method("get_work_slot_positions"):
				total += (b.get_work_slot_positions() as Array).size()
	if total > 0:
		return total
	return 0 if is_nan(get_placeholder_work_site_x(work_site_def)) else 1


## 村庄批量配比分配（批次 4，initial_content.spawn_npcs 正片入口）：
##   - 各职业配额 = min(配置 quota, 工位容量)；工位容量仅约束工位职业
##     （work_site_def 非空），资源点职业（空 def）不受工位约束——资源点
##     存在性由城镇生成线保证（village_a 净空带吃掉资源点是布局阶段问题，
##     不据此砍职业配比）；
##   - 村民按职业档案序轮转分配，配额满跳下一职业，全部配额满 → 待业
##     （set_profession("")，走 wander 闲逛）；
##   - 配额满即止的轮转序 = 档案配置序（blacksmith → lumberjack → miner）。
## 返回 {"jobs": {职业id: 人数}, "idle": 待业数}（stdout 证据/测试断言用）。
## 单实体（缺协议/无效）按待业计，不抛错。
static func assign_village_jobs(entities: Array) -> Dictionary:
	var profs := get_professions()
	var stats: Dictionary = {"jobs": {}, "idle": 0}
	var quotas: Dictionary = {}
	var prof_order: Array = []
	if not profs.is_empty():
		# 先算各职业配额（容量参照取第一个有效实体，仅借它的场景树）
		var ref: Node = null
		for e in entities:
			if e != null and is_instance_valid(e):
				ref = e
				break
		for row in profs:
			var prof: Dictionary = row if row is Dictionary else {}
			var id := String(prof.get("id", ""))
			if id.is_empty():
				continue
			prof_order.append(prof)
			var q := int(prof.get("quota", DEFAULT_QUOTA))
			var site_def := String(prof.get("work_site_def", ""))
			if not site_def.is_empty():
				q = mini(q, count_work_capacity(ref, site_def))
			quotas[id] = q
	# 轮转分配：指针沿档案序循环，配额满跳过；一整圈无位即全待业
	var assigned: Dictionary = {}
	var cursor: int = 0
	var quota_left: bool = not prof_order.is_empty()
	for e in entities:
		if e == null or not is_instance_valid(e) or not e.has_method("set_profession"):
			stats["idle"] = int(stats["idle"]) + 1
			continue
		if not quota_left:
			stats["idle"] = int(stats["idle"]) + 1
			continue
		var placed: bool = false
		for _scan in prof_order.size():
			var prof: Dictionary = prof_order[cursor % prof_order.size()]
			cursor += 1
			var id := String(prof.get("id", ""))
			if int(assigned.get(id, 0)) >= int(quotas.get(id, 0)):
				continue
			e.set_profession(id)
			apply_appearance(e, prof)
			assigned[id] = int(assigned.get(id, 0)) + 1
			placed = true
			break
		if not placed:
			quota_left = false  # 一整圈无位：剩余村民全部待业
			stats["idle"] = int(stats["idle"]) + 1
	stats["jobs"] = assigned
	return stats


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
