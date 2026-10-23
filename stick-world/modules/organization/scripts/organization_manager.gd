extends RefCounted
class_name OrganizationManager
## 组织模块内部管理逻辑类
##
## api.gd 委派实际实现到此。
## 管理组织的 CRUD、层级校验、编制配置、人事任免等核心逻辑。
## 指挥链/预设子域逻辑在 scripts/command/（org_preset_kit 蓝图预设、succession_engine
## 补位引擎、report_gate 上报门控、org_command_dispatcher、transport_layer）——
## 状态真相源与公共 API 薄壳留在本类。
##
## 2026-08 集中制迁移（WorldState 容器决策 A）：组织数据从裸 Dictionary 升级为
## OrganizationState 对象（core/entities/organization_state.gd），并经 set_world()
## 同步注册到 WorldState 容器——存档由 WorldState 统一序列化，本类不再自持存储格式。

# ===== 常量 =====

## 有效层级范围
const TIER_MIN: int = 1
const TIER_MAX: int = 5

## 有效标签
const VALID_TAGS: Array[String] = [
	"MILITARY", "RESEARCH", "ENGINEERING", "ADMINISTRATION", "LOGISTICS"
]

## 有效自主权限级别
const VALID_AUTONOMY_LEVELS: Array[String] = [
	"HIGH", "MEDIUM", "LOW"
]

## 有效插入位置
const VALID_POSITIONS: Array[String] = [
	"above", "below"
]

const ScriptOrgState := preload("res://core/entities/organization_state.gd")
const ScriptWorldState := preload("res://core/autoload/world_state.gd")
const ScriptSerializer := preload("res://core/entities/world_state_serializer.gd")
const ScriptDispatcher := preload("res://modules/organization/scripts/command/org_command_dispatcher.gd")
const ScriptTransport := preload("res://modules/organization/scripts/command/transport_layer.gd")
const ScriptDefaultBehaviorWriter := preload("res://modules/organization/scripts/default_behavior_writer.gd")
const ScriptPresetKit := preload("res://modules/organization/scripts/command/org_preset_kit.gd")
const ScriptSuccessionEngine := preload("res://modules/organization/scripts/command/succession_engine.gd")
const ScriptReportGate := preload("res://modules/organization/scripts/command/report_gate.gd")

const TAG_TO_ENUM := {
	"MILITARY": ScriptOrgState.Tag.MILITARY,
	"RESEARCH": ScriptOrgState.Tag.RESEARCH,
	"ENGINEERING": ScriptOrgState.Tag.ENGINEERING,
	"ADMINISTRATION": ScriptOrgState.Tag.ADMINISTRATION,
	"LOGISTICS": ScriptOrgState.Tag.LOGISTICS,
}

const AUTONOMY_TO_ENUM := {
	"HIGH": ScriptOrgState.AutonomyLevel.HIGH,
	"MEDIUM": ScriptOrgState.AutonomyLevel.MEDIUM,
	"LOW": ScriptOrgState.AutonomyLevel.LOW,
}

## Tag 枚举 → 字符串（export_as_preset 序列化与 default_behavior 档案行匹配用，与 TAG_TO_ENUM 互逆）
const ENUM_TO_TAG := {
	ScriptOrgState.Tag.MILITARY: "MILITARY",
	ScriptOrgState.Tag.RESEARCH: "RESEARCH",
	ScriptOrgState.Tag.ENGINEERING: "ENGINEERING",
	ScriptOrgState.Tag.ADMINISTRATION: "ADMINISTRATION",
	ScriptOrgState.Tag.LOGISTICS: "LOGISTICS",
}


# ===== 内部数据结构 =====

## 所有组织数据，key = org_id, value = OrganizationState
var organizations: Dictionary = {}

## 组织 ID 自增计数器
var _next_id: int = 1

## WorldState 容器引用（2026-08 集中制：由 api.setup 注入，null 时跳过容器同步，仅测试/独立使用）
var _world: Node = null

# ===== 批次 3：指挥链组件（架构文档 §四）=====

## 补位引擎上报（对内信号；api.setup 时转发到公共信号 report_filed——manager 内部
## 发射的上报如 commander_lost 必报，无法经 api 方法回程包装）
signal report_filed(org_id: String, report: Dictionary)

## 逐层命令分解器（§4.1，无状态纯逻辑）
var command_dispatcher: ScriptDispatcher

## 传输层 v1 抽象传播（§4.2）：三 provider 经 api.set_transport_providers 装配注入；
## location 是组织自有数据，manager 内部接线
var transport_layer: ScriptTransport

## 预设域助手（蓝图/预设系统，command/org_preset_kit.gd）：实例化/回滚复用宿主写口
var _preset_kit: ScriptPresetKit

## 补位引擎（§4.3.1，command/succession_engine.gd）：组织表经形参传入，cmd provider 持助手
var _succession_engine: ScriptSuccessionEngine

## 上报门控（§4.4，command/report_gate.gd）：纯判定，伤亡阈值持助手
var _report_gate: ScriptReportGate

## 组织侧 default_behavior 写入方（GK-5 前置批）：惰性自建，档案 ai.org_default_behavior
## 总闸缺省关 = 不触碰组织状态；装配/测试可经 set_default_behavior_writer 注入
var _behavior_writer: ScriptDefaultBehaviorWriter = null


func _init() -> void:
	command_dispatcher = ScriptDispatcher.new()
	transport_layer = ScriptTransport.new()
	transport_layer.set_location_provider(_org_location)
	_preset_kit = ScriptPresetKit.new(self)
	_succession_engine = ScriptSuccessionEngine.new()
	_report_gate = ScriptReportGate.new()


# ===== 工具方法 =====

## 注入 WorldState 容器引用（集中制存档/查询）
func set_world(world: Node) -> void:
	_world = world


## 生成唯一组织 ID
func _generate_org_id() -> String:
	var id := "org_%d" % _next_id
	_next_id += 1
	return id


## 校验层级是否在有效范围内
func _is_valid_tier(tier: int) -> bool:
	return tier >= TIER_MIN and tier <= TIER_MAX


## 校验标签是否有效
func _is_valid_tag(tag: String) -> bool:
	return tag in VALID_TAGS


## 校验自主权限级别是否有效
func _is_valid_autonomy_level(level: String) -> bool:
	return level.to_upper() in VALID_AUTONOMY_LEVELS


## 校验插入位置是否有效
func _is_valid_position(position: String) -> bool:
	return position.to_lower() in VALID_POSITIONS


## 校验 parent/child tier 关系
## 子组织的 tier 必须 = 父组织的 tier - 1
func _validate_tier_relationship(parent_tier: int, child_tier: int) -> bool:
	return child_tier == parent_tier - 1


## 获取组织状态对象，不存在返回 null
func _get_org(org_id: String) -> ScriptOrgState:
	return organizations.get(org_id, null)


## 构造初始化的组织状态对象（create/insert_tier 共用）
func _make_state(org_id: String, name: String, tag_enum: int, tier: int, parent_id: String) -> ScriptOrgState:
	var state: ScriptOrgState = ScriptOrgState.new()
	state.id = org_id
	state.name = name
	state.tag = tag_enum as ScriptOrgState.Tag
	state.tier = tier
	state.parent_org = parent_id
	state.autonomy_level = ScriptOrgState.AutonomyLevel.MEDIUM
	_apply_default_behavior(state)
	return state


# ── 组织侧 default_behavior 写入方（GK-5 前置批）───────────────
# 落点 = _make_state（create_organization 与 insert_tier 的唯一共用构造点，预设实例化也
# 经 create_organization 走到此处）——创建期单点接线，组织一诞生即带档案默认行为。
# 档案 config/ai/org_default_behavior.tres：总闸 writer_enabled 生效默认 true（GK-5 第一层
# 已开闸）；显式配 false 可退回零回归门。闸开按标签行 > 全域兜底行填充 v2 字典（消费端
# UtilityScorer）。显式蓝图 default_behavior 仍优先（见 org_preset_kit.
# _instantiate_preset：档案默认 < 蓝图显式配置）。惰性自建路径同时接上
# balance_changed → reload()（热重载，改 .tres 免重启）。

## 装配/测试注入写入方（缺省惰性自建；注入须在创建组织前）
func set_default_behavior_writer(writer: ScriptDefaultBehaviorWriter) -> void:
	_behavior_writer = writer


## 按档案行把 default_behavior 灌进组织状态（闸关/无命中 = 空操作）
func _apply_default_behavior(state: ScriptOrgState) -> bool:
	if _behavior_writer == null:
		_behavior_writer = ScriptDefaultBehaviorWriter.new()
		_behavior_writer.bind_balance_reload()
	return _behavior_writer.apply_to(state, String(ENUM_TO_TAG.get(state.tag, "")))


## 读取组织 default_behavior（只读深拷贝；未配置/组织不存在返回空字典）
func get_default_behavior(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {}
	return org.default_behavior.duplicate(true)


# ===== 创建/查询 =====

## 创建组织
func create_organization(name: String, tag: String, tier: int, parent_id: String) -> Dictionary:
	# 校验层级
	if not _is_valid_tier(tier):
		return {"ok": false, "error": "层级必须在 %d-%d 范围内" % [TIER_MIN, TIER_MAX]}

	# 校验标签
	if not _is_valid_tag(tag):
		return {"ok": false, "error": "无效的标签: %s" % tag}

	# 校验父组织（如果指定）
	if parent_id != "":
		var parent := _get_org(parent_id)
		if parent == null:
			return {"ok": false, "error": "父组织不存在: %s" % parent_id}
		if not _validate_tier_relationship(parent.tier, tier):
			return {"ok": false, "error": "子组织层级必须比父组织低一级"}

	var org_id := _generate_org_id()
	var state: ScriptOrgState = _make_state(org_id, name, TAG_TO_ENUM[tag], tier, parent_id)
	organizations[org_id] = state

	# 关联父组织
	if parent_id != "":
		var parent: ScriptOrgState = organizations[parent_id]
		parent.child_orgs.append(org_id)

	# 集中制：同步注册到 WorldState 容器
	if _world != null:
		_world.register_organization(state)

	return {"ok": true, "data": {"org_id": org_id}}


## 获取组织数据（data 为纯 Dictionary，序列化走 WorldState 统一格式）
func get_organization(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	return {"ok": true, "data": ScriptSerializer.organization_to_dict(org)}


## 获取下级组织 ID 列表
func get_child_orgs(org_id: String) -> Array[String]:
	var org := _get_org(org_id)
	if org == null:
		return []
	# 显式构造类型化数组（child_orgs 存储为无类型 Array，直接 duplicate 会触发返回类型检查崩溃）
	var result: Array[String] = []
	for child_id in org.child_orgs:
		result.append(child_id)
	return result


## 按标签查询组织
func get_orgs_by_tag(tag: String) -> Array[String]:
	if not _is_valid_tag(tag):
		return []
	var tag_enum: int = TAG_TO_ENUM[tag]
	var result: Array[String] = []
	for org_id in organizations:
		if organizations[org_id].tag == tag_enum:
			result.append(org_id)
	return result


## 查询某个地块内的所有组织
func get_orgs_in_region(region_id: String) -> Array[String]:
	var result: Array[String] = []
	for org_id in organizations:
		if organizations[org_id].location == region_id:
			result.append(org_id)
	return result


## 列出全部根组织（森林多根；OrgPanel 树构建入口，无全列表遍历口故单设）
func list_root_orgs() -> Array[String]:
	var result: Array[String] = []
	for org_id in organizations:
		if organizations[org_id].parent_org == "":
			result.append(org_id)
	return result


## 改名（GDD §3.3 命名可改；行政区划锁定规则挂行政/扩张系统后续任务）
func set_org_name(org_id: String, new_name: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	var trimmed := new_name.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "error": "名称不能为空"}
	org.name = trimmed
	return {"ok": true, "data": {}}


# ===== 编制管理 =====

## 设置人员编制模板
func set_personnel_template(org_id: String, template: Dictionary) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.personnel_template = template.duplicate()
	return {"ok": true, "data": {}}


## 设置装备模板
func set_equipment_template(org_id: String, template: Dictionary) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.equipment_template = template.duplicate()
	return {"ok": true, "data": {}}


## 设置自主决策权限
func set_autonomy(org_id: String, level: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	var normalized := level.to_upper()
	if not _is_valid_autonomy_level(normalized):
		return {"ok": false, "error": "无效的自主权限级别: %s，有效值: high/medium/low" % level}
	org.autonomy_level = AUTONOMY_TO_ENUM[normalized]
	return {"ok": true, "data": {}}


## 设置默认行为
func set_default_behavior(org_id: String, behavior: Dictionary) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.default_behavior = behavior.duplicate()
	return {"ok": true, "data": {}}


## 设置组织驻地（org.location 语义源，组织系统架构 §4.2.2）。
## 区域标识两级：settlement_id（定居点级）或 map_id（地图根级）——
## 传输层跨图分支经 region_distance_provider 消费（world_map.region_distance 解析）。
## 赋值方 = 装配层 org_created 回填（建队回填起步）；「驻地随实体移动更新」为
## 后续语义（架构 §八 开放问题），不在本 setter 扩展。
func set_location(org_id: String, location: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.location = location
	return {"ok": true, "data": {}}


# ===== 人事 =====

## 任命指挥官
func assign_commander(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.commander_id = stickman_id
	return {"ok": true, "data": {}}


## 撤除指挥官
## 补位引擎（§4.3.1）：手工撤职与死亡同一入口——撤除后按 succession_rule 自动补位
func remove_commander(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if org.commander_id == "":
		return {"ok": true, "data": {}}
	var prev := org.commander_id
	org.commander_id = ""
	_run_succession(org, prev)
	return {"ok": true, "data": {}}


## 分配火柴人到组织
func assign_stickman(org_id: String, stickman_id: String, _role: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if stickman_id in org.personnel:
		return {"ok": false, "error": "该火柴人已在组织中: %s" % stickman_id}
	org.personnel.append(stickman_id)
	return {"ok": true, "data": {}}


## 从组织移除火柴人
## 补位引擎（§4.3.1）：被移除者是指挥官时自动补位（死亡/调离同一入口，无独立 notify API；
## FormationSystem 死亡清理处既有调用天然触发，零新增挂点）
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if stickman_id not in org.personnel:
		return {"ok": false, "error": "该火柴人不在组织中: %s" % stickman_id}
	org.personnel.erase(stickman_id)
	if org.commander_id == stickman_id:
		org.commander_id = ""
		_run_succession(org, stickman_id)
	return {"ok": true, "data": {}}


## 跨组织调人（原子接口，方案 §五.6 定稿口径）：**合法性校验一体、先校验后落地**，
## 任一校验失败直接返回 {ok:false, error} 且不改动任何状态（不做"先删后加再回滚"）。
## 校验口径 = 既有 remove_stickman + assign_stickman 校验的并集，不新造规则：
##   ① 源组织存在  ② 目标组织存在  ③ 源组织 ≠ 目标组织
##   ④ stickman_id 在源组织 personnel 中  ⑤ stickman_id 不在目标组织 personnel 中（防双挂）
## 层级/职责约束：现有编制语义不限制容纳层级（中间层 personnel = 直属副官，§4.3 合法），
## 故不引入 tier/容量新规则。单位存活/实体存在性归 combat 域——组织侧零出向，
## personnel 中的脏 id（跨图残留/未出场）只按成员表事实处理，不查实体、不崩溃。
## 成功 = 复用既有 remove_stickman（含指挥官补位）+ assign_stickman，不复制/双写内部逻辑。
func transfer_stickman(stickman_id: String, from_org: String, to_org: String) -> Dictionary:
	var src := _get_org(from_org)
	if src == null:
		return {"ok": false, "error": "源组织不存在: %s" % from_org}
	var dst := _get_org(to_org)
	if dst == null:
		return {"ok": false, "error": "目标组织不存在: %s" % to_org}
	if from_org == to_org:
		return {"ok": false, "error": "源组织与目标组织相同，无需调动"}
	if stickman_id.is_empty() or stickman_id not in src.personnel:
		return {"ok": false, "error": "该火柴人不在源组织中: %s" % stickman_id}
	if stickman_id in dst.personnel:
		return {"ok": false, "error": "该火柴人已在目标组织中: %s" % stickman_id}
	# 预检全过 → 落地。两条既有内部路径的其余校验在预检阶段已保证通过，故不会中途失败。
	# 防御性补偿：万一 assign 失败（不可达分支），把成员放回源组织，维持"失败不改状态"契约。
	var rm := remove_stickman(from_org, stickman_id)
	if not rm.get("ok", false):
		return rm
	var add := assign_stickman(to_org, stickman_id, "")
	if not add.get("ok", false):
		assign_stickman(from_org, stickman_id, "")
		return add
	return {"ok": true, "data": {"stickman_id": stickman_id, "from_org": from_org, "to_org": to_org}}


# ===== 层级调整 =====

## 在 org 和其 parent 之间插入一个新组织
func insert_tier(org_id: String, new_org_name: String, position: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	var normalized_pos := position.to_lower()
	if not _is_valid_position(normalized_pos):
		return {"ok": false, "error": "无效的位置: %s，有效值: above/below" % position}

	var parent_id: String = org.parent_org
	if parent_id == "":
		return {"ok": false, "error": "根组织无法在其上方插入新层级"}

	var parent := _get_org(parent_id)
	if parent == null:
		return {"ok": false, "error": "父组织不存在: %s" % parent_id}

	# 计算新组织的层级
	# "above": 在 org 与其 parent 之间插入（层级必须位于两者之间）
	# "below": 在 org 之下插入（新组织成为 org 的子组织）
	var new_tier: int
	if normalized_pos == "above":
		new_tier = org.tier + 1
	else:
		new_tier = org.tier - 1

	if not _is_valid_tier(new_tier):
		return {"ok": false, "error": "插入后的层级 %d 超出有效范围" % new_tier}

	# 层级不变量：child.tier 必须 == parent.tier - 1。
	# "above" 要求新层级严格低于父层级（存在空层才可插入）；连续层级下插入必然失败，
	# 不能再制造"同级父子"（2026-08 审计修复：原实现放行 new_tier == parent.tier）。
	if normalized_pos == "above":
		if new_tier >= parent.tier:
			return {"ok": false, "error": "父组织与目标组织之间没有空层级可插入"}
	else:
		# "below"：新组织成为 org 的子级，org 成为其父级
		if not _validate_tier_relationship(org.tier, new_tier):
			return {"ok": false, "error": "插入的层级与原组织层级不连续"}

	# 创建新组织。above 时挂到原父组织；below 时挂到 org 之下（2026-08 审计修复：
	# 原实现 below 也挂到 parent_id，导致 org→new 隔代跳级）。
	var new_parent_id: String = parent_id if normalized_pos == "above" else org_id
	var new_org_id := _generate_org_id()
	var state: ScriptOrgState = _make_state(new_org_id, new_org_name, parent.tag, new_tier, new_parent_id)
	organizations[new_org_id] = state

	if normalized_pos == "above":
		state.child_orgs.append(org_id)
		org.parent_org = new_org_id
		# 更新父组织的 child_orgs（替换 org_id 为 new_org_id）
		var idx: int = parent.child_orgs.find(org_id)
		if idx != -1:
			parent.child_orgs[idx] = new_org_id
		else:
			parent.child_orgs.append(new_org_id)
	else:
		org.child_orgs.append(new_org_id)

	# 集中制：同步注册到 WorldState 容器
	if _world != null:
		_world.register_organization(state)

	return {"ok": true, "data": {"org_id": new_org_id}}


## 删除该组织，其子组织自动上挂到 parent
func remove_tier(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	var parent_id: String = org.parent_org
	if parent_id == "":
		return {"ok": false, "error": "根组织无法被删除"}

	var parent := _get_org(parent_id)
	if parent == null:
		return {"ok": false, "error": "父组织不存在: %s" % parent_id}

	# 子组织上挂到 parent（去重：避免已是 parent 直属时产生重复 child_orgs）
	for child_id in org.child_orgs:
		var child := _get_org(child_id)
		if child != null:
			child.parent_org = parent_id
			if child_id not in parent.child_orgs:
				parent.child_orgs.append(child_id)

	# 从父组织的 child_orgs 中移除
	parent.child_orgs.erase(org_id)

	# 删除组织
	organizations.erase(org_id)

	# 集中制：同步从 WorldState 容器注销
	if _world != null:
		_world.unregister_organization(org_id)

	return {"ok": true, "data": {}}


# ===== 解散 =====

## 解散组织
## [Q] 所有人员回归待分配池（personnel 清空、指挥官解除）, 子组织上挂到 parent
## [Q] 组织从容器与 WorldState 中移除（解散=终态，不留墓碑；2026-08 审计修复状态泄漏）
func disband_organization(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	# 子组织上挂到 parent（去重）
	var parent_id: String = org.parent_org
	if parent_id != "":
		var parent: ScriptOrgState = _get_org(parent_id)
		if parent != null:
			for child_id in org.child_orgs:
				var child := _get_org(child_id)
				if child != null:
					child.parent_org = parent_id
					if child_id not in parent.child_orgs:
						parent.child_orgs.append(child_id)
			parent.child_orgs.erase(org_id)

	# 人员回归待分配池：清空 personnel 与指挥官
	org.personnel.clear()
	org.commander_id = ""

	# 从容器与 WorldState 移除，避免每次编队创建/解散都累积 DISBANDED 记录
	organizations.erase(org_id)
	if _world != null:
		_world.unregister_organization(org_id)

	return {"ok": true, "data": {}}


# ===== 预设（真身在 command/org_preset_kit.gd，此处公共 API 薄壳）=====

## 加载官方预设母本，创建组织树（单根校验/挂接/回滚/返回值语义见 org_preset_kit.load_preset；
## 返回 data: {org_id=根组织, created=全部新组织 id（根在首位）}）
func load_preset(preset_name: String, parent_id: String) -> Dictionary:
	return _preset_kit.load_preset(preset_name, parent_id)


## 应用 v2 蓝图数据（export_as_preset 产物格式），创建组织树
##（模板透传/整体回滚语义见 org_preset_kit.apply_preset）
func apply_preset(data: Dictionary, parent_id: String) -> Dictionary:
	return _preset_kit.apply_preset(data, parent_id)


## 将组织及其子树导出为 v2 蓝图数据（apply_preset 可直接回灌；条目 key 为语义键、
## 不携带运行时 org_id，可 diff/可合并，见 org_preset_kit.export_as_preset）
func export_as_preset(org_id: String) -> Dictionary:
	return _preset_kit.export_as_preset(org_id)


## 列出全部预设名（presets.tres preset 字段去重，面板"从预设创建"入口数据源）
func list_preset_names() -> Array[String]:
	return _preset_kit.list_preset_names()


# ===== 批次 3：逐层指挥链（架构文档 §四，3-F1）=====

## 装配注入三 provider（实体坐标/玩家位置/跨图驻地距离）——经 api.set_transport_providers 转发
func set_transport_providers(position_provider: Callable, player_position_provider: Callable,
		region_distance_provider: Callable) -> void:
	transport_layer.setup(position_provider, player_position_provider, region_distance_provider)


## 装配注入 cmd 属性查询（补位排序用，§4.3.1）——经 api.set_attribute_provider 转发
func set_attribute_provider(provider: Callable) -> void:
	_succession_engine.set_attribute_provider(provider)


## MEDIUM 自主档伤亡上报阈值注入（balance.variables 行覆盖入口）
func set_casualty_report_threshold(threshold: float) -> void:
	_report_gate.set_casualty_report_threshold(threshold)


## 组织驻地查询（transport 内部 location provider 接线；不存在按 "" = 同驻地口径）
func _org_location(org_id: String) -> String:
	var org := _get_org(org_id)
	return org.location if org != null else ""


## 逐层投递计划（§4.1 schema：玩家跳 + BFS 层序 hops；同令透传；分解器只出结构不算时间）
func build_dispatch_plan(org_id: String, order: Dictionary) -> Dictionary:
	return command_dispatcher.build_plan(organizations, org_id, order)


# ── 补位引擎（§4.3.1，3-P 定稿；真身在 command/succession_engine.gd）──────────────────────────────
# 触发点内聚在 remove_stickman/remove_commander（被移除者 == commander 时自动补位）；
# 死亡/调离/手工撤职同一入口。伤亡是唯一的"位置事实空缺"来源（过渡态），补上的人就是真指挥官。

## 补位候选序（[{id, cmd}, ...] 按 cmd 降序，平局按池序稳定）——OrgPanel 展示/测试断言
func get_succession_candidates(org_id: String) -> Array[Dictionary]:
	return _succession_engine.get_succession_candidates(organizations, org_id)


## 补位触发薄壳（remove_stickman/remove_commander 内聚调用；细则见 succession_engine.run_succession）
func _run_succession(org: ScriptOrgState, prev_commander_id: String) -> Dictionary:
	return _succession_engine.run_succession(organizations, org, prev_commander_id, report_filed)


# ── 信息上报骨架（§4.4，P0 三 type × autonomy 三档门控；真身在 command/report_gate.gd）──────────────────
# 门控规则是组织学规则，归组织侧判定——combat 只发原始事件；
# P0 只发一层（信号载荷为发起方 org_id），逐级衰减是 P1。

## 上报门控判定（combat 挂点用法：gate 通过才 file_report；三档表细则见 report_gate）
## type: "commander_lost"（必报）/ "casualty_threshold" / "contact"；未知 type / 组织不存在 → false
func evaluate_report_gate(org_id: String, type: String, payload: Dictionary) -> bool:
	return _report_gate.evaluate_report_gate(_get_org(org_id), type, payload)


## 提交上报（combat 挂点入口；schema 校验与信号发射见 report_gate.file_report）
func file_report(org_id: String, report: Dictionary) -> void:
	_report_gate.file_report(organizations, org_id, report, report_filed)


# ===== 存档对接（2026-08 集中制：序列化格式与 WorldState 统一） =====

## 序列化全部组织数据（含 ID 计数器，避免读档后 ID 冲突）
## ⚠️ 冻结状态（2026-08-22 审计决策）：无任何调用方（organization 未注册存档接口，
## 数据经 WorldState 冻结容器序列化）。保留实现，接入存档时改走
## game_saving/game_loaded 信号直写表，勿再挂回 SaveManager.register_module 旧机制。
func get_save_data() -> Dictionary:
	var orgs: Dictionary = {}
	for org_id in organizations:
		orgs[org_id] = ScriptSerializer.organization_to_dict(organizations[org_id])
	return {
		"organizations": orgs,
		"next_id": _next_id,
	}


## 恢复组织数据（反序列化为 OrganizationState 并重新注册到 WorldState 容器）
func load_save_data(data: Dictionary) -> void:
	organizations.clear()
	var orgs: Dictionary = data.get("organizations", {})
	for org_id in orgs:
		var state: ScriptOrgState = ScriptSerializer.organization_from_dict(orgs[org_id])
		organizations[org_id] = state
		if _world != null:
			_world.register_organization(state)
	_next_id = int(data.get("next_id", 1))


## 读档收编（读档完整性批次）：把 WorldState 容器里的组织状态收编为本类工作集。
## 存档链：本类创建的组织经 register_organization 进 WorldState 容器，随 world_state
## 行落盘；读档链 WorldState._on_game_loaded 先恢复容器（game_loaded 时序保证），
## 随后 save_handler 存档恢复编排（解散旧班 → 本方法 → 重建班）经 api 调本方法收编
## ——引用同一批 OrganizationState 对象，不重序列化，此后两端读写同源。
## 先清后收：mid-session 读档时旧工作集被档内版本整体覆盖（与 WorldState 容器同语义）；
## 调用前置 = 旧班已解散（否则旧班 id 与档内组织撞车，后续解散会误删档内组织）。
## _next_id 计数器不随档（world_state 行无此字段），按现存 org_%d 最大后缀续算防新 id 冲突。
func restore_from_world_container() -> void:
	organizations.clear()
	if _world != null:
		for org_id in _world.organizations:
			var state: Variant = _world.organizations[org_id]
			if state is ScriptOrgState:
				organizations[String(org_id)] = state
	_recompute_next_id()


## 按现存组织 id（org_%d）最大后缀续算 ID 计数器（无后缀/非数字 id 不参与）。
func _recompute_next_id() -> void:
	var max_suffix := 0
	for org_id in organizations:
		var suffix := String(org_id).trim_prefix("org_").to_int()
		if suffix > max_suffix:
			max_suffix = suffix
	_next_id = max_suffix + 1


## 整表重设成员（读档完整性批次）：清旧表后逐个写入。供编队恢复重建人员账——
## 档内 personnel 存的是存档时旧 iid（跨会话已死），按恢复后的活实体重写；
## 绕过 remove_stickman 的补位引擎（重写账面不是人员变动，不触发继任）。
## 未知组织 = {ok: false}；重复/空 id 去重（沿用 assign 防双挂语义）。
func set_personnel(org_id: String, stickman_ids: Array) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.personnel.clear()
	for sid_v in stickman_ids:
		var sid := str(sid_v)
		if not sid.is_empty() and sid not in org.personnel:
			org.personnel.append(sid)
	return {"ok": true, "data": {"count": org.personnel.size()}}
