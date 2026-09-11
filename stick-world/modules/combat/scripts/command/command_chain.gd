class_name CommandChain
extends Node
## 指挥链 -- 号令送达执行器 + 组织级逐层接力（架构文档 §4.2.4，3-F2 职责重划）。
##
## 职责三分（3-P 定稿）：dispatcher 出结构（hop 计划）/ transport 出秒数（物理传播）
## / 本类只**执行**：
##   - deliver()：即时送达执行器（units 解析 + spread 散点 + set_order）。旧
##     base_delay × tier_diff 抽象公式已退役（docs/技术/架构/组织系统架构.md §4.2），
##     延迟唯一来源 = 传输层物理传播；source_tier/squad_tier 参数保留签名兼容。
##   - deliver_via_orgs()：按 dispatcher 的 hop 计划逐层接力——每跳传播秒数取自
##     传输层（org_api.get_delivery_time），L1 送达即时执行 deliver，中间层无实体
##     动作（同令透传的下一跳由接力结构本身完成）；伤亡空缺的中间层命令停驻丢弃
##     （§4.3.1 续传裁决）。
##
## 玩家微操（issue source_tier=0 对 L1 直令）与战场本地 AI（team_ai 对眼前小队下令）
## 均零延迟 = 现场指挥；跨组织层级的传播延迟只发生在 issue_to_org 接力链上。

# ─────────────────────────────── 信号 ────────────────────────────────
## 号令已送达单位
signal order_delivered(order_type: int, squad_id: String, unit_ids: Array)

# ─────────────────────────────── 运行时 ────────────────────────────────
## FormationSystem 引用（队内目标点分配用；由装配注入）
var _formation: Node = null


## 注入 FormationSystem 引用（system_setup 装配时调用）。
func setup_formation(formation: Node) -> void:
	_formation = formation


# ─────────────────────────────── 核心 API ────────────────────────────────

## 下达号令到指定单位列表（恒即时送达——延迟由传输层在接力链上承担）。
## order_type: TacticalOrders.OrderType
## squad_id: 目标小队 ID
## units: StickmanEntity 节点数组
## behavior_name: 要设置的行为名（如 "move", "idle", "retreat"）
## params: 行为参数（如 {"target": Vector2}）
## source_tier/squad_tier: 签名兼容保留（旧延迟公式已退役，不再参与计算）
## spread_mode: 队伍级目标点分配（反编译参考实装 D）：
##   "formation" row/col 阵列（推进/冲刺）/ "line" 横排散开 / "rally" 围圈（集合）/ "" 不散开。
func deliver(order_type: int, squad_id: String, units: Array, behavior_name: String, params: Dictionary, source_tier: int = 0, squad_tier: int = 1, spread_mode: String = "") -> void:
	_execute_delivery(order_type, squad_id, units, behavior_name, params, spread_mode)


## 组织级逐层接力投递（§4.2.4 协程，TacticalOrders.issue_to_org 入口调用）。
## plan: OrgApi.build_dispatch_plan 的 data（root_org/leaf_orgs/hops，hop 0 玩家跳）。
## org_api: organization 公共接口（get_delivery_time 传输计时 + get_organization 结构查询）。
## 传播模型：时刻 0 发出玩家跳 → 根组织送达时刻启动其全部出跳并行接力
## （多分支各自独立计时；同链路径上 L1 收令时刻 = 沿途各跳延迟之和）。
func deliver_via_orgs(plan: Dictionary, org_api: Node, order_type: int, behavior_name: String, params: Dictionary, spread_mode: String) -> void:
	if org_api == null:
		push_warning("[CommandChain] deliver_via_orgs 缺少 org_api 引用")
		return
	# hops 按 from_org 索引：某组织送达时刻即可启动它的全部出跳（多分支并行）
	var by_source: Dictionary = {}
	for hop in plan.get("hops", []):
		var key: String = String(hop.get("from_org", ""))
		if not by_source.has(key):
			by_source[key] = []
		by_source[key].append(hop)
	# hop 0 玩家跳（from_org == "" 表示玩家源，§4.1.2）：时刻 0 发出
	for hop in by_source.get("", []):
		var root_org: String = String(hop.get("to_org", ""))
		if root_org.is_empty():
			continue
		var delay: float = _hop_delay(org_api, "", root_org)
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
		_arrive_at_org(root_org, by_source, org_api, order_type, behavior_name, params, spread_mode)


# ─────────────────────────────── 内部 ────────────────────────────────

## 一跳传播秒数（org_api 未提供 get_delivery_time 时按 0 = 即时，装配退化安全）
func _hop_delay(org_api: Node, from_org: String, to_org: String) -> float:
	if org_api != null and org_api.has_method("get_delivery_time"):
		return maxf(0.0, float(org_api.get_delivery_time(from_org, to_org)))
	return 0.0


## 某 to_org 的送达时刻语义（§4.2.4）：
##   L1 → 战斗职责校验（非战斗叶拒收）+ 解析小队成员，即时执行送达；
##   中间层 → 无实体动作（不做决策）；伤亡空缺（无指挥官，补位无人）→ 命令停驻丢弃；
##   已解散/不存在 → 送达即丢弃（dispatcher DISBANDED 跳过同口径的运行时兜底）。
func _arrive_at_org(org_id: String, by_source: Dictionary, org_api: Node, order_type: int, behavior_name: String, params: Dictionary, spread_mode: String) -> void:
	if not org_api.has_method("get_organization"):
		return
	var info: Dictionary = org_api.get_organization(org_id)
	if not info.get("ok", false):
		return
	var data: Dictionary = info.get("data", {})
	if int(data.get("tier", 1)) <= 1:
		_deliver_to_l1_squad(org_id, order_type, behavior_name, params, spread_mode)
		return
	# 中间层伤亡空缺（§4.3.1 续传裁决）：旧指挥官没收到/没转发的命令在模拟中不存在——
	# 直接丢弃，不做队列/续传；新指挥官上任后由下令方重发（team_ai 周期重评估天然覆盖）
	if String(data.get("commander_id", "")).is_empty():
		return
	for hop in by_source.get(org_id, []):
		var child_org: String = String(hop.get("to_org", ""))
		if child_org.is_empty():
			continue
		_relay_child(org_id, child_org, by_source, org_api, order_type, behavior_name, params, spread_mode)


## 单条出跳的传播协程：延迟到点后送达 to_org（不 await 的调用 = 并行分支，各自独立计时）
func _relay_child(from_org: String, to_org: String, by_source: Dictionary, org_api: Node, order_type: int, behavior_name: String, params: Dictionary, spread_mode: String) -> void:
	var delay: float = _hop_delay(org_api, from_org, to_org)
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	_arrive_at_org(to_org, by_source, org_api, order_type, behavior_name, params, spread_mode)


## L1 送达执行（§4.2.4）：非战斗叶拒收号令（照 issue 既有 is_combat_squad 口径，
## plan 不挡、送达时挡——组织树可能混编）；无小队/无成员（跨图残留、编制空架）静默丢弃。
func _deliver_to_l1_squad(org_id: String, order_type: int, behavior_name: String, params: Dictionary, spread_mode: String) -> void:
	if _formation == null:
		return
	if _formation.has_method("is_combat_squad") and not _formation.is_combat_squad(org_id):
		push_warning("[CommandChain] 组织 %s 无战斗职责，拒收号令" % org_id)
		return
	var units: Array = _formation.get_squad_units(org_id)
	if units.is_empty():
		return
	_execute_delivery(order_type, org_id, units, behavior_name, params, spread_mode)


## 实际执行号令送达：设置每个单位的 AIController 命令。
## spread_mode 非空且有 formation 时，为每个单位个性化目标点（队内散开）。
func _execute_delivery(order_type: int, squad_id: String, units: Array, behavior_name: String, params: Dictionary, spread_mode: String = "") -> void:
	var unit_ids: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai != null and ai.has_method("set_order"):
			# 队伍级目标点分配：复制 params 再个性化 target（不污染共享字典）
			var p: Dictionary = params
			if _formation != null and not spread_mode.is_empty() and p.has("target"):
				p = params.duplicate()
				var dest: Vector2 = _formation.get_squad_dest(squad_id, u, p["target"], spread_mode)
				p["target"] = dest
			ai.set_order(behavior_name, p)
		unit_ids.append(u.get_instance_id())
	order_delivered.emit(order_type, squad_id, unit_ids)
