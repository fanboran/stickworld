extends RefCounted
## 补位引擎（架构文档 §4.3.1，3-P 定稿）—— 从 organization_manager.gd 拆出的子域。
##
## 触发点内聚在宿主 remove_stickman/remove_commander（被移除者 == commander 时自动
## 补位）；死亡/调离/手工撤职同一入口。伤亡是唯一的"位置事实空缺"来源（过渡态），
## 补上的人就是真指挥官。
##
## 构造姿势（command/ 域惯例，纯算法无宿主回引）：组织表经方法参数传入（同
## org_command_dispatcher.build_plan 的 organizations 形参）；cmd 属性 provider 装配
## 注入持本实例（同 transport_layer）；report_filed 信号属宿主 api 转发面（api.setup
## 转发到公共信号），由宿主调用时以 Signal 值传入，引擎不持宿主。

const ScriptOrgState := preload("res://core/entities/organization_state.gd")

## cmd 属性查询（补位排序用，§4.3.1）：装配层实现 instance_from_id → attributes.cmd，
## 失败返回 -1 沉底；未注入时全员 -1 → 平局按池序
var _attribute_provider: Callable = Callable()


## 装配注入 cmd 属性查询（补位排序用，§4.3.1）——经宿主 set_attribute_provider 转发
func set_attribute_provider(provider: Callable) -> void:
	_attribute_provider = provider


## 补位候选序（[{id, cmd}, ...] 按 cmd 降序，平局按池序稳定）——OrgPanel 展示/测试断言
func get_succession_candidates(organizations: Dictionary, org_id: String) -> Array[Dictionary]:
	var org: ScriptOrgState = organizations.get(org_id, null)
	if org == null:
		return []
	return _succession_pool(organizations, org, org.commander_id)


## 候选池 = personnel ∪ 直接子组织 commander（去重、剔空串、剔除被移除者），
## L1 自然退化为班内成员，中间层自然退化为下级指挥官（§4.3.1 第 3 条）
func _succession_pool(organizations: Dictionary, org: ScriptOrgState, exclude_id: String) -> Array[Dictionary]:
	var pool: Array = []
	var seen := {}
	var order := 0
	for sid in org.personnel:
		var member := str(sid)
		if member == "" or member == exclude_id or seen.has(member):
			continue
		seen[member] = true
		pool.append({"id": member, "cmd": _cmd_attribute(member), "order": order})
		order += 1
	for child_id in org.child_orgs:
		var child: ScriptOrgState = organizations.get(child_id, null)
		if child == null:
			continue
		var cid := child.commander_id
		if cid == "" or cid == exclude_id or seen.has(cid):
			continue
		seen[cid] = true
		pool.append({"id": cid, "cmd": _cmd_attribute(cid), "order": order})
		order += 1
	# cmd 降序；平局按池序稳定（personnel 先于子指挥官）——sort_custom 不保证稳定，用 order 做次级键
	pool.sort_custom(func(a, b):
		if a.cmd != b.cmd:
			return a.cmd > b.cmd
		return a.order < b.order)
	var result: Array[Dictionary] = []
	for p in pool:
		result.append({"id": p.id, "cmd": p.cmd})
	return result


## cmd 属性查询：provider 缺失/异常 → -1 沉底（平局按池序）
func _cmd_attribute(stickman_id: String) -> float:
	if not _attribute_provider.is_valid():
		return -1.0
	var value: Variant = _attribute_provider.call(stickman_id)
	if value is float or value is int:
		return float(value)
	return -1.0


## 补位主流程（§4.3.1）：RANK_HIGHEST 自动补位；PLAYER_CHOSEN/NONE 保持空缺等任命；
## 成功补位发 EventBus.commander_assigned（battle_panel 已消费，3-F2 FormationSystem 订阅回写）；
## commander_lost 上报必报型——无视 autonomy 门控（§4.4）。
## report_signal = 宿主 report_filed 信号（Signal 值传入）。
## 返回 {filled, successor_id}（供测试断言）。
func run_succession(organizations: Dictionary, org: ScriptOrgState, prev_commander_id: String,
		report_signal: Signal) -> Dictionary:
	var filled := false
	var successor := ""
	if org.succession_rule == ScriptOrgState.SuccessionRule.RANK_HIGHEST:
		var pool := _succession_pool(organizations, org, prev_commander_id)
		if not pool.is_empty():
			successor = pool[0]["id"]
			org.commander_id = successor
			filled = true
			var unit_id := successor.to_int()
			if unit_id > 0:
				EventBus.commander_assigned.emit(org.id, unit_id)
	report_signal.emit(org.id, {
		"type": "commander_lost",
		"filed_at": Time.get_ticks_msec(),
		"payload": {"prev_commander_id": prev_commander_id, "filled": filled, "successor_id": successor},
	})
	return {"filled": filled, "successor_id": successor}
