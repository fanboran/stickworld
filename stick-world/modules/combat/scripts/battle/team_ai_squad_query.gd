extends RefCounted
## 小队/编制视图取数 -- team_ai.gd 拆分件（W2 胖文件拆分，行为直搬）。
##
## 职责：TeamAi 对编队系统（FormationSystem）与号令系统（TacticalOrders）的
## 全部小队级 duck 取数口——本方战斗小队列表、编制原子单元分组、组织根查询、
## 小队质心/存活判定。纯读视图，无决策逻辑、无状态（状态全在宿主 TeamAi）。
##
## 拆分纪律：本类持宿主回引（_host），不持 formation/orders 引用——经宿主字段
## 透传，引用补注入（set_order_refs）即全局生效；跨模块 duck 消费面
## （get_squad_units / get_all_squads / is_combat_squad / get_org_root_for_squad）
## 签名与调用路径逐位不变。
##
## 消费方：TeamAi 姿态编排（宿主壳转发）、team_ai_slot_kernel（槽期望数基数）、
## team_ai_order_emitter（号令下发取小队/组织根）、team_ai_behavior_hooks
## （default_behavior 上下文）。装配序最底（无同伴依赖）。

## 宿主 TeamAi 回引（duck 引用；状态字段/号令编队引用全在宿主）
var _host: Variant = null


## 装配：注入宿主回引（TeamAi.setup 内调用；仅持引用，无副作用）
func setup(host: Variant) -> void:
	_host = host


## 原子单元数（槽期望数基数）：组织化编制作一处（编制行军原子）、散兵各一处；
## 编队系统缺失（测试环境）或本方暂无注册小队 → 退化 1（槽逻辑照跑，与 SWL
## 内核"无小队仍切姿态"行为一致；号令侧无小队可发，自然空转）。
func count_atomic_units() -> int:
	if _host._formation == null or not is_instance_valid(_host._formation) \
			or not _host._formation.has_method("get_all_squads"):
		return 1
	var n := atomic_groups().size()
	return n if n > 0 else 1


## 原子单元分组（下令路径与槽匹配共用）：组织化编制 = 同组织根的小队一组，
## 散兵各成一组。返回 [{key, squads}]（key = 组织根 id，散兵 = squad_id 自身）。
func atomic_groups() -> Array:
	var groups: Array = []
	var by_root: Dictionary = {}
	for squad_id_v in own_combat_squads():
		var squad_id := str(squad_id_v)
		var root := org_root_of(squad_id)
		if root.is_empty():
			groups.append({"key": squad_id, "squads": [squad_id]})
			continue
		if not by_root.has(root):
			var g := {"key": root, "squads": []}
			by_root[root] = g
			groups.append(g)
		(by_root[root]["squads"] as Array).append(squad_id)
	return groups


## 小队所在组织根（号令系统代理查询；orders 缺失/无代理方法 → "" 散兵口径，
## combat 不直引 organization——模块契约，见 TacticalOrders.get_org_root_for_squad）
func org_root_of(squad_id: String) -> String:
	if _host._orders == null or not is_instance_valid(_host._orders) \
			or not _host._orders.has_method("get_org_root_for_squad"):
		return ""
	return String(_host._orders.get_org_root_for_squad(squad_id))


## 本阵营战斗小队列表（执行侧匹配与号令的统一取数口；序 = 编队注册序，稳定可断言）
func own_combat_squads() -> Array:
	if _host._formation == null or not is_instance_valid(_host._formation) \
			or not _host._formation.has_method("get_all_squads"):
		return []
	var result: Array = []
	for squad_id_v in _host._formation.get_all_squads():
		var squad_id := str(squad_id_v)
		if is_own_combat_squad(squad_id):
			result.append(squad_id)
	return result


## 本阵营战斗小队判定：成员 get_faction 多数派 == 本阵营 ∧ is_combat_squad。
## 小队无阵营归属字段（FormationSystem 全局单例），多数派判定稳定（战斗中 faction 固定）。
func is_own_combat_squad(squad_id: String) -> bool:
	if _host._formation == null or not is_instance_valid(_host._formation):
		return false
	if _host._formation.has_method("is_combat_squad") and not _host._formation.is_combat_squad(squad_id):
		return false
	if not _host._formation.has_method("get_squad_units"):
		return false
	var units: Array = _host._formation.get_squad_units(squad_id)
	if units.is_empty():
		return false
	var own: int = 0
	var total: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("get_faction"):
			continue
		total += 1
		if int(u.get_faction()) == _host._faction:
			own += 1
	if total <= 0:
		return false
	return own * 2 > total


## 小队是否有存活战斗成员（空队/全灭队不调 issue，避免号令系统 push_warning 噪音）
func squad_has_alive_combatant(squad_id: String) -> bool:
	if _host._formation == null or not is_instance_valid(_host._formation) or not _host._formation.has_method("get_squad_units"):
		return false
	for u in _host._formation.get_squad_units(squad_id):
		if u != null and is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			return true
	return false


## 小队存活成员质心（编队缺失/空队退化本方质心——与防守兜底目标语义一致）
func squad_centroid(squad_id: String) -> Vector2:
	if _host._formation == null or not is_instance_valid(_host._formation) \
			or not _host._formation.has_method("get_squad_units"):
		return _host._own_centroid
	var sum := Vector2.ZERO
	var n: int = 0
	for u in _host._formation.get_squad_units(squad_id):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		sum += u.global_position if u is Node2D else Vector2.ZERO
		n += 1
	return sum / float(n) if n > 0 else _host._own_centroid
