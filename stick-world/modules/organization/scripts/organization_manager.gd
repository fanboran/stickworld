extends RefCounted
class_name OrganizationManager
## 组织模块内部管理逻辑类
##
## api.gd 委派实际实现到此。
## 管理组织的 CRUD、层级校验、编制配置、人事任免等核心逻辑。

# ===== 常量 =====

## 有效层级范围
const TIER_MIN: int = 1
const TIER_MAX: int = 5

## 有效标签
const VALID_TAGS: Array[String] = [
	"MILITARY", "RESEARCH", "ENGINEERING", "ADMINISTRATION", "COMMERCE"
]

## 有效自主权限级别
const VALID_AUTONOMY_LEVELS: Array[String] = [
	"HIGH", "MEDIUM", "LOW"
]

## 有效插入位置
const VALID_POSITIONS: Array[String] = [
	"above", "below"
]


# ===== 内部数据结构 =====

## 所有组织数据，key = org_id, value = Dictionary
var organizations: Dictionary = {}

## 所有项目数据，key = project_id, value = Dictionary
var projects: Dictionary = {}

## 组织 ID 自增计数器
var _next_id: int = 1


# ===== 工具方法 =====

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


## 获取组织数据，不存在则返回 null
func _get_org(org_id: String) -> Dictionary:
	return organizations.get(org_id, {})


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
		if parent.is_empty():
			return {"ok": false, "error": "父组织不存在: %s" % parent_id}
		if not _validate_tier_relationship(parent.tier, tier):
			return {"ok": false, "error": "子组织层级必须比父组织低一级"}

	var org_id := _generate_org_id()
	organizations[org_id] = {
		"id": org_id,
		"name": name,
		"tag": tag,
		"tier": tier,
		"parent_org": parent_id if parent_id != "" else "",
		"child_orgs": [],
		"commander_id": "",
		"personnel": [],
		"personnel_template": {},
		"equipment_template": {},
		"autonomy_level": "MEDIUM",
		"default_behavior": {},
		"supply_priority": "MEDIUM",
		"morale_threshold": 0.0,
		"current_project": "",
		"location": "",
		"state": "FORMING"
	}

	# 关联父组织
	if parent_id != "":
		var parent: Dictionary = organizations[parent_id]
		parent.child_orgs.append(org_id)

	return {"ok": true, "data": {"org_id": org_id}}


## 获取组织数据
func get_organization(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	return {"ok": true, "data": org.duplicate(true)}


## 获取下级组织 ID 列表
func get_child_orgs(org_id: String) -> Array[String]:
	var org := _get_org(org_id)
	if org.is_empty():
		return []
	return org.child_orgs.duplicate()


## 按标签查询组织
func get_orgs_by_tag(tag: String) -> Array[String]:
	if not _is_valid_tag(tag):
		return []
	var result: Array[String] = []
	for org_id in organizations:
		if organizations[org_id].tag == tag:
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
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.personnel_template = template.duplicate()
	return {"ok": true, "data": {}}


## 设置装备模板
func set_equipment_template(org_id: String, template: Dictionary) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.equipment_template = template.duplicate()
	return {"ok": true, "data": {}}


## 设置自主决策权限
func set_autonomy(org_id: String, level: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	var normalized := level.to_upper()
	if not _is_valid_autonomy_level(normalized):
		return {"ok": false, "error": "无效的自主权限级别: %s，有效值: high/medium/low" % level}
	org.autonomy_level = normalized
	return {"ok": true, "data": {}}


## 设置默认行为
func set_default_behavior(org_id: String, behavior: Dictionary) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.default_behavior = behavior.duplicate()
	return {"ok": true, "data": {}}


# ===== 人事 =====

## 任命指挥官
func assign_commander(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.commander_id = stickman_id
	return {"ok": true, "data": {}}


## 撤除指挥官
func remove_commander(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	org.commander_id = ""
	return {"ok": true, "data": {}}


## 分配火柴人到组织
func assign_stickman(org_id: String, stickman_id: String, role: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if stickman_id in org.personnel:
		return {"ok": false, "error": "该火柴人已在组织中: %s" % stickman_id}
	org.personnel.append(stickman_id)
	return {"ok": true, "data": {}}


## 从组织移除火柴人
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	if stickman_id not in org.personnel:
		return {"ok": false, "error": "该火柴人不在组织中: %s" % stickman_id}
	org.personnel.erase(stickman_id)
	return {"ok": true, "data": {}}


# ===== 层级调整 =====

## 在 org 和其 parent 之间插入一个新组织
func insert_tier(org_id: String, new_org_name: String, position: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	var normalized_pos := position.to_lower()
	if not _is_valid_position(normalized_pos):
		return {"ok": false, "error": "无效的位置: %s，有效值: above/below" % position}

	var parent_id: String = org.parent_org
	if parent_id == "":
		return {"ok": false, "error": "根组织无法在其上方插入新层级"}

	var parent := _get_org(parent_id)
	if parent.is_empty():
		return {"ok": false, "error": "父组织不存在: %s" % parent_id}

	# 计算新组织的层级
	# "above": 新组织层级 = parent.tier（与父同级，但作为父的兄弟？）
	# 实际上 insert_tier 是在 org 和 parent 之间插入
	# 所以新组织的 tier 应该 = parent.tier - 1（即 org.tier + 1）
	# 但需要校验连续性
	var new_tier: int
	if normalized_pos == "above":
		# 插入到 org 之上：新组织层级 = org.tier + 1（更接近 parent）
		new_tier = org.tier + 1
	else:
		# 插入到 org 之下：新组织层级 = org.tier - 1（更远离 parent）
		new_tier = org.tier - 1

	if not _is_valid_tier(new_tier):
		return {"ok": false, "error": "插入后的层级 %d 超出有效范围" % new_tier}

	# 校验层级连续性
	if normalized_pos == "above":
		if not _validate_tier_relationship(parent.tier, new_tier):
			return {"ok": false, "error": "插入的层级与父组织层级不连续"}
		if not _validate_tier_relationship(new_tier, org.tier):
			return {"ok": false, "error": "插入的层级与原组织层级不连续"}
	else:
		if not _validate_tier_relationship(org.tier, new_tier):
			return {"ok": false, "error": "插入的层级与原组织层级不连续"}

	# 创建新组织
	var new_org_id := _generate_org_id()
	organizations[new_org_id] = {
		"id": new_org_id,
		"name": new_org_name,
		"tag": parent.tag,
		"tier": new_tier,
		"parent_org": parent_id,
		"child_orgs": [org_id],
		"commander_id": "",
		"personnel": [],
		"personnel_template": {},
		"equipment_template": {},
		"autonomy_level": "MEDIUM",
		"default_behavior": {},
		"supply_priority": "MEDIUM",
		"morale_threshold": 0.0,
		"current_project": "",
		"location": "",
		"state": "FORMING"
	}

	# 更新原组织的 parent
	org.parent_org = new_org_id

	# 更新父组织的 child_orgs（替换 org_id 为 new_org_id）
	var idx: int = parent.child_orgs.find(org_id)
	if idx != -1:
		parent.child_orgs[idx] = new_org_id
	else:
		parent.child_orgs.append(new_org_id)

	return {"ok": true, "data": {"org_id": new_org_id}}


## 删除该组织，其子组织自动上挂到 parent
func remove_tier(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	var parent_id: String = org.parent_org
	if parent_id == "":
		return {"ok": false, "error": "根组织无法被删除"}

	var parent := _get_org(parent_id)
	if parent.is_empty():
		return {"ok": false, "error": "父组织不存在: %s" % parent_id}

	# 子组织上挂到 parent
	for child_id in org.child_orgs:
		var child := _get_org(child_id)
		if not child.is_empty():
			child.parent_org = parent_id
			parent.child_orgs.append(child_id)

	# 从父组织的 child_orgs 中移除
	parent.child_orgs.erase(org_id)

	# 删除组织
	organizations.erase(org_id)

	return {"ok": true, "data": {}}


# ===== 解散 =====

## 解散组织
func disband_organization(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}

	# 子组织上挂到 parent
	var parent_id: String = org.parent_org
	if parent_id != "":
		var parent: Dictionary = _get_org(parent_id)
		if not parent.is_empty():
			for child_id in org.child_orgs:
				var child := _get_org(child_id)
				if not child.is_empty():
					child.parent_org = parent_id
					parent.child_orgs.append(child_id)
			parent.child_orgs.erase(org_id)

	# 标记为已解散
	org.state = "DISBANDED"

	return {"ok": true, "data": {}}


# ===== 预设 =====

## 加载预设模板，创建组织树
func load_preset(preset_name: String, parent_id: String) -> Dictionary:
	# 骨架阶段：返回预设未实现
	return {"ok": false, "error": "预设系统尚未实现: %s" % preset_name}


## 将组织及其子树导出为预设
func export_as_preset(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org.is_empty():
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	# 骨架阶段：返回组织数据的浅拷贝作为预设数据
	return {"ok": true, "data": org.duplicate(true)}
