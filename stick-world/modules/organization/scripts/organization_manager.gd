extends RefCounted
class_name OrganizationManager
## 组织模块内部管理逻辑类
##
## api.gd 委派实际实现到此。
## 管理组织的 CRUD、层级校验、编制配置、人事任免等核心逻辑。
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
	"MILITARY", "RESEARCH", "ENGINEERING", "ADMINISTRATION", "COMMERCE", "LABOR"
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

const TAG_TO_ENUM := {
	"MILITARY": ScriptOrgState.Tag.MILITARY,
	"RESEARCH": ScriptOrgState.Tag.RESEARCH,
	"ENGINEERING": ScriptOrgState.Tag.ENGINEERING,
	"ADMINISTRATION": ScriptOrgState.Tag.ADMINISTRATION,
	"COMMERCE": ScriptOrgState.Tag.COMMERCE,
	"LABOR": ScriptOrgState.Tag.LABOR,
}

const AUTONOMY_TO_ENUM := {
	"HIGH": ScriptOrgState.AutonomyLevel.HIGH,
	"MEDIUM": ScriptOrgState.AutonomyLevel.MEDIUM,
	"LOW": ScriptOrgState.AutonomyLevel.LOW,
}


# ===== 内部数据结构 =====

## 所有组织数据，key = org_id, value = OrganizationState
var organizations: Dictionary = {}

## 组织 ID 自增计数器
var _next_id: int = 1

## WorldState 容器引用（2026-08 集中制：由 api.setup 注入，null 时跳过容器同步，仅测试/独立使用）
var _world: Node = null


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
	return state


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
	return {"ok": true, "data": ScriptWorldState._organization_to_dict(org)}


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


# ===== 人事 =====

## 任命指挥官
func assign_commander(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.commander_id = stickman_id
	return {"ok": true, "data": {}}


## 撤除指挥官
func remove_commander(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.commander_id = ""
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
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if stickman_id not in org.personnel:
		return {"ok": false, "error": "该火柴人不在组织中: %s" % stickman_id}
	org.personnel.erase(stickman_id)
	return {"ok": true, "data": {}}


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
	# "above": 新组织层级 = org.tier + 1（更接近 parent）
	# "below": 新组织层级 = org.tier - 1（更远离 parent）
	var new_tier: int
	if normalized_pos == "above":
		new_tier = org.tier + 1
	else:
		new_tier = org.tier - 1

	if not _is_valid_tier(new_tier):
		return {"ok": false, "error": "插入后的层级 %d 超出有效范围" % new_tier}

	# 校验层级连续性（2026-08 修复：原 above 校验要求 new_tier == parent.tier - 1，
	# 而 new_tier = org.tier + 1，连续层级下 parent.tier = org.tier + 1，
	# 导致 above 分支恒失败——改为"不高于父层级 + 与原组织连续"）
	if normalized_pos == "above":
		if new_tier > parent.tier:
			return {"ok": false, "error": "插入的层级不能高于父组织"}
		if not _validate_tier_relationship(new_tier, org.tier):
			return {"ok": false, "error": "插入的层级与原组织层级不连续"}
	else:
		if not _validate_tier_relationship(org.tier, new_tier):
			return {"ok": false, "error": "插入的层级与原组织层级不连续"}

	# 创建新组织
	var new_org_id := _generate_org_id()
	var state: ScriptOrgState = _make_state(new_org_id, new_org_name, parent.tag, new_tier, parent_id)
	state.child_orgs.append(org_id)
	organizations[new_org_id] = state

	# 更新原组织的 parent
	org.parent_org = new_org_id

	# 更新父组织的 child_orgs（替换 org_id 为 new_org_id）
	var idx: int = parent.child_orgs.find(org_id)
	if idx != -1:
		parent.child_orgs[idx] = new_org_id
	else:
		parent.child_orgs.append(new_org_id)

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

	# 子组织上挂到 parent
	for child_id in org.child_orgs:
		var child := _get_org(child_id)
		if child != null:
			child.parent_org = parent_id
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
func disband_organization(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	# 子组织上挂到 parent
	var parent_id: String = org.parent_org
	if parent_id != "":
		var parent: ScriptOrgState = _get_org(parent_id)
		if parent != null:
			for child_id in org.child_orgs:
				var child := _get_org(child_id)
				if child != null:
					child.parent_org = parent_id
					parent.child_orgs.append(child_id)
			parent.child_orgs.erase(org_id)

	# 人员回归待分配池：清空 personnel 与指挥官
	org.personnel.clear()
	org.commander_id = ""

	# 标记为已解散
	org.state = ScriptOrgState.State.DISBANDED

	return {"ok": true, "data": {}}


# ===== 预设 =====

## 加载预设模板，创建组织树
func load_preset(preset_name: String, _parent_id: String) -> Dictionary:
	# 骨架阶段：返回预设未实现
	return {"ok": false, "error": "预设系统尚未实现: %s" % preset_name}


## 将组织及其子树导出为预设
func export_as_preset(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	# 骨架阶段：返回组织数据的序列化副本作为预设数据
	return {"ok": true, "data": ScriptWorldState._organization_to_dict(org)}


# ===== 存档对接（2026-08 集中制：序列化格式与 WorldState 统一） =====

## 序列化全部组织数据（含 ID 计数器，避免读档后 ID 冲突）
func get_save_data() -> Dictionary:
	var orgs: Dictionary = {}
	for org_id in organizations:
		orgs[org_id] = ScriptWorldState._organization_to_dict(organizations[org_id])
	return {
		"organizations": orgs,
		"next_id": _next_id,
	}


## 恢复组织数据（反序列化为 OrganizationState 并重新注册到 WorldState 容器）
func load_save_data(data: Dictionary) -> void:
	organizations.clear()
	var orgs: Dictionary = data.get("organizations", {})
	for org_id in orgs:
		var state: ScriptOrgState = ScriptWorldState._organization_from_dict(orgs[org_id])
		organizations[org_id] = state
		if _world != null:
			_world.register_organization(state)
	_next_id = int(data.get("next_id", 1))
