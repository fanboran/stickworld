extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：OrgCommandDispatcher 逐层命令分解（架构文档 §4.1，3-P 定稿）。
## 玩家跳 + BFS 层序 + 错误码 + DISBANDED 跳过 + 同令透传。纯数据层，不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("Dispatcher: 单链树 L3→L2→L1（玩家跳+2 跳层序）", _test_single_chain)
	_runner.add_test("Dispatcher: 多分支树 BFS 序/child_orgs 稳定序/leaf_orgs 完整", _test_multi_branch)
	_runner.add_test("Dispatcher: 目标即 L1（hops = 玩家跳单条）", _test_target_is_l1)
	_runner.add_test("Dispatcher: org_not_found（不存在/已解散）", _test_org_not_found)
	_runner.add_test("Dispatcher: no_subordinate（tier>1 无有效子组织）", _test_no_subordinate)
	_runner.add_test("Dispatcher: DISBANDED 子树跳过", _test_disbanded_subtree_skip)
	_runner.add_test("Dispatcher: 同令透传（每跳 order 与入参逐项相等）", _test_order_passthrough)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────── fixtures ───────────────

## 单链：团(L3) → 连(L2) → 排(L1)
func _build_chain() -> Dictionary:
	var m: ScriptOrgManager = ScriptOrgManager.new()
	var r_root: Dictionary = m.create_organization("团", "MILITARY", 3, "")
	var r_mid: Dictionary = m.create_organization("连", "MILITARY", 2, r_root.data.org_id)
	var r_leaf: Dictionary = m.create_organization("排", "MILITARY", 1, r_mid.data.org_id)
	return {"m": m, "root": r_root.data.org_id, "mid": r_mid.data.org_id, "leaf": r_leaf.data.org_id}

## 多分支：团(L3) → 连A(L2)/连B(L2) → 排A1/排A2(L1)/排B1(L1)
func _build_branching() -> Dictionary:
	var m: ScriptOrgManager = ScriptOrgManager.new()
	var root: String = m.create_organization("团", "MILITARY", 3, "").data.org_id
	var c1: String = m.create_organization("一连", "MILITARY", 2, root).data.org_id
	var c2: String = m.create_organization("二连", "MILITARY", 2, root).data.org_id
	var c1a: String = m.create_organization("一排", "MILITARY", 1, c1).data.org_id
	var c1b: String = m.create_organization("二排", "MILITARY", 1, c1).data.org_id
	var c2a: String = m.create_organization("三排", "MILITARY", 1, c2).data.org_id
	return {"m": m, "root": root, "c1": c1, "c2": c2, "c1a": c1a, "c1b": c1b, "c2a": c2a}


# ─────────────── tests ───────────────

func _test_single_chain() -> void:
	var fx := _build_chain()
	var plan: Dictionary = fx.m.build_dispatch_plan(fx.root, {"order_type": 0})
	_runner.assert_true(plan.get("ok", false), "单链树计划应成功: " + str(plan))
	var data: Dictionary = plan.data
	_runner.assert_equal(String(data.root_org), fx.root, "root_org 应为入参组织")
	_runner.assert_equal(data.leaf_orgs, [fx.leaf] as Array[String], "leaf_orgs 应只含 L1 叶")
	var hops: Array = data.hops
	_runner.assert_equal(hops.size(), 3, "单链应 3 跳（玩家跳+2 跳）")
	_runner.assert_equal(String(hops[0].from_org), "", "hop0 应为玩家跳（空源）")
	_runner.assert_equal(int(hops[0].from_tier), 0, "玩家跳 from_tier=0")
	_runner.assert_equal(String(hops[0].to_org), fx.root, "hop0 送达根组织")
	_runner.assert_equal(int(hops[0].to_tier), 3, "hop0 to_tier=3")
	_runner.assert_equal(String(hops[1].from_org), fx.root, "hop1 从根组织出发")
	_runner.assert_equal(String(hops[1].to_org), fx.mid, "hop1 送达 L2")
	_runner.assert_equal(int(hops[1].from_tier), 3, "hop1 层级递降 3→2")
	_runner.assert_equal(String(hops[2].to_org), fx.leaf, "hop2 送达 L1")
	_runner.assert_equal(int(hops[2].to_tier), 1, "hop2 to_tier=1")


func _test_multi_branch() -> void:
	var fx := _build_branching()
	var plan: Dictionary = fx.m.build_dispatch_plan(fx.root, {"order_type": 0})
	_runner.assert_true(plan.get("ok", false), "多分支树计划应成功")
	var hops: Array = plan.data.hops
	# BFS 层序：玩家跳 → root→c1 → root→c2 → c1→c1a → c1→c1b → c2→c2a
	var seq: Array = []
	for h in hops:
		seq.append("%s>%s" % [h.from_org, h.to_org])
	var expected: Array = [
		">%s" % fx.root, "%s>%s" % [fx.root, fx.c1], "%s>%s" % [fx.root, fx.c2],
		"%s>%s" % [fx.c1, fx.c1a], "%s>%s" % [fx.c1, fx.c1b], "%s>%s" % [fx.c2, fx.c2a],
	]
	_runner.assert_equal(seq, expected, "BFS 层序 + child_orgs 注册序稳定")
	_runner.assert_equal(plan.data.leaf_orgs, [fx.c1a, fx.c1b, fx.c2a] as Array[String], "leaf_orgs 完整且按 BFS 序")


func _test_target_is_l1() -> void:
	var fx := _build_chain()
	var plan: Dictionary = fx.m.build_dispatch_plan(fx.leaf, {"order_type": 0})
	_runner.assert_true(plan.get("ok", false), "对 L1 直令应成功")
	var hops: Array = plan.data.hops
	_runner.assert_equal(hops.size(), 1, "目标即 L1：hops = 玩家跳单条")
	_runner.assert_equal(String(hops[0].to_org), fx.leaf, "玩家跳直达 L1")
	_runner.assert_equal(plan.data.leaf_orgs, [fx.leaf] as Array[String], "L1 自身即执行叶")


func _test_org_not_found() -> void:
	var fx := _build_chain()
	var plan: Dictionary = fx.m.build_dispatch_plan("org_nope", {"order_type": 0})
	_runner.assert_false(plan.get("ok", true), "未知组织应失败")
	_runner.assert_equal(String(plan.get("error", "")), "org_not_found", "错误码 org_not_found")
	# 已解散等同不存在（解散即从容器移除，防御性口径）
	var plan2: Dictionary = fx.m.build_dispatch_plan(fx.leaf, {"order_type": 0})
	_runner.assert_true(plan2.get("ok", false), "存在组织应成功")


func _test_no_subordinate() -> void:
	var fx := _build_chain()
	# 中间层连(L2) 若无子组织（脏树防御，正常父先于子创建时 L2 必有 L1 或不可达）
	var m: ScriptOrgManager = ScriptOrgManager.new()
	var lonely: String = m.create_organization("空架子", "MILITARY", 2, "").data.org_id
	var plan: Dictionary = m.build_dispatch_plan(lonely, {"order_type": 0})
	_runner.assert_false(plan.get("ok", true), "tier>1 无有效子组织应失败")
	_runner.assert_equal(String(plan.get("error", "")), "no_subordinate", "错误码 no_subordinate")


func _test_disbanded_subtree_skip() -> void:
	var fx := _build_branching()
	# 二连子树解散（节点状态置 DISBANDED，防雾口径：dispatcher 跳过不报错不投递）
	fx.m.organizations[fx.c2].state = 4  # OrganizationState.State.DISBANDED
	var plan: Dictionary = fx.m.build_dispatch_plan(fx.root, {"order_type": 0})
	_runner.assert_true(plan.get("ok", false), "存在有效子树应成功")
	var tos: Array = []
	for h in plan.data.hops:
		tos.append(String(h.to_org))
	_runner.assert_false(tos.has(fx.c2), "DISBANDED 子树根不应出现在 hops")
	_runner.assert_false(tos.has(fx.c2a), "DISBANDED 子树成员不应出现在 hops")
	_runner.assert_equal(plan.data.leaf_orgs, [fx.c1a, fx.c1b] as Array[String], "leaf_orgs 只含存活分支")
	# 根自身 DISBANDED → org_not_found（对消费方而言组织已不存在）
	fx.m.organizations[fx.root].state = 4
	var plan2: Dictionary = fx.m.build_dispatch_plan(fx.root, {"order_type": 0})
	_runner.assert_false(plan2.get("ok", true), "根 DISBANDED 应按不存在处理")
	_runner.assert_equal(String(plan2.get("error", "")), "org_not_found", "根解散错误码 org_not_found")


func _test_order_passthrough() -> void:
	var fx := _build_branching()
	var order := {"order_type": 3, "target_pos": Vector2(500, 300), "extra": "x"}
	var plan: Dictionary = fx.m.build_dispatch_plan(fx.root, order)
	_runner.assert_true(plan.get("ok", false), "计划应成功")
	for h in plan.data.hops:
		_runner.assert_equal(h.order, order, "每跳 order 与入参逐项相等（同令透传，含 target_pos）")
	# 透传应为副本：改动计划内 order 不影响入参（防共享引用别名）
	var hop0: Dictionary = plan.data.hops[0]
	hop0.order["order_type"] = 99
	_runner.assert_equal(int(order.order_type), 3, "hop order 是入参副本，不回写污染")
