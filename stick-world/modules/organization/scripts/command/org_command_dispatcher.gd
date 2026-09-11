extends RefCounted
## 逐层命令分解器（架构文档 §4.1，3-P 定稿）——"每层 AI 只直接指挥向下一层"（GDD §4.1）。
##
## 职责三分之一：查组织树出**结构**（hop 序列）；不算时间（传输层）、不碰单位（combat 执行）。
## P0 分解语义 = 同令透传：每跳转发的 order 字典不变，延迟由各跳传输层物理传播累积；
## "拿下这个区域→攻这个方向"的语义改写是玩法级 AI，登记开放问题（§七）不在本批。
##
## hop 序列：hop 0 恒为「玩家跳」（from_org="" 表示玩家源，from_tier=0），
## 之后从根组织起 BFS 层序展开（同层按 child_orgs 注册序，稳定可断言），到 L1 截止。

const ScriptOrgState := preload("res://core/entities/organization_state.gd")

## 生成投递计划（§4.1.2 输出 schema）。
## organizations: manager 的组织状态表（key=org_id, value=OrganizationState），只读。
## order: 命令字典（organization 不解释字段，只透传）。
## 返回 Result：ok=true → data={root_org, leaf_orgs, hops}；
## 错误："org_not_found"（不存在/已解散）/ "no_subordinate"（tier>1 但无有效子组织，脏树防御）。
## 纯数据操作：不持有单位引用、不进场景树。
func build_plan(organizations: Dictionary, org_id: String, order: Dictionary) -> Dictionary:
	var root: ScriptOrgState = organizations.get(org_id, null)
	if root == null or root.state == ScriptOrgState.State.DISBANDED:
		return {"ok": false, "error": "org_not_found"}

	var valid_children := _valid_children(organizations, root)
	if root.tier > 1 and valid_children.is_empty():
		return {"ok": false, "error": "no_subordinate"}

	var hops: Array = []
	var leaf_orgs: Array[String] = []
	# hop 0 玩家跳：命令须物理到达根组织指挥官（玩家≠附身该指挥官时吃传播距离，§4.1.2）
	hops.append({
		"from_org": "", "to_org": root.id,
		"from_tier": 0, "to_tier": root.tier,
		"order": order.duplicate(),
	})
	if root.tier <= 1:
		# 目标即 L1：hops = 玩家跳单条，送达即执行（覆盖对 L1 直令，等价旧 issue 玩家路径）
		leaf_orgs.append(root.id)
		return {"ok": true, "data": {"root_org": root.id, "leaf_orgs": leaf_orgs, "hops": hops}}

	# BFS 层序：先根后叶、同层按 child_orgs 注册序（队列先进先出天然保序）
	var queue: Array = [root]
	while not queue.is_empty():
		var current: ScriptOrgState = queue.pop_front()
		for child in _valid_children(organizations, current):
			hops.append({
				"from_org": current.id, "to_org": child.id,
				"from_tier": current.tier, "to_tier": child.tier,
				"order": order.duplicate(),
			})
			if child.tier <= 1:
				leaf_orgs.append(child.id)
			else:
				queue.append(child)

	return {"ok": true, "data": {"root_org": root.id, "leaf_orgs": leaf_orgs, "hops": hops}}


## 非解散且存在的子组织列表（保持 child_orgs 注册序）
func _valid_children(organizations: Dictionary, org: ScriptOrgState) -> Array:
	var children: Array = []
	for child_id in org.child_orgs:
		var child: ScriptOrgState = organizations.get(child_id, null)
		if child == null or child.state == ScriptOrgState.State.DISBANDED:
			continue
		children.append(child)
	return children
