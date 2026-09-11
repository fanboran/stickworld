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

## 上报已提交（§4.4 信息上报骨架：combat 挂点经 evaluate_report_gate 门控后 file_report；
## 补位引擎 commander_lost 必报也走此信号。P0 一层直报，消费方自取 parent_org 归档）
signal report_filed(org_id: String, report: Dictionary)


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
	# manager 内部发射的上报（补位引擎 commander_lost 必报）转发到公共信号
	if _manager != null:
		_manager.report_filed.connect(report_filed.emit)
	_apply_balance_variables()


## balance.variables 指挥链三行覆盖（缺行零回归——transport/manager 代码默认值已就位）
const BALANCE_VARIABLES_PATH := "res://config/balance/variables.tres"

func _apply_balance_variables() -> void:
	var res: Resource = load(BALANCE_VARIABLES_PATH)
	if res == null or not "variables" in res:
		return
	for row in res.get("variables").get("data", []):
		match String(row.get("id", "")):
			"var_courier_speed":
				_manager.transport_layer.set_courier_speed(float(row.get("value", 208.0)))
			"var_command_cross_map_distance":
				_manager.transport_layer.set_fallback_distance(float(row.get("value", 2000.0)))
			"var_report_casualty_threshold":
				_manager.set_casualty_report_threshold(float(row.get("value", 0.30)))


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


# ===== 批次 3：逐层指挥链（架构文档 §四）=====

## 生成逐层投递计划（§4.1 schema：hop 0 玩家跳 + BFS 层序展开到 L1；同令透传）
## data: {root_org, leaf_orgs, hops}；错误："org_not_found" / "no_subordinate"
func build_dispatch_plan(org_id: String, order: Dictionary) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.build_dispatch_plan(org_id, order)


## 一跳传播秒数（传输层 v1 §4.2：距离÷媒介速度；层级数不直接生延迟）
## combat 接力执行消费（3-F2 issue_to_org 逐跳计时）；未装配 provider 时退化跨图/同驻地口径
func get_delivery_time(from_org: String, to_org: String) -> float:
	if not _is_initialized:
		return 0.0
	return _manager.transport_layer.delivery_time(from_org, to_org)


## 装配注入传输层三 provider（3-F2 system_setup 接线）：
## position_provider(org_id)->Vector2|INF、player_position_provider()->Vector2、
## region_distance_provider(from_loc, to_loc)->float|-1
func set_transport_providers(position_provider: Callable, player_position_provider: Callable,
		region_distance_provider: Callable) -> void:
	if _is_initialized:
		_manager.set_transport_providers(position_provider, player_position_provider, region_distance_provider)


## 装配注入 cmd 属性查询（补位排序用，§4.3.1）：stickman_id -> float，失败返回 -1 沉底
func set_attribute_provider(provider: Callable) -> void:
	if _is_initialized:
		_manager.set_attribute_provider(provider)


## 补位候选序（§4.3.1）：[{id, cmd}, ...] 按 cmd 降序（平局按池序）——面板展示/测试断言
func get_succession_candidates(org_id: String) -> Array[Dictionary]:
	if not _is_initialized:
		return []
	return _manager.get_succession_candidates(org_id)


## 上报门控判定（§4.4 三档表）：commander_lost 必报恒 true；HIGH 不报 casualty/contact；
## MEDIUM casualty 按存活比阈值；LOW 全量。combat 挂点用法：gate 通过才 file_report
func evaluate_report_gate(org_id: String, type: String, payload: Dictionary) -> bool:
	if not _is_initialized:
		return false
	return _manager.evaluate_report_gate(org_id, type, payload)


## 提交上报（combat 挂点入口；内部校验 schema 后发 report_filed，组织侧只透传不解释）
func file_report(org_id: String, report: Dictionary) -> void:
	if _is_initialized:
		_manager.file_report(org_id, report)
