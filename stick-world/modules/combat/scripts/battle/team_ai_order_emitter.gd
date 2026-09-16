extends RefCounted
## 姿态号令下发 -- team_ai.gd 拆分件（W2 胖文件拆分，行为直搬）。
##
## 职责：TeamAi 的唯一号令执行通道——姿态 → 号令映射（_issue_stance_orders）、
## 攻击槽重定向重发（issue_retarget_orders）、逐小队下发出口（issue_orders，
## 含玩家手动号令保护期避让与组织化编制/散兵路径分流）。只消费 TacticalOrders，
## 不改号令系统行为。
##
## 下令路径收敛（设计文档 §四）：组织化编制经 issue_to_org 逐跳传播（编制=原子，
## 同根一号令一轮内去重）；散兵经 issue 直令（现场电台零延迟）。玩家手动号令
## 保护期 > 姿态自动号令。常规姿态仅切换时下发一次（维持期不重发，防号令风暴）；
## ROUT 例外——维持期由宿主 stance_update 每决策周期重发；攻击槽目标超时重定向
## 由 issue_retarget_orders 重发绑定小队。
##
## 拆分纪律：本类持宿主回引（_host）；姿态/任务槽板/保护期时间戳/快照全在宿主
## ——姿态切换事件（EventBus.team_ai_stance_changed）的发射点在宿主 _set_stance，
## 本类只负责其后的号令映射下发。依赖同伴：team_ai_squad_query（小队/组织根/
## 原子分组取数）、team_ai_behavior_hooks（default_behavior v2 无令小队接管）。
## 装配序 query/hooks 先于本类；依赖无环（本类不回依 slot_kernel，重定向由
## kernel 调本类）。

## 同模块号令脚本（OrderType 枚举消费；combat 域内 preload 惯例）
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")
## 同模块任务槽板（KIND_ATTACK 判定消费）
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")

## 宿主 TeamAi 回引（姿态/任务槽板/保护期状态/快照全在宿主）
var _host: Variant = null
## 同伴：小队/编制视图取数（本方小队列表、原子分组、组织根）
var _squads: Variant = null
## 同伴：default_behavior v2 接入（无显式号令小队的效用打分接管）
var _hooks: Variant = null


## 装配：注入宿主回引与同伴（TeamAi.setup 内调用；query/hooks 须先装配）
func setup(host: Variant, squads: Variant, hooks: Variant) -> void:
	_host = host
	_squads = squads
	_hooks = hooks


## 姿态→号令映射器（TeamAi 的唯一执行通道：只消费 TacticalOrders，不改号令系统行为）。
## A2 槽内核（ATTACK 态）：小队经 match_groups 匹配任务槽——攻击槽绑定小队 →
## ADVANCE_ALL 槽目标（评分最优敌位）；未绑定/防守槽 → ADVANCE_ALL 本方质心
## （防守位兜底）。DEFEND → ADVANCE_ALL 本方质心（回聚合防线坚守，不消费槽）；
## GARRISON → RALLY 己方锚点（围圈驻点，生存模式不走槽）；ROUT → RETREAT(evacuate)
## 全军战役撤离（撤至己方侧边缘登记 departed，C3 敌将撤仗）。
## 下令路径收敛（设计文档 §四）：组织化编制经 issue_to_org 逐跳传播（编制=原子，
## 同根一号令一轮内去重）；散兵经 issue 直令（现场电台零延迟）。玩家手动号令
## 保护期 > 姿态自动号令：散兵逐队避让；编制任一成员保护期内整组避让（玩家意图
## 压过编制号令，下轮姿态切换/槽重发恢复）。
## 常规姿态仅切换时下发一次（维持期不重发，防号令风暴）；ROUT 例外——维持期由
## stance_update 每决策周期重发（溃逃抢占兜底，见 §4.2）；攻击槽目标超时重定向
## 由 issue_retarget_orders 重发绑定小队。
func issue_stance_orders() -> void:
	if _host._stance == _host.STANCE_ROUT:
		issue_orders(_squads.own_combat_squads(), {}, ScriptTacticalOrders.OrderType.RETREAT,
				Vector2.ZERO, {"evacuate": true})
		return
	var squads: Array = _squads.own_combat_squads()
	if squads.is_empty():
		return
	# 执行侧小队匹配（A2 C3）：序位在前攻击槽数的原子单元组绑攻击槽，其余绑防守
	var mapping: Dictionary = {}
	if _host._task_board_enabled():
		mapping = _host._task_board.match_groups(_squads.atomic_groups())
	var plan_of: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		# 原宿主 match _stance 分支的 if/elif 直译（拆分后姿态常量经宿主读取，
		# match 模式要求常量表达式，实例访问不合法——语义逐位等价，空 else 同 `_:` pass）
		var stance: int = _host._stance
		if stance == _host.STANCE_ATTACK:
			var target: Vector2 = _host._enemy_centroid  # 退化语义（槽内核关闭时旧目标）
			if _host._task_board_enabled():
				# 槽驱动：攻击槽绑定 → 槽目标；未绑定/防守槽 → 本方质心防守位
				target = _host._own_centroid
				var slot: Variant = _host._task_board.get_slot(str(mapping.get(squad_id, "")))
				if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
					target = slot.target
			plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": target}
		elif stance == _host.STANCE_DEFEND:
			plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": _host._own_centroid}
		elif stance == _host.STANCE_GARRISON:
			plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.RALLY, "target": _host.get_garrison_anchor()}
		# A4 default_behavior v2：无显式号令（防守兜底/未绑定）小队按效用打分选行为
		# （追加钩子，开关默认关 = 原样返回零回归；见 apply_default_behavior_plans）
		plan_of = _hooks.apply_default_behavior_plans(plan_of, mapping)
	issue_orders(squads, plan_of)


## 攻击槽目标重定向重发（TaskBoard.tick 目标超时 → 脏槽的绑定小队向新目标推进）
func issue_retarget_orders(dirty_slot_ids: Array) -> void:
	var squads: Array = _squads.own_combat_squads()
	if squads.is_empty() or dirty_slot_ids.is_empty():
		return
	var plan_of: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		var slot_id = _host._task_board.slot_of_squad(squad_id)
		if slot_id.is_empty() or not dirty_slot_ids.has(slot_id):
			continue
		var slot: Variant = _host._task_board.get_slot(slot_id)
		if slot == null:
			continue
		plan_of[squad_id] = {"order_type": ScriptTacticalOrders.OrderType.ADVANCE_ALL, "target": slot.target}
	if not plan_of.is_empty():
		issue_orders(squads, plan_of)


## 号令下发执行（唯一出口）：逐小队查计划 → 手动号令保护期避让 → 路径分流。
## plan_of 为空且给定 order_type 时全员同令（ROUT 撤离路径）。
## 保护期语义：散兵逐队避让；编制组（同组织根）任一成员在保护期内 → 整组避让。
## 路径分流：有组织根 ∧ 号令系统支持 issue_to_org → 编制根一号令（同根去重）；
## 否则散兵 issue 直令。issue 拒绝（职责校验/空队）→ 跳过不重试，下一决策周期
## 随姿态重评自然恢复（既有口径）。
func issue_orders(squads: Array, plan_of: Dictionary, order_type: int = -1,
		target: Vector2 = Vector2.ZERO, extra_params: Dictionary = {}) -> void:
	if _host._orders == null or not is_instance_valid(_host._orders) or not _host._orders.has_method("issue"):
		return
	var issued_roots: Dictionary = {}
	for squad_id_v in squads:
		var squad_id := str(squad_id_v)
		# 玩家手动号令保护期：玩家手动号令 > 姿态自动号令（硬约束，spec §5.2.1.2a）
		if _host._is_manual_order_active(squad_id):
			continue
		var root = _squads.org_root_of(squad_id)
		if not root.is_empty():
			# 编制原子性守卫：组内任一成员保护期内 → 整组本轮避让
			var group_guarded: bool = false
			for other_v in squads:
				var other := str(other_v)
				if other != squad_id and _host._is_manual_order_active(other) and _squads.org_root_of(other) == root:
					group_guarded = true
					break
			if group_guarded:
				continue
			# 同根一号令（编制行军原子；issue_to_org 计划天然覆盖组内全部 L1）
			if issued_roots.has(root):
				continue
			issued_roots[root] = true
		var p_order: int = order_type
		var p_target: Vector2 = target
		var p_extra: Dictionary = extra_params
		if not plan_of.is_empty():
			var plan: Dictionary = plan_of.get(squad_id, {})
			if plan.is_empty():
				continue
			p_order = int(plan.get("order_type", order_type))
			p_target = plan.get("target", target)
			p_extra = plan.get("extra", {})
		if p_order < 0:
			continue
		if not root.is_empty() and _host._orders.has_method("issue_to_org"):
			# 组织化编制：走 org 入口逐跳传播（号令语义参数增量随计划透传）
			_host._orders.issue_to_org(root, p_order, p_target, p_extra)
		else:
			_host._orders.issue(p_order, squad_id, p_target, _host.SOURCE_TIER_AI, p_extra)
