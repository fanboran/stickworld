class_name TacticalOrders
extends Node
## 战术号令系统 -- 预设号令的下达入口。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.3、§8.4、组织系统架构.md §4.2.4。
## 两条下达路径：
##   issue(order, squad_id, ...)            对 L1 小队直令（玩家框选微操/team_ai 现场指挥，
##                                          不吃传播——战场现场电台）：
##   -> command_chain.deliver(...) 即时送达 -> 各单位 AIController.set_order 执行
##   issue_to_org(org_id, order_type, ...)  对组织（任意层级）下令（§4.2.4 逐层接力）：
##   -> OrgApi.build_dispatch_plan 生成 hop 计划（玩家跳 + BFS 层序，同令透传）
##   -> command_chain.deliver_via_orgs(...) 按跳物理传播接力（延迟 = 距离 ÷ 媒介速度）
##   -> L1 送达即时执行；中间层无实体动作；伤亡空缺的中间层命令停驻丢弃
##
## P0 范围号令（§8.4）：
##   ADVANCE_ALL  - 全体向目标点前进（behavior: move）
##   SPRINT       - 加速冲刺（behavior: move, run=true）
##   HOLD_POSITION - 原地坚守（behavior: idle，清除移动命令）
##   RETREAT      - 有序后撤（behavior: retreat）
##   TAKE_COVER   - 就近找掩体（behavior: seek_cover）
##   RALLY        - 集结溃兵（behavior: move 到集结点）

# ─────────────────────────────── 号令类型 ────────────────────────────────
enum OrderType {
	ADVANCE_ALL,     ## 全体向目标点前进
	SPRINT,          ## 消耗体力加速冲刺
	HOLD_POSITION,   ## 原地坚守
	RETREAT,         ## 有序后撤
	TAKE_COVER,      ## 就近找掩体
	RALLY,           ## 集结溃兵
}

# ─────────────────────────────── 信号 ────────────────────────────────
## 号令已下达（送达前即发射，含延迟信息）
signal order_issued(order_type: int, target_squad_id: String, source_tier: int)

# ─────────────────────────────── 状态 ────────────────────────────────
## FormationSystem 引用（查询小队成员）
var _formation_system: Node = null
## CommandChain 引用（延迟下达）
var _command_chain: Node = null
## OrganizationApi 引用（issue_to_org 计划生成/传输计时；装配注入，缺省时 issue_to_org 不可用）
var _org_api: Node = null


# ─────────────────────────────── 装配 ────────────────────────────────

func setup(formation_system: Node, command_chain: Node, org_api: Node = null) -> void:
	_formation_system = formation_system
	_command_chain = command_chain
	_org_api = org_api


# ─────────────────────────────── 核心 API ────────────────────────────────

## 对指定小队下达号令。
## order_type: OrderType 枚举值
## squad_id: 目标小队 ID
## target_pos: 目标位置（世界坐标，ADVANCE/RALLY 用）
## source_tier: 发令者层级（0=玩家直接指挥，延迟为 0）
## extra_params: 行为参数增量（合并进 _order_to_params；如 RETREAT 的 evacuate=true
## 战役撤离标记，TeamAi ROUT 姿态消费——出征与领地架构 §4.2）
## 返回是否成功下达（小队存在且有有效单位）。
func issue(order_type: int, squad_id: String, target_pos: Vector2 = Vector2.ZERO,
		source_tier: int = 0, extra_params: Dictionary = {}) -> bool:
	if _formation_system == null or _command_chain == null:
		push_warning("[TacticalOrders] 未注入 formation_system 或 command_chain")
		return false
	var units: Array = _formation_system.get_squad_units(squad_id)
	if units.is_empty():
		push_warning("[TacticalOrders] 小队 %s 无有效单位" % squad_id)
		return false
	# 战斗号令仅限战斗职责小队（建造队/劳工队/运输队拒绝）
	if _formation_system.has_method("is_combat_squad") and not _formation_system.is_combat_squad(squad_id):
		push_warning("[TacticalOrders] 小队 %s 无战斗职责，拒绝号令" % squad_id)
		return false
	var behavior_name: String = _order_to_behavior(order_type)
	var params: Dictionary = _order_to_params(order_type, target_pos)
	params.merge(extra_params, true)
	# 队伍级目标点分配模式（反编译参考实装 D）：推进/冲刺横排散开，RALLY 围圈集合
	var spread_mode: String = _order_to_spread(order_type)
	# 通过指挥链下达（P0 source_tier=0 时无延迟）
	_command_chain.deliver(order_type, squad_id, units, behavior_name, params, source_tier, 1, spread_mode)
	# 发射信号
	order_issued.emit(order_type, squad_id, source_tier)
	if EventBus != null and EventBus.has_signal("order_issued"):
		EventBus.order_issued.emit(order_type, squad_id, source_tier)
	return true


## 对所有小队下达号令。返回成功下达的小队数。
func issue_to_all(order_type: int, target_pos: Vector2 = Vector2.ZERO) -> int:
	if _formation_system == null:
		return 0
	var count: int = 0
	for squad_id in _formation_system.get_all_squads():
		if issue(order_type, squad_id, target_pos):
			count += 1
	return count


## 对组织下达号令（§4.2.4，任意层级根）：生成逐层投递计划后经 CommandChain
## 物理传播接力——L1 收令时刻 = 沿途各跳延迟之和；中间层只透传不做决策。
## org_id: 目标组织 id（L1 小队或中间层均可）
## extra_params: 行为参数增量（A2 TeamAi 消费：RETREAT 的 evacuate=true 经组织链
## 透传至 L1，与 issue 直令路径同语义）
## 返回是否受理（计划生成成功即受理；送达结果异步，非战斗叶在送达时拒收）
func issue_to_org(org_id: String, order_type: int, target_pos: Vector2 = Vector2.ZERO,
		extra_params: Dictionary = {}) -> bool:
	if _formation_system == null or _command_chain == null:
		push_warning("[TacticalOrders] 未注入 formation_system 或 command_chain")
		return false
	if _org_api == null or not _org_api.has_method("build_dispatch_plan"):
		push_warning("[TacticalOrders] 未注入 organization_api，组织号令不可用")
		return false
	# 逐层投递计划（§4.1 schema：hop 0 玩家跳 + BFS 层序；organization 不解释字段只透传）
	var plan_result: Dictionary = _org_api.build_dispatch_plan(org_id, {
		"order_type": order_type,
		"target_pos": target_pos,
	})
	if not plan_result.get("ok", false):
		push_warning("[TacticalOrders] 组织号令计划失败: %s" % plan_result.get("error", ""))
		return false
	# 同令透传：全部跳共用同一份号令语义，映射一次全程适用
	var behavior_name: String = _order_to_behavior(order_type)
	var params: Dictionary = _order_to_params(order_type, target_pos)
	params.merge(extra_params, true)
	var spread_mode: String = _order_to_spread(order_type)
	# 接力执行（协程，fire-and-forget——受理即返回，送达异步推进）
	_command_chain.deliver_via_orgs(plan_result["data"], _org_api, order_type, behavior_name, params, spread_mode)
	# 发射信号（既有口径：org 根 id 作 target；source_tier=0 玩家跳）
	order_issued.emit(order_type, org_id, 0)
	if EventBus != null and EventBus.has_signal("order_issued"):
		EventBus.order_issued.emit(order_type, org_id, 0)
	return true


# ─────────────────────────────── 查询 ────────────────────────────────

## 查询小队所在组织树的根 id（A2 下令路径分流消费，设计文档 §四）：
## 组织化编制（小队挂于多层组织树下）→ 树根 org_id，号令走 issue_to_org 逐跳传播；
## 散兵（无组织挂载 / 无父级的独立 L1）/ org_api 未装配 / 查询失败 → ""（issue 直令）。
## 独立 L1（无父级）按散兵处理：其 issue_to_org 计划只有玩家跳一跳，走 org 入口
## 无传播语义且 Event 信号口径会误标玩家跳——不路由。
## combat 不直引 organization——组织查询由本类代理（已持 _org_api 引用），守模块契约。
func get_org_root_for_squad(squad_id: String) -> String:
	if _org_api == null or not _org_api.has_method("get_organization"):
		return ""
	var info: Dictionary = _org_api.get_organization(squad_id)
	if not info.get("ok", false):
		return ""
	var data: Dictionary = info.get("data", {})
	var current_id: String = String(data.get("id", squad_id))
	# 沿 parent_org 上溯至树根（上限防环；父链断裂按已到层级取根）
	for _i in 8:
		var parent: String = String(data.get("parent_org", ""))
		if parent.is_empty():
			# 根即自身 = 独立 L1，无指挥链可走 → 散兵口径
			return "" if current_id == squad_id else current_id
		var pinfo: Dictionary = _org_api.get_organization(parent)
		if not pinfo.get("ok", false):
			return current_id
		data = pinfo.get("data", {})
		current_id = String(data.get("id", current_id))
	return current_id


## 获取号令名称（供 UI/调试用）
func get_order_name(order_type: int) -> String:
	match order_type:
		OrderType.ADVANCE_ALL: return "ADVANCE_ALL"
		OrderType.SPRINT: return "SPRINT"
		OrderType.HOLD_POSITION: return "HOLD_POSITION"
		OrderType.RETREAT: return "RETREAT"
		OrderType.TAKE_COVER: return "TAKE_COVER"
		OrderType.RALLY: return "RALLY"
		_: return "UNKNOWN"


# ─────────────────────────────── 内部映射 ────────────────────────────────

## 号令类型 -> AIController 行为名
func _order_to_behavior(order_type: int) -> String:
	match order_type:
		OrderType.ADVANCE_ALL, OrderType.RALLY:
			return "move"
		OrderType.SPRINT:
			return "move"
		OrderType.HOLD_POSITION:
			return "idle"
		OrderType.RETREAT:
			return "retreat"
		OrderType.TAKE_COVER:
			return "seek_cover"
		_:
			return "idle"


## 号令类型 -> 行为参数
func _order_to_params(order_type: int, target_pos: Vector2) -> Dictionary:
	match order_type:
		OrderType.ADVANCE_ALL, OrderType.RALLY:
			# engage_in_range：推进途中敌人进入武器射程即停下接战（行为见 behavior_move），
			# 否则 move 行为只认目标点，远程班会被号令拽着冲过射程贴脸（2026-08-31 观察场审计）
			return {"target": target_pos, "engage_in_range": true}
		OrderType.SPRINT:
			return {"target": target_pos, "run": true, "engage_in_range": true}
		OrderType.HOLD_POSITION:
			return {}
		OrderType.RETREAT:
			# battle_instance 由 behavior 自动从 entity 获取；
			# 战役撤离 evacuate=true 经 issue 的 extra_params 增量并入（TeamAi ROUT 姿态）
			return {}
		OrderType.TAKE_COVER:
			return {}
		_:
			return {}


## 号令类型 -> 队伍级目标点分配模式（反编译参考实装 D）：
## "formation" row/col 阵列散开（ADVANCE/SPRINT，11b SWL Formation 直译），
## "rally" 围圈集合，其余不散开。
func _order_to_spread(order_type: int) -> String:
	match order_type:
		OrderType.ADVANCE_ALL, OrderType.SPRINT:
			return "formation"
		OrderType.RALLY:
			return "rally"
		_:
			return ""
