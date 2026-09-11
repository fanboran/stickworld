extends Node
## organization 模块公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 organization 内部脚本的方法。
##
## 组织是游戏最核心的系统——五层级通用管理单元。
## 军队、科学院、工程队、行政体系、商队共享同一套底层逻辑。

# ===== 公共信号 =====

## 组织创建完成
signal org_created(org_id: String)

## 组织编制/结构变更
signal org_restructured(org_id: String)

## 组织已解散
signal org_disbanded(org_id: String)


# ===== 内部引用（在 _setup 中绑定） =====

var _manager: OrganizationManager
var _is_initialized: bool = false


# ===== 初始化 =====

## 注入内部管理器引用（Node 签名，2026-08 审计收敛）
func setup(manager: Object) -> void:
	_manager = manager as OrganizationManager
	_is_initialized = true
	# 2026-08 集中制（WorldState 容器决策 A）：组织状态注册进 WorldState 容器，
	# 存档由 WorldState 统一序列化（本模块不再自行注册 SaveManager）
	if WorldState != null and manager.has_method("set_world"):
		manager.set_world(WorldState)


# ===== 存档对接（保留转发，当前由 WorldState 统一落盘，此处仅防御性可用） =====

## 序列化全部组织数据（SaveManager 调用）
func get_save_data() -> Dictionary:
	if not _is_initialized:
		return {}
	return _manager.get_save_data()


## 恢复组织数据（SaveManager 调用）
func load_save_data(data: Dictionary) -> void:
	if _is_initialized:
		_manager.load_save_data(data)


# ===== 创建/查询 =====

## 创建一个新组织
## [P] tier 必须在 1-5 范围内, tag 有效, parent 的 tier = tier+1（若存在）
## [Q] 发射 org_created
func create_organization(org_name: String, tag: String, tier: int, parent_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.create_organization(org_name, tag, tier, parent_id)
	if result.get("ok", false):
		org_created.emit(result.data.org_id)
	return result


## 获取组织数据
func get_organization(org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.get_organization(org_id)


## 获取下级组织 ID 列表
func get_child_orgs(org_id: String) -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_child_orgs(org_id)


## 按标签查询组织
func get_orgs_by_tag(tag: String) -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_orgs_by_tag(tag)


## 查询某个地块内的所有组织
func get_orgs_in_region(region_id: String) -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_orgs_in_region(region_id)


## 列出全部根组织（森林多根；OrgPanel 树构建入口）
func list_root_orgs() -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.list_root_orgs()


## 改名（GDD §3.3 命名可改）
## [Q] 成功发射 org_restructured（树节点文案含名称，属可见结构信息）
func set_org_name(org_id: String, new_name: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.set_org_name(org_id, new_name)
	if result.get("ok", false):
		org_restructured.emit(org_id)
	return result


## 列出全部预设名（"从预设创建"入口数据源）
func list_preset_names() -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.list_preset_names()


# ===== 编制管理 =====

## 设置人员编制模板
## template 如 {"rifleman": 4, "machine_gunner": 1, "mage": 1}
## [Q] 发射 org_restructured
func set_personnel_template(org_id: String, template: Dictionary) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.set_personnel_template(org_id, template)
	if result.get("ok", false):
		org_restructured.emit(org_id)
	return result


## 设置装备模板
func set_equipment_template(org_id: String, template: Dictionary) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.set_equipment_template(org_id, template)
	if result.get("ok", false):
		org_restructured.emit(org_id)
	return result


## 设置自主决策权限
## level: "high" / "medium" / "low"
func set_autonomy(org_id: String, level: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.set_autonomy(org_id, level)


## 设置默认行为（无指令时的自动行为）
func set_default_behavior(org_id: String, behavior: Dictionary) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.set_default_behavior(org_id, behavior)


# ===== 人事 =====

## 任命指挥官
func assign_commander(org_id: String, stickman_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.assign_commander(org_id, stickman_id)


## 撤除指挥官
func remove_commander(org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.remove_commander(org_id)


## 分配火柴人到组织
func assign_stickman(org_id: String, stickman_id: String, role: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.assign_stickman(org_id, stickman_id, role)


## 从组织移除火柴人
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.remove_stickman(org_id, stickman_id)


# ===== 层级调整 =====

## 在 org 和其 parent 之间插入一个新组织
## position: "above"（插入到 org 之上）/ "below"（插入到 org 之下）
## [Q] 成功时发射 org_created（新节点）+ org_restructured（父结构变化）
func insert_tier(org_id: String, new_org_name: String, position: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.insert_tier(org_id, new_org_name, position)
	if result.get("ok", false):
		org_created.emit(result.data.org_id)
		org_restructured.emit(org_id)
	return result


## 删除该组织，其子组织自动上挂到 parent
## [Q] 成功时发射 org_restructured（子组织上挂 = 结构变化）
func remove_tier(org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.remove_tier(org_id)
	if result.get("ok", false):
		org_restructured.emit(org_id)
	return result


# ===== 解散 =====

## 解散组织
## [Q] 所有人员回归待分配池, 子组织上挂到 parent, 发射 org_disbanded
func disband_organization(org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.disband_organization(org_id)
	if result.get("ok", false):
		org_disbanded.emit(org_id)
	return result


# ===== 预设 =====

## 加载官方预设母本，创建组织树（presets.tres：军事编制/科研架构/工程架构/行政架构/运输架构）
## parent_id = "" 创建独立根树；指定 parent 时须预设顶层 level == parent.tier - 1
## [Q] 每创建一个组织发射一次 org_created（data.created 列出全部新组织 id）
func load_preset(preset_name: String, parent_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.load_preset(preset_name, parent_id)
	if result.get("ok", false):
		for org_id in result.data.created:
			org_created.emit(org_id)
	return result


## 应用 v2 蓝图数据（export_as_preset 产物格式）创建组织树。
## 条目模板字段（编制/装备/权限/默认行为）透传；实例字段（成员/指挥官）不导入。
## 挂接/回滚/信号语义同 load_preset
func apply_preset(data: Dictionary, parent_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.apply_preset(data, parent_id)
	if result.get("ok", false):
		for org_id in result.data.created:
			org_created.emit(org_id)
	return result


## 将组织及其子树导出为 v2 蓝图数据
## 返回 data: {name, tag, entries=[{key, name, level, tag, parent_key, 模板字段}]}，
## 条目 key 为语义键（无运行时 org_id），可直接回灌 apply_preset；UGC 文件化挂后续任务
func export_as_preset(org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.export_as_preset(org_id)
