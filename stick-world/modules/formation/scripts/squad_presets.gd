extends RefCounted
## 编制预设子域 —— 从 formation_system.gd 拆出的预设/职责范围域。
##
## 职责：编制预设装载（config/formations/formation_presets.tres + 内置战斗班兜底）、
## 预设查询（UI 下拉 / 不存在回退战斗班解析）、班侧职责面（班 preset 记录查询 /
## 职责范围查询与调整 / 工作类型放行判定 / 战斗班判定）。
##
## 状态例外（"状态留宿主"纪律的登记合法例外）：_presets/_presets_loaded 随域自持
## ——预设域无跨域消费者（唯一写入口 load_presets、读口全在本文件，搬前 grep 证实
## _presets 只被本域读写）；班侧状态（_squads/_unit_to_squad）仍留宿主，经 _host
## 动态回引读写（姿势同 squad_platoon 等状态留宿主型助手）。
## WorkType 常量真身随域，宿主经 const 别名转发（FormationSystem.WorkType 的既有
## 类名级消费面——formation_panel 等——不变）；DEFAULT_PRESET_ID 常量留宿主
##（create_squad 默认形参与快照恢复经 _host 取用），本域经 _host 读取不抄副本。

## 工作类型（RimWorld 式抽象职责，见 docs 设计 §二）
## 搬运（HAUL）是全员基础能力，不受职责范围限制（见 is_work_allowed）；
## 运输（TRANSPORT）是跨城市运输/物资运往前线的物流职责（物流系统预留）。
const WorkType := {
	COMBAT = "WORK_COMBAT",       ## 战斗/掩体/撤退/接号令
	BUILD = "WORK_BUILD",         ## 工地建造
	HAUL = "WORK_HAUL",           ## 搬运材料（全员基础能力）
	TRANSPORT = "WORK_TRANSPORT", ## 运输队：跨城市运输/物资运往前线（物流系统预留）
	FORAGE = "WORK_FORAGE",       ## 采集劳作（预留）
}

## 预设配置文件路径
const PRESET_CONFIG_PATH := "res://config/formations/formation_presets.tres"

var _host  ## 宿主 FormationSystem（动态回引：班侧状态唯一真相源在宿主；DEFAULT_PRESET_ID 亦取自宿主）

## 编制预设：preset_id -> {"id", "name", "tag", "work_types", "default_role"}
var _presets: Dictionary = {}
## 预设是否已加载
var _presets_loaded: bool = false


func _init(host) -> void:
	_host = host


## 从 config/formations/formation_presets.tres 加载编制预设（失败用内置默认兜底保证可用）。
func load_presets() -> void:
	if _presets_loaded:
		return
	_presets_loaded = true
	# 内置兜底：战斗班（与旧行为一致）
	_presets[_host.DEFAULT_PRESET_ID] = {
		"id": _host.DEFAULT_PRESET_ID,
		"name": "战斗班",
		"tag": "MILITARY",
		"work_types": [WorkType.COMBAT],
		"default_role": "fighter",
	}
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not "variables" in res:
		push_warning("[FormationSystem] 预设配置加载失败: %s，使用内置默认" % PRESET_CONFIG_PATH)
		return
	var data: Array = res.get("variables").get("data", [])
	for p in data:
		var pid: String = p.get("id", "")
		if pid.is_empty():
			continue
		_presets[pid] = {
			"id": pid,
			"name": p.get("name", pid),
			"tag": p.get("tag", "MILITARY"),
			"work_types": (p.get("work_types", [WorkType.COMBAT]) as Array).duplicate(),
			"default_role": p.get("default_role", "member"),
		}


## 获取全部编制预设列表（用于 UI 下拉）。返回 Array[Dictionary]。
func get_all_presets() -> Array:
	load_presets()
	var result: Array = []
	for pid in _presets.keys():
		result.append(_presets[pid].duplicate(true))
	return result


## 按 id 获取编制预设（不存在返回空 Dictionary）。
func get_preset(preset_id: String) -> Dictionary:
	load_presets()
	return _presets.get(preset_id, {})


## 解析预设：不存在或字段缺失时回退内置战斗班。
func resolve_preset(preset_id: String) -> Dictionary:
	load_presets()
	var p: Dictionary = _presets.get(preset_id, {})
	if p.is_empty():
		p = _presets[_host.DEFAULT_PRESET_ID]
	return p


## 获取小队使用的预设 id。
func get_squad_preset(squad_id: String) -> String:
	if not _host._squads.has(squad_id):
		return ""
	return _host._squads[squad_id]["preset_id"]


## 获取小队当前职责范围（工作类型数组）。
func get_squad_work_types(squad_id: String) -> Array:
	if not _host._squads.has(squad_id):
		return []
	return (_host._squads[squad_id]["work_types"] as Array).duplicate()


## 调整小队职责范围（工作类型数组，如 ["WORK_COMBAT", "WORK_HAUL"]）。
## 职责可自由调整；组织标签不随调整迁移（P0 简化，阶段 1 并入组织系统）。
## 返回是否成功。
func set_squad_work_types(squad_id: String, work_types: Array) -> bool:
	if not _host._squads.has(squad_id):
		return false
	_host._squads[squad_id]["work_types"] = work_types.duplicate()
	return true


## 判断单位是否允许执行某工作类型。
## 未编队单位视为全能（允许一切）；编队单位受队伍职责范围限制，
## 但搬运（WORK_HAUL）是全员基础能力恒放行——不存在搬不了东西的单位。
func is_work_allowed(unit: Node, work_type: String) -> bool:
	if work_type == WorkType.HAUL:
		return true
	if unit == null or not is_instance_valid(unit):
		return true
	var squad_id: String = _host._unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id == "" or not _host._squads.has(squad_id):
		return true
	return work_type in _host._squads[squad_id]["work_types"]


## 小队是否允许战斗类职责（供号令可用性过滤）。
func is_combat_squad(squad_id: String) -> bool:
	if not _host._squads.has(squad_id):
		return false
	return WorkType.COMBAT in _host._squads[squad_id]["work_types"]
