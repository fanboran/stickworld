class_name FormationSystem
extends Node
## 编队系统 -- 将选中的单位编为小队（squad），复用组织模块的 L1 节点。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2、§8.3。
##
## 流程：
##   1. selection_system 返回 unit_ids 数组
##   2. formation_system.create_squad(units) -> 返回 squad_id
##   3. formation_system.assign_leader(squad_id, leader_unit) 任命排长
##   4. tactical_orders.issue(order, squad_id, ...) 对小队下令
##
## 小队 = L1 MILITARY 组织节点（§8.3: "任命排长 = 创建 L1 组织节点"）。
## 本系统在组织模块之上封装小队级别的便捷 API，并维护 unit<->squad 双向映射。
##
## 队伍级目标决策（反编译参考实装 D-B）：本系统每 SQUAD_DECISION_INTERVAL 秒为每个
## 战斗小队选一个**共享攻击目标**（排长决策 → 队员执行），队员在攻击行为里优先用
## 队伍目标（集火），否则各自寻敌。参考遗产 TeamAi / 传奇单位组目标同步。
##
## 编队动态跟队（SWL MoveInFormationBehindAnotherFormation + GapBetweenFormationGroups
## 直译）：小队可锚定跟随另一小队（set_squad_follow_squad），每 0.5s tick 把后队未接战
## 成员重下发到"前队质心 − 行进方向 × gap"的队形位（hold_on_arrive 驻留，接战即还战斗
## 行为接管）；前队全灭/解散 → 自动解除锚定转自主决策。

# ─────────────────────────────── 常量 ────────────────────────────────
## 小队对应的组织层级（L1 = 最低层，排级）
const SQUAD_TIER := 1
## 默认预设（未指定时使用战斗班，保持旧行为兼容）
const DEFAULT_PRESET_ID := "fp_combat_squad"
## 预设配置文件路径
const PRESET_CONFIG_PATH := "res://config/formations/formation_presets.tres"
## 队形散开间距（px）：推进横排相邻队员间隔（反编译参考实装 D）
const SPREAD_SPACING: float = 32.0
## 集合围圈半径（px）：RALLY 集结时队员绕圈距离
const RALLY_RADIUS: float = 24.0
## 队伍级目标决策间隔（秒）：排长每此间隔重选一次共享攻击目标（反编译参考实装 D-B）
const SQUAD_DECISION_INTERVAL: float = 0.5
## 编队动态跟队默认间距（px，SWL GapBetweenFormationGroups 量级）：
## 后队落点 = 前队质心 − 行进方向 × gap
const FOLLOW_DEFAULT_GAP: float = 150.0
## 跟队重下发死区（px）：成员距锚定队形位小于此值不重下号令（防抖动/防 arrive 动画重播）
const FOLLOW_DEADZONE: float = 40.0
## 指挥官光环士气恢复速率（每秒；排长存活时队员士气恢复，AI 完善批次 3）
const LEADER_MORALE_AURA: float = 3.0
## 公共目标选择核心（反编译参考实装 A；同模块 combat，显式 preload）
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")

## 工作类型（RimWorld 式抽象职责，见 docs 设计 §二）
const WorkType := {
	COMBAT = "WORK_COMBAT",   ## 战斗/掩体/撤退/接号令
	BUILD = "WORK_BUILD",     ## 工地建造
	HAUL = "WORK_HAUL",       ## 搬运材料
	FORAGE = "WORK_FORAGE",   ## 采集劳作（预留）
}

# ─────────────────────────────── 信号 ────────────────────────────────
## 小队创建：squad_id + unit instance_id 数组
signal squad_created(squad_id: String, unit_ids: Array)
## 小队解散
signal squad_disbanded(squad_id: String)

# ─────────────────────────────── 状态 ────────────────────────────────
## OrganizationApi 引用（由 GameRoot 注入）
var _org_api: Node = null
## squad_id -> {"units": Array[Node], "leader": Node, "preset_id": String,
##              "work_types": Array[String], "role": String, "name": String,
##              "follow_squad_id": String, "follow_gap": float}
var _squads: Dictionary = {}
## unit.get_instance_id() -> squad_id（快速反查）
var _unit_to_squad: Dictionary = {}
## 小队名称自增计数
var _squad_counter: int = 0
## 编制预设：preset_id -> {"id", "name", "tag", "work_types", "default_role"}
var _presets: Dictionary = {}
## 预设是否已加载
var _presets_loaded: bool = false
## 队伍级共享攻击目标：squad_id -> Node（排长决策；反编译参考实装 D-B）
var _squad_targets: Dictionary = {}
## 队伍级目标决策计时器（累计到 SQUAD_DECISION_INTERVAL 触发一轮决策）
var _squad_decision_timer: float = 0.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 由 GameRoot 装配时注入 OrganizationApi 引用
func setup(org_api: Node) -> void:
	_org_api = org_api
	_load_presets()


## 从 config/formations/formation_presets.tres 加载编制预设。
## 加载失败时使用内置默认预设兜底，保证系统可用。
func _load_presets() -> void:
	if _presets_loaded:
		return
	_presets_loaded = true
	# 内置兜底：战斗班（与旧行为一致）
	_presets[DEFAULT_PRESET_ID] = {
		"id": DEFAULT_PRESET_ID,
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


func _process(_delta: float) -> void:
	if _squads.is_empty():
		return
	# 清理死亡/释放的单位，空小队自动解散
	var to_disband: Array = []
	for squad_id in _squads.keys():
		var squad: Dictionary = _squads[squad_id]
		var units: Array = squad["units"]
		var changed: bool = false
		var i: int = units.size() - 1
		while i >= 0:
			var u = units[i]
			# 防御：实例已释放（如跨图销毁）时无法读取 iid，整体解散兜底
			if not is_instance_valid(u):
				to_disband.append(squad_id)
				break
			if u.has_method("is_dead") and u.is_dead():
				_unit_to_squad.erase(u.get_instance_id())
				units.remove_at(i)
				changed = true
				# 同步组织模块：移除死亡单位（2026-08 修复：原实现仅本地移除，org.personnel 失步）
				if _org_api != null and _org_api.has_method("remove_stickman"):
					_org_api.remove_stickman(squad_id, str(u.get_instance_id()))
				if squad["leader"] == u:
					squad["leader"] = null
					# 同步解除指挥官
					if _org_api != null and _org_api.has_method("remove_commander"):
						_org_api.remove_commander(squad_id)
				# 清除编队派生角色（单位仍有效时）
				if u.has_method("set_role"):
					u.set_role("")
			i -= 1
		if units.is_empty():
			to_disband.append(squad_id)
		elif changed:
			# 已同步组织模块（remove_stickman/remove_commander），无额外操作
			pass
	for sid in to_disband:
		disband_squad(sid)
	# 队伍级目标决策（反编译参考实装 D-B）：排长决策 → 队员执行
	_decide_squad_targets(_delta)
	# 指挥官光环（AI 完善批次 3）：排长存活 → 队员士气恢复
	_apply_leader_morale_aura(_delta)


## 指挥官光环（行业最佳实践）：战斗小队排长存活时，队员持续恢复士气（指挥提振）。
func _apply_leader_morale_aura(delta: float) -> void:
	if _squads.is_empty():
		return
	for squad_id in _squads.keys():
		if not is_combat_squad(squad_id):
			continue
		var leader: Node = get_squad_leader(squad_id)
		if leader == null or not is_instance_valid(leader) \
				or (leader.has_method("is_dead") and leader.is_dead()):
			continue
		for u in _squads[squad_id]["units"]:
			if u == leader or not is_instance_valid(u):
				continue
			if u.has_method("is_dead") and u.is_dead():
				continue
			if not u.has_method("get_health"):
				continue
			var health: Node = u.get_health()
			if health != null and health.has_method("restore_morale"):
				health.restore_morale(LEADER_MORALE_AURA * delta)


# ─────────────────────────────── 核心 API ────────────────────────────────

## 创建小队。units 为 StickmanEntity 节点数组。返回 squad_id（失败返回 ""）。
## preset_id 指定编制预设（如 fp_combat_squad / fp_builder_crew / fp_worker_crew），
## 决定组织标签、成员职责范围（work_types）与成员角色（role）。
## 已在其他小队中的单位会先被移出。
func create_squad(units: Array, squad_name: String = "", preset_id: String = DEFAULT_PRESET_ID) -> String:
	if _org_api == null:
		push_warning("[FormationSystem] organization_api 未注入")
		return ""
	# 过滤有效单位（存活）
	var valid_units: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		valid_units.append(u)
	if valid_units.is_empty():
		push_warning("[FormationSystem] 无有效单位，无法创建小队")
		return ""
	# 解析预设
	var preset: Dictionary = _resolve_preset(preset_id)
	# 已在其他小队的单位先移出
	for u in valid_units:
		_remove_unit_from_squad(u)
	# 创建 L1 组织（标签来自预设）
	_squad_counter += 1
	var name_str: String = squad_name if not squad_name.is_empty() else "squad_%d" % _squad_counter
	var result: Dictionary = _org_api.create_organization(name_str, preset["tag"], SQUAD_TIER, "")
	if not result.get("ok", false):
		push_warning("[FormationSystem] 创建组织失败: %s" % result.get("error", ""))
		return ""
	var squad_id: String = result["data"]["org_id"]
	# 将单位分配到组织，写入角色
	var work_types: Array = (preset["work_types"] as Array).duplicate()
	for u in valid_units:
		var sid: String = str(u.get_instance_id())
		_org_api.assign_stickman(squad_id, sid, preset["default_role"])
		if u.has_method("set_role"):
			u.set_role(preset["default_role"])
		_unit_to_squad[u.get_instance_id()] = squad_id
	# 本地追踪
	_squads[squad_id] = {
		"units": valid_units.duplicate(),
		"leader": null,
		"preset_id": preset["id"],
		"work_types": work_types,
		"role": preset["default_role"],
		"name": name_str,
		"follow_player": false,
		"follow_squad_id": "",
		"follow_gap": 0.0,
	}
	# 发射信号
	var unit_ids: Array = []
	for u in valid_units:
		unit_ids.append(u.get_instance_id())
	squad_created.emit(squad_id, unit_ids)
	if EventBus != null and EventBus.has_signal("squad_created"):
		EventBus.squad_created.emit(squad_id, unit_ids)
	return squad_id


## 解散小队。
func disband_squad(squad_id: String) -> void:
	if not _squads.has(squad_id):
		return
	var squad: Dictionary = _squads[squad_id]
	# 清除单位映射与编队派生角色（2026-08 审计修复：disband 也要清 role，与 disband_all_squads 一致）
	for u in squad["units"]:
		if is_instance_valid(u):
			_unit_to_squad.erase(u.get_instance_id())
			if u.has_method("set_role"):
				u.set_role("")
	# 解散组织
	if _org_api != null and _org_api.has_method("disband_organization"):
		_org_api.disband_organization(squad_id)
	# 移除本地追踪
	_squads.erase(squad_id)
	_squad_targets.erase(squad_id)
	squad_disbanded.emit(squad_id)


## 解散全部小队并清空本地状态（跨图携带前调用：快照导出后调用，
## 避免旧图实体 freed 后残留引用导致 _process 报错）。
func disband_all_squads() -> void:
	for squad_id in _squads.keys():
		var squad: Dictionary = _squads[squad_id]
		for u in squad["units"]:
			if is_instance_valid(u):
				_unit_to_squad.erase(u.get_instance_id())
				if u.has_method("set_role"):
					u.set_role("")
		if _org_api != null and _org_api.has_method("disband_organization"):
			_org_api.disband_organization(squad_id)
		squad_disbanded.emit(squad_id)
	_squads.clear()
	_unit_to_squad.clear()


## 任命小队长（排长）。返回是否成功。
func assign_leader(squad_id: String, leader: Node) -> bool:
	if not _squads.has(squad_id):
		push_warning("[FormationSystem] 小队不存在: %s" % squad_id)
		return false
	if not is_instance_valid(leader):
		return false
	# 必须是小队成员
	if leader not in _squads[squad_id]["units"]:
		push_warning("[FormationSystem] 任命失败：单位不在该小队中")
		return false
	# 设置组织指挥官
	if _org_api != null and _org_api.has_method("assign_commander"):
		_org_api.assign_commander(squad_id, str(leader.get_instance_id()))
	_squads[squad_id]["leader"] = leader
	if EventBus != null and EventBus.has_signal("commander_assigned"):
		EventBus.commander_assigned.emit(squad_id, leader.get_instance_id())
	return true


## 将单位加入已有小队。
func add_unit(squad_id: String, unit: Node) -> bool:
	if not _squads.has(squad_id):
		return false
	if not is_instance_valid(unit):
		return false
	if unit.has_method("is_dead") and unit.is_dead():
		return false
	# 先从当前小队移出
	_remove_unit_from_squad(unit)
	# 加入组织
	if _org_api != null and _org_api.has_method("assign_stickman"):
		_org_api.assign_stickman(squad_id, str(unit.get_instance_id()), _squads[squad_id]["role"])
	if unit.has_method("set_role"):
		unit.set_role(_squads[squad_id]["role"])
	_squads[squad_id]["units"].append(unit)
	_unit_to_squad[unit.get_instance_id()] = squad_id
	return true


## 将单位从小队移除。
func remove_unit(unit: Node) -> void:
	_remove_unit_from_squad(unit)


# ─────────────────────────────── 查询 API ────────────────────────────────

func get_squad_units(squad_id: String) -> Array:
	if not _squads.has(squad_id):
		return []
	return (_squads[squad_id]["units"] as Array).duplicate()


func get_squad_leader(squad_id: String) -> Node:
	if not _squads.has(squad_id):
		return null
	return _squads[squad_id]["leader"]


## 队伍级目标点分配（反编译参考实装 D）：按单位在队内序号计算个性化目标点，
## 取代"全体同一点"——推进横排展开、集合围圈，配合实体 separation 防叠人。
## mode: "line" 横排散开（推进/冲刺）/ "rally" 围圈（集合）/ 其它 返回 base_pos。
## 参考：遗产 TeamAi/Formation、传奇 Formations/FormationMember。
func get_squad_dest(squad_id: String, unit: Node, base_pos: Vector2, mode: String = "") -> Vector2:
	if not _squads.has(squad_id) or unit == null or not is_instance_valid(unit):
		return base_pos
	var units: Array = _squads[squad_id]["units"]
	var idx: int = units.find(unit)
	if idx < 0:
		return base_pos
	var n: int = units.size()
	if n <= 1:
		return base_pos
	if mode == "line":
		# 垂直于移动方向横排展开：间距 SPREAD_SPACING，相对中心左右交替
		var dir: Vector2 = (base_pos - unit.global_position).normalized() if base_pos != unit.global_position else Vector2.RIGHT
		var perp := Vector2(-dir.y, dir.x)
		var offset: float = (idx - float(n - 1) / 2.0) * SPREAD_SPACING
		return base_pos + perp * offset
	if mode == "rally":
		# 围圈集合：队员绕集合点一圈（RALLY 紧凑成团）
		var angle: float = idx * TAU / float(n)
		return base_pos + Vector2(cos(angle), sin(angle)) * RALLY_RADIUS
	return base_pos


## 队伍级目标决策（反编译参考实装 D-B）：每 SQUAD_DECISION_INTERVAL 秒为每个战斗小队
## 选一个共享攻击目标（排长决策 → 队员执行）。由 _process 调用。
func _decide_squad_targets(delta: float) -> void:
	if _squads.is_empty():
		_squad_targets.clear()
		return
	_squad_decision_timer += delta
	if _squad_decision_timer < SQUAD_DECISION_INTERVAL:
		return
	_squad_decision_timer = 0.0
	for squad_id in _squads.keys():
		if not is_combat_squad(squad_id):
			_squad_targets.erase(squad_id)
			continue
		var leader: Node = get_squad_leader(squad_id)
		var rep: Node = leader
		# 排长失效时退化到第一个存活队员
		if rep == null or not is_instance_valid(rep) or (rep.has_method("is_dead") and rep.is_dead()):
			rep = null
			for u in _squads[squad_id]["units"]:
				if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
					rep = u
					break
		if rep == null:
			_squad_targets.erase(squad_id)
			continue
		# 经队员拿 battle（不持有 battle 引用，避免耦合）；无 battle 不选目标
		var battle: Node = rep.get_battle_instance() if rep.has_method("get_battle_instance") else null
		if battle == null or not is_instance_valid(battle):
			_squad_targets.erase(squad_id)
			continue
		var target: Node = ScriptTargetFinder.find_target(rep, { "battle": battle })
		if target == null:
			_squad_targets.erase(squad_id)
		else:
			_squad_targets[squad_id] = target
	# 编队动态跟队（SWL MoveInFormationBehindAnotherFormation 直译）：锚定小队落点维持
	_update_squad_follows()


## 队伍级共享攻击目标（队员查询；含有效性校验——目标死亡/失效返回 null）。
func get_squad_target(squad_id: String) -> Node:
	if not _squad_targets.has(squad_id):
		return null
	var t: Node = _squad_targets[squad_id]
	if t == null or not is_instance_valid(t):
		return null
	if t.has_method("is_dead") and t.is_dead():
		return null
	return t


func get_unit_squad(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	return _unit_to_squad.get(unit.get_instance_id(), "")


func get_all_squads() -> Array:
	return _squads.keys()


func get_squad_count() -> int:
	return _squads.size()


func is_in_squad(unit: Node) -> bool:
	return get_unit_squad(unit) != ""


func get_squad_size(squad_id: String) -> int:
	if not _squads.has(squad_id):
		return 0
	return _squads[squad_id]["units"].size()


# ─────────────────────────────── 内部 ────────────────────────────────

## 将单位从其当前小队中移除（如有）
func _remove_unit_from_squad(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	var squad_id: String = _unit_to_squad.get(iid, "")
	if squad_id == "":
		return
	if not _squads.has(squad_id):
		_unit_to_squad.erase(iid)
		return
	var squad: Dictionary = _squads[squad_id]
	(squad["units"] as Array).erase(unit)
	_unit_to_squad.erase(iid)
	if squad["leader"] == unit:
		squad["leader"] = null
	# 清除编队派生角色
	if unit.has_method("set_role"):
		unit.set_role("")
	# 同步到组织模块
	if _org_api != null and _org_api.has_method("remove_stickman"):
		_org_api.remove_stickman(squad_id, str(iid))


# ──────────────────────── 编队动态跟队（内部）────────────────────────────────

## 锚定小队落点维持（每 0.5s tick，与队伍目标决策共用节拍）：
##   1. 前队解散/全灭 → 解除锚定，后队转自主决策（SWL 前队全灭不再跟队）
##   2. 落点 = 前队质心 − 行进方向 × gap；行进方向取"后队质心 → 前队质心"
##      （停驻接敌时依然稳定，不依赖速度采样，天然左右军镜像）
##   3. 前队接敌 → 后队越过 gap 推进到战线支援（不带 hold 驻留，到位/接敌即
##      交还战斗决策）——否则前队缠斗时后队永远钉在 gap 处"全员卡死"
##   4. 未接战成员超出死区 → 重下 move 号令（hold_on_arrive 驻留 +
##      engage_in_range：敌进射程即 finish 交还战斗行为）
func _update_squad_follows() -> void:
	for squad_id in _squads.keys():
		if _squads[squad_id].get("follow_squad_id", "") != "":
			_update_squad_follow(squad_id)


## 单个锚定小队的落点计算与成员号令下发。
func _update_squad_follow(squad_id: String) -> void:
	var squad: Dictionary = _squads.get(squad_id, {})
	if squad.is_empty():
		return
	# 与"跟随玩家"模式互斥（跟随玩家由 BehaviorFollow 决策，锚定号令会打断它）
	if squad.get("follow_player", false):
		return
	var front_id: String = squad.get("follow_squad_id", "")
	if front_id.is_empty():
		return
	# 前队解散 → 解除锚定
	if not _squads.has(front_id):
		clear_squad_follow(squad_id)
		return
	# 前队质心（仅存活成员；全灭 → 解除锚定转自主决策）
	var front_centroid := Vector2.ZERO
	var front_n: int = 0
	for u in _squads[front_id]["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			front_centroid += u.global_position
			front_n += 1
	if front_n == 0:
		clear_squad_follow(squad_id)
		return
	front_centroid /= float(front_n)
	# 前队是否接敌（任一存活成员射程内有敌）：接敌 → 后队推进支援，不再钉在 gap 处
	var front_engaged: bool = false
	for u in _squads[front_id]["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()) \
				and _member_enemy_in_range(u):
			front_engaged = true
			break
	# 后队存活成员与质心
	var members: Array = []
	var my_centroid := Vector2.ZERO
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			members.append(u)
			my_centroid += u.global_position
	if members.is_empty():
		return
	my_centroid /= float(members.size())
	# 行进方向：后队质心 → 前队质心（退化 = 两队重叠，维持原位不推；
	# 支援模式重叠时仍要推进，不提前返回）
	var dir: Vector2 = front_centroid - my_centroid
	if not front_engaged and dir.length_squared() < 1.0:
		return
	var anchor: Vector2 = front_centroid
	if not front_engaged:
		anchor = front_centroid - dir.normalized() * float(squad.get("follow_gap", FOLLOW_DEFAULT_GAP))
	# 成员号令下发（接战/撤退/找掩体/被附身成员不打断；玩家号令不覆盖）
	for u in members:
		if u.has_method("is_possessed") and u.is_possessed():
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai == null:
			continue
		if ai.has_method("get_current_behavior") \
				and ai.get_current_behavior() in ["retreat", "seek_cover"]:
			continue  # 士气驱动行为，不拽回队列
		if _member_enemy_in_range(u):
			continue  # 射程内有敌（含风筝窗口），交还给战斗行为
		var slot: Vector2 = get_squad_dest(squad_id, u, anchor, "line")
		# 已有他人号令（无 follow_order 标记 = 玩家/上级号令）→ 不覆盖
		if ai.has_method("has_order") and ai.has_order():
			if not (ai.has_method("get_ordered_params")
					and ai.get_ordered_params().get("follow_order", false)):
				continue
			# 已有跟队号令且落点未漂出死区 → 不重复下发（防 travel 重入重播 arrive 动画）
			if ai.has_method("get_ordered_behavior") and ai.get_ordered_behavior() == "move" \
					and ai.get_ordered_params().get("target", Vector2.ZERO).distance_to(slot) <= FOLLOW_DEADZONE:
				continue
		ai.set_order("move", {
			"target": slot,
			"engage_in_range": true,
			# 行军跟队驻留待命；支援推进不驻留——到位即 finish 交还战斗决策
			"hold_on_arrive": not front_engaged,
			"follow_order": true,
		})


## 成员主手射程内是否有存活敌人（跟队不打断接战成员；行为同 BehaviorMove 接敌检查）。
func _member_enemy_in_range(u: Node) -> bool:
	if not u.has_method("get_battle_instance"):
		return false
	var bi: Node = u.get_battle_instance()
	if bi == null or not is_instance_valid(bi) \
			or not bi.has_method("is_active") or not bi.is_active():
		return false
	var faction: int = u.get_faction() if u.has_method("get_faction") else 0
	if faction == 0 or not bi.has_method("get_enemies_of"):
		return false
	var weapon: Node = u.get_weapon() if u.has_method("get_weapon") else null
	var attack_range: float = float(weapon.attack_range) if weapon != null and "attack_range" in weapon else 100.0
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if u.global_position.distance_to(e.global_position) <= attack_range:
			return true
	return false


## 锚定链是否已包含 squad_id（防成环：设 A→B 前检查 B 的前向链是否回到 A）。
func _follow_chain_has(squad_id: String, target_id: String) -> bool:
	var cur: String = target_id
	var hops: int = 0
	while not cur.is_empty() and hops < 16:
		if cur == squad_id:
			return true
		if not _squads.has(cur):
			return false
		cur = _squads[cur].get("follow_squad_id", "")
		hops += 1
	return false


# ─────────────────────────────── 预设 API ────────────────────────────────

## 获取全部编制预设列表（用于 UI 下拉）。返回 Array[Dictionary]。
func get_all_presets() -> Array:
	_load_presets()
	var result: Array = []
	for pid in _presets.keys():
		result.append(_presets[pid].duplicate(true))
	return result


## 按 id 获取编制预设（不存在返回空 Dictionary）。
func get_preset(preset_id: String) -> Dictionary:
	_load_presets()
	return _presets.get(preset_id, {})


## 解析预设：不存在或字段缺失时回退内置战斗班。
func _resolve_preset(preset_id: String) -> Dictionary:
	_load_presets()
	var p: Dictionary = _presets.get(preset_id, {})
	if p.is_empty():
		p = _presets[DEFAULT_PRESET_ID]
	return p


# ─────────────────────────────── 职责 API ────────────────────────────────

## 获取小队使用的预设 id。
func get_squad_preset(squad_id: String) -> String:
	if not _squads.has(squad_id):
		return ""
	return _squads[squad_id]["preset_id"]


## 获取小队当前职责范围（工作类型数组）。
func get_squad_work_types(squad_id: String) -> Array:
	if not _squads.has(squad_id):
		return []
	return (_squads[squad_id]["work_types"] as Array).duplicate()


## 调整小队职责范围（工作类型数组，如 ["WORK_COMBAT", "WORK_HAUL"]）。
## 职责可自由调整；组织标签不随调整迁移（P0 简化，阶段 1 并入组织系统）。
## 返回是否成功。
func set_squad_work_types(squad_id: String, work_types: Array) -> bool:
	if not _squads.has(squad_id):
		return false
	_squads[squad_id]["work_types"] = work_types.duplicate()
	return true


## 判断单位是否允许执行某工作类型。
## 未编队单位视为全能（允许一切）；编队单位受队伍职责范围限制。
func is_work_allowed(unit: Node, work_type: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return true
	var squad_id: String = _unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id == "" or not _squads.has(squad_id):
		return true
	return work_type in _squads[squad_id]["work_types"]


## 小队是否允许战斗类职责（供号令可用性过滤）。
func is_combat_squad(squad_id: String) -> bool:
	if not _squads.has(squad_id):
		return false
	return WorkType.COMBAT in _squads[squad_id]["work_types"]


## 设置小队"跟随玩家"模式：开启后成员自动跟随玩家移动（跟到战场）。
## 由编制窗口勾选触发，BehaviorFollow 行为执行。
func set_squad_follow(squad_id: String, follow: bool) -> bool:
	if not _squads.has(squad_id):
		return false
	_squads[squad_id]["follow_player"] = follow
	return true


## 小队是否处于跟随玩家模式。
func is_squad_following(squad_id: String) -> bool:
	if not _squads.has(squad_id):
		return false
	return _squads[squad_id].get("follow_player", false)


## 单位所在小队是否跟随玩家（供 AI 决策查询）。
func is_unit_squad_following(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var squad_id: String = _unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id == "" or not _squads.has(squad_id):
		return false
	return _squads[squad_id].get("follow_player", false)


# ──────────────────────────── 编队动态跟队（锚定跟随）────────────────────────────────

## 设置小队锚定跟随另一小队（编队动态跟队，SWL MoveInFormationBehindAnotherFormation +
## GapBetweenFormationGroups 直译）：后队落点 = 前队质心 − 行进方向 × gap，由
## _decide_squad_targets 每 0.5s tick 维持；前队全灭/解散自动解除锚定转自主决策。
## front_squad_id 传空 = 解除锚定。返回是否成功。
func set_squad_follow_squad(squad_id: String, front_squad_id: String, gap: float = FOLLOW_DEFAULT_GAP) -> bool:
	if not _squads.has(squad_id):
		return false
	if front_squad_id.is_empty():
		clear_squad_follow(squad_id)
		return true
	if front_squad_id == squad_id or not _squads.has(front_squad_id):
		return false
	if _follow_chain_has(squad_id, front_squad_id):
		return false  # 防锚定成环（A→B→…→A）
	_squads[squad_id]["follow_squad_id"] = front_squad_id
	_squads[squad_id]["follow_gap"] = maxf(0.0, gap)
	_update_squad_follow(squad_id)  # 立即落一次位（不等下个 tick）
	return true


## 解除小队锚定跟随，转自主决策（前队全灭/玩家接管时调用）。
## 仅回收跟队自己下的 move 号令（follow_order 标记鉴别），玩家号令不受影响。
func clear_squad_follow(squad_id: String) -> void:
	if not _squads.has(squad_id):
		return
	_squads[squad_id]["follow_squad_id"] = ""
	_squads[squad_id]["follow_gap"] = 0.0
	for u in _squads[squad_id]["units"]:
		if not is_instance_valid(u):
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai == null or not ai.has_method("has_order") or not ai.has_order():
			continue
		if not ai.has_method("get_ordered_behavior") or ai.get_ordered_behavior() != "move":
			continue
		if ai.has_method("get_ordered_params") \
				and ai.get_ordered_params().get("follow_order", false):
			ai.clear_order()


## 查询锚定跟随信息（调试/测试用）：{"front": String, "gap": float}，未锚定返回 {}。
func get_squad_follow(squad_id: String) -> Dictionary:
	if not _squads.has(squad_id):
		return {}
	var front: String = _squads[squad_id].get("follow_squad_id", "")
	if front.is_empty():
		return {}
	return { "front": front, "gap": _squads[squad_id].get("follow_gap", 0.0) }


## 获取小队名称。
func get_squad_name(squad_id: String) -> String:
	if not _squads.has(squad_id):
		return ""
	return _squads[squad_id]["name"]


# ─────────────────────────────── 跨图携带（快照/恢复）────────────────────────────────

## 导出全部编队快照（跨图携带用，travel 前由 GameRoot 收集）。
## 返回 Array[Dictionary]：{"name", "preset_id", "work_types", "leader_iid",
##                           "members": [{"iid", "role"}]}
func export_squads() -> Array:
	var result: Array = []
	for squad_id in _squads.keys():
		var s: Dictionary = _squads[squad_id]
		var members: Array = []
		for u in s["units"]:
			if is_instance_valid(u):
				members.append({
					"iid": u.get_instance_id(),
					"role": u.get_role() if u.has_method("get_role") else "",
				})
		var leader_iid: int = 0
		if s["leader"] != null and is_instance_valid(s["leader"]):
			leader_iid = s["leader"].get_instance_id()
		result.append({
			"name": s["name"],
			"preset_id": s["preset_id"],
			"work_types": (s["work_types"] as Array).duplicate(),
			"leader_iid": leader_iid,
			"members": members,
			"follow_player": s.get("follow_player", false),
		})
	return result


## 按快照重建编队（跨图携带恢复，map_loaded 后由 GameRoot 调用）。
## entity_map: 旧 instance_id(int) -> 新实体(Node)。
## 返回成功恢复的小队数。
func restore_squads(snapshots: Array, entity_map: Dictionary) -> int:
	var restored: int = 0
	for snap in snapshots:
		var members: Array = []
		for m in snap.get("members", []):
			var e: Node = entity_map.get(int(m.get("iid", 0)))
			if e != null and is_instance_valid(e):
				members.append(e)
		if members.is_empty():
			continue
		var squad_id: String = create_squad(
			members, snap.get("name", ""), snap.get("preset_id", DEFAULT_PRESET_ID)
		)
		if squad_id.is_empty():
			continue
		# 恢复自定义职责范围
		var work_types: Array = snap.get("work_types", [])
		if not work_types.is_empty():
			set_squad_work_types(squad_id, work_types)
		# 恢复排长
		var leader_iid: int = int(snap.get("leader_iid", 0))
		if leader_iid != 0 and entity_map.has(leader_iid):
			var leader: Node = entity_map[leader_iid]
			if is_instance_valid(leader) and leader in members:
				assign_leader(squad_id, leader)
		# 恢复跟随玩家标志（跨图后跟随不丢）
		if snap.get("follow_player", false):
			set_squad_follow(squad_id, true)
		restored += 1
	return restored
