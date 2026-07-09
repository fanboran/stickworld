extends Node
## technology 模块公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 technology 内部脚本的方法。
##
## 科技系统管理科技的解锁、研究进度、研究员分配。
## 研究由带有 RESEARCH 标签的组织驱动。

# ===== 公共信号 =====

## 科技研究已开始
signal tech_started(tech_id: String)

## 科技研究已暂停
signal tech_paused(tech_id: String)

## 科技研究已恢复
signal tech_resumed(tech_id: String)

## 科技研究完成
signal tech_completed(tech_id: String)


# ===== 内部引用（在 setup 中绑定） =====

var _manager  ## TechnologyManager 引用
var _is_initialized: bool = false


# ===== 初始化 =====

## 注入内部管理器引用
func setup(manager) -> void:
	_manager = manager
	_is_initialized = true


# ===== 研究 =====

## 开始研究一项科技
## [P] tech 状态=AVAILABLE, org 存在且标签=RESEARCH
## [Q] tech 状态=RESEARCHING, 发射 tech_started
func start_research(tech_id: String, org_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.start_research(tech_id, org_id)


# ===== 查询 =====

## 获取所有可研究的科技 ID 列表
func get_available_techs() -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_available_techs()


## 获取所有正在研究中的科技及其进度
## 返回格式: [{tech_id, org_id, progress, cost, ...}]
func get_researching_techs() -> Array[Dictionary]:
	if not _is_initialized:
		return []
	return _manager.get_researching_techs()


## 获取所有已解锁的科技 ID 列表
func get_unlocked_techs() -> Array[String]:
	if not _is_initialized:
		return []
	return _manager.get_unlocked_techs()


## 获取某项科技的完整状态信息
func get_tech_state(tech_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.get_tech_state(tech_id)


# ===== 分配 =====

## 向组织分配研究员
## [P] researcher 的 assigned_org = org_id
func assign_researchers(org_id: String, researcher_ids: Array[String]) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	return _manager.assign_researchers(org_id, researcher_ids)


# ===== 暂停/恢复 =====

## 暂停某项科技的研究
func pause_research(tech_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.pause_research(tech_id)
	if result.get("ok", false):
		tech_paused.emit(tech_id)
	return result


## 恢复某项科技的研究
func resume_research(tech_id: String) -> Dictionary:
	if not _is_initialized:
		return {"ok": false, "error": "模块未初始化"}
	var result := _manager.resume_research(tech_id)
	if result.get("ok", false):
		tech_resumed.emit(tech_id)
	return result