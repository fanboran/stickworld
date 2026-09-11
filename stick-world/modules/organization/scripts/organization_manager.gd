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
	"MILITARY", "RESEARCH", "ENGINEERING", "ADMINISTRATION", "COMMERCE", "LABOR", "LOGISTICS"
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

const TAG_TO_ENUM := {
	"MILITARY": ScriptOrgState.Tag.MILITARY,
	"RESEARCH": ScriptOrgState.Tag.RESEARCH,
	"ENGINEERING": ScriptOrgState.Tag.ENGINEERING,
	"ADMINISTRATION": ScriptOrgState.Tag.ADMINISTRATION,
	"COMMERCE": ScriptOrgState.Tag.COMMERCE,
	"LABOR": ScriptOrgState.Tag.LABOR,
	"LOGISTICS": ScriptOrgState.Tag.LOGISTICS,
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


# ===== 预设 =====

## 预设层级树配置（官方母本蓝图：军事编制/科研架构/工程架构/行政架构/运输架构）
const PRESET_CONFIG_PATH := "res://config/formations/presets.tres"

## Tag 枚举 → 字符串（export_as_preset 序列化用，与 TAG_TO_ENUM 互逆）
const ENUM_TO_TAG := {
	ScriptOrgState.Tag.MILITARY: "MILITARY",
	ScriptOrgState.Tag.RESEARCH: "RESEARCH",
	ScriptOrgState.Tag.ENGINEERING: "ENGINEERING",
	ScriptOrgState.Tag.ADMINISTRATION: "ADMINISTRATION",
	ScriptOrgState.Tag.COMMERCE: "COMMERCE",
	ScriptOrgState.Tag.LABOR: "LABOR",
	ScriptOrgState.Tag.LOGISTICS: "LOGISTICS",
}


## AutonomyLevel 枚举 → 字符串（export_as_preset 序列化用，与 AUTONOMY_TO_ENUM 互逆）
const AUTONOMY_TO_STR := {
	ScriptOrgState.AutonomyLevel.HIGH: "HIGH",
	ScriptOrgState.AutonomyLevel.MEDIUM: "MEDIUM",
	ScriptOrgState.AutonomyLevel.LOW: "LOW",
}


## 加载官方预设母本，创建组织树（presets.tres 按条目 preset 字段过滤，装载时归一为 v2 条目）。
## 挂接/回滚/返回值语义同 apply_preset。返回 data: {org_id=根组织, created=全部新组织 id（根在首位）}
func load_preset(preset_name: String, parent_id: String) -> Dictionary:
	var loaded := _load_preset_rows(preset_name)
	if not loaded.get("ok", false):
		return loaded
	return _instantiate_preset({"name": preset_name, "tag": "", "entries": loaded.data.entries}, parent_id)


## 应用 v2 蓝图数据（export_as_preset 产物格式），创建组织树。
## parent_id = "" 时创建独立根树（按蓝图标称层级）；指定 parent 时须蓝图顶层
## level == parent.tier - 1（不做层级平移——平移会让"师"落到连级，语义错乱）。
## 条目模板字段（personnel_template/equipment_template/autonomy/default_behavior）透传到新组织；
## 实例字段（personnel/commander_id/location 等）不属于蓝图，永不导入。
## 中途失败回滚已创建组织（整体成功或整体失败）。
func apply_preset(data: Dictionary, parent_id: String) -> Dictionary:
	var err := _validate_preset_data(data)
	if err != "":
		return {"ok": false, "error": err}
	return _instantiate_preset(data, parent_id)


## 预设实例化主体（load_preset / apply_preset 共用，输入已归一为 v2 条目）
func _instantiate_preset(preset_data: Dictionary, parent_id: String) -> Dictionary:
	var entries: Array = preset_data.get("entries", [])
	var root_tag := String(preset_data.get("tag", ""))

	# 单根校验 + 条目 key 集（顶层 = parent_key 为空或不在条目集内）
	var keys := {}
	for e in entries:
		keys[String(e.get("key", ""))] = true
	var roots: Array = []
	for e in entries:
		var pk := String(e.get("parent_key", ""))
		if pk == "" or not keys.has(pk):
			roots.append(e)
	if roots.size() != 1:
		return {"ok": false, "error": "预设必须是单根树，实际顶层条目 %d 个" % roots.size()}
	if root_tag == "":
		root_tag = String(roots[0].get("tag", ""))
	if root_tag == "":
		return {"ok": false, "error": "预设缺少标签（data.tag 与顶层条目 tag 均为空）"}

	# 挂接校验
	if parent_id != "":
		var parent := _get_org(parent_id)
		if parent == null:
			return {"ok": false, "error": "父组织不存在: %s" % parent_id}
		var root_level := int(roots[0].get("level", 0))
		if root_level != parent.tier - 1:
			return {"ok": false, "error": "预设顶层层级 %d 与父组织层级 %d 不衔接（须为 parent.tier-1=%d）" % [root_level, parent.tier, parent.tier - 1]}

	# 按 level 降序创建（层级严格递减的树中父必先于子；同层按原顺序稳定）
	var order_index := {}
	for i in entries.size():
		order_index[entries[i]] = i
	var ordered: Array = entries.duplicate()
	ordered.sort_custom(func(a, b):
		var la := int(a.get("level", 0))
		var lb := int(b.get("level", 0))
		if la != lb:
			return la > lb
		return order_index[a] < order_index[b])

	var key_map := {}   # 预设条目 key -> 新 org_id
	var created: Array[String] = []
	var failure := ""   # 非空 = 创建中断原因，统一走回滚出口
	for e in ordered:
		if failure != "":
			break
		var pk := String(e.get("parent_key", ""))
		var new_parent: String
		if pk == "" or not keys.has(pk):
			new_parent = parent_id
		elif key_map.has(pk):
			new_parent = String(key_map[pk])
		else:
			# 父条目尚未创建（数据断链，如子级 level >= 父级）——不可建，整体失败
			failure = "条目 %s 的父条目 %s 未创建（层级断链）" % [String(e.get("key")), pk]
			break
		var r := create_organization(String(e.get("name", "未命名")), String(e.get("tag", root_tag)), int(e.get("level", 1)), new_parent)
		if r.get("ok", false):
			key_map[String(e.get("key", ""))] = r.data.org_id
			created.append(r.data.org_id)
			# 模板字段透传（实例字段不属于蓝图，不导入）
			var st := _get_org(r.data.org_id)
			var tmpl: Variant = e.get("personnel_template", {})
			st.personnel_template = tmpl.duplicate() if tmpl is Dictionary else {}
			var equip: Variant = e.get("equipment_template", {})
			st.equipment_template = equip.duplicate() if equip is Dictionary else {}
			var behav: Variant = e.get("default_behavior", {})
			st.default_behavior = behav.duplicate() if behav is Dictionary else {}
			st.autonomy_level = AUTONOMY_TO_ENUM.get(String(e.get("autonomy", "MEDIUM")).to_upper(), ScriptOrgState.AutonomyLevel.MEDIUM)
		else:
			failure = str(r.get("error", ""))

	if failure != "":
		for i in range(created.size() - 1, -1, -1):
			disband_organization(created[i])
		return {"ok": false, "error": "预设创建中断（已回滚）: %s" % failure}

	return {"ok": true, "data": {"org_id": created[0], "created": created}}


## 将组织及其子树导出为 v2 蓝图数据（apply_preset 可直接回灌）。
## 格式：{name, tag, entries=[{key, name, level, tag, parent_key, 模板字段...}]}
## 条目 key 为导出时重编的语义键（"n1","n2"... 先根序）——蓝图不携带运行时 org_id，
## 可 diff/可合并（构筑谱系/UGC 前提）；实例字段（成员/指挥官/驻地）不导。
func export_as_preset(org_id: String) -> Dictionary:
	var org := _get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	# 第一遍：先根序收集 (org, parent_org_id)，分配语义键
	var flat: Array = []
	_collect_flat(org, "", flat)
	var key_of := {}   # org_id -> 语义键
	for i in flat.size():
		key_of[flat[i]["org"].id] = "n%d" % (i + 1)
	# 第二遍：产 v2 条目（parent_key 经映射；根为空）
	var entries: Array = []
	for item in flat:
		var o: ScriptOrgState = item["org"]
		entries.append({
			"key": key_of[o.id],
			"name": o.name,
			"level": o.tier,
			"tag": ENUM_TO_TAG.get(o.tag, ""),
			"parent_key": "" if item["parent"] == "" else String(key_of[item["parent"]]),
			"personnel_template": o.personnel_template.duplicate(),
			"equipment_template": o.equipment_template.duplicate(),
			"autonomy": AUTONOMY_TO_STR.get(o.autonomy_level, "MEDIUM"),
			"default_behavior": o.default_behavior.duplicate(),
		})
	return {"ok": true, "data": {"name": org.name, "tag": ENUM_TO_TAG.get(org.tag, ""), "entries": entries}}


## 先根序收集子树 (org, parent_org_id) 扁平表（兄弟顺序 = child_orgs 顺序）
func _collect_flat(org: ScriptOrgState, parent_id: String, flat: Array) -> void:
	flat.append({"org": org, "parent": parent_id})
	for child_id in org.child_orgs:
		var child := _get_org(child_id)
		if child != null:
			_collect_flat(child, org.id, flat)


## 从 presets.tres 按预设名取条目，归一为 v2 形态（母本行字段 id/parent_id 映射为 key/parent_key）
func _load_preset_rows(preset_name: String) -> Dictionary:
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not (res is BalanceResource):
		return {"ok": false, "error": "预设配置加载失败: %s" % PRESET_CONFIG_PATH}
	var rows := BalanceResource.sanitized_rows(res)
	var entries: Array = []
	var available: PackedStringArray = []
	for row in rows:
		var pname := String(row.get("preset", ""))
		if pname != "" and pname not in available:
			available.append(pname)
		if pname == preset_name:
			entries.append({
				"key": String(row.get("id", "")),
				"name": String(row.get("name", "")),
				"level": int(row.get("level", 0)),
				"tag": String(row.get("tag", "")),
				"parent_key": String(row.get("parent_id", "")),
			})
	if entries.is_empty():
		return {"ok": false, "error": "未知预设: %s（可用: %s）" % [preset_name, ", ".join(available)]}
	return {"ok": true, "data": {"entries": entries}}


## 列出全部预设名（presets.tres preset 字段去重，面板"从预设创建"入口数据源）
func list_preset_names() -> Array[String]:
	var names: Array[String] = []
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not (res is BalanceResource):
		return names
	for row in BalanceResource.sanitized_rows(res):
		var pname := String(row.get("preset", ""))
		if pname != "" and pname not in names:
			names.append(pname)
	return names


## 校验 v2 蓝图数据的结构（单根在 _instantiate_preset 校验；此处验条目字段完备）
func _validate_preset_data(data: Dictionary) -> String:
	var entries: Variant = data.get("entries", null)
	if entries == null or not (entries is Array) or (entries as Array).is_empty():
		return "预设数据缺少非空 entries 数组"
	for e in entries:
		if not (e is Dictionary):
			return "预设条目须为 Dictionary"
		if String(e.get("key", "")) == "":
			return "预设条目缺少 key"
		if int(e.get("level", 0)) < TIER_MIN or int(e.get("level", 0)) > TIER_MAX:
			return "预设条目 %s 层级 %s 超出 %d-%d 范围" % [String(e.get("key")), String(e.get("level")), TIER_MIN, TIER_MAX]
	return ""


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
