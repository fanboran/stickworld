extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：OrganizationManager 组织 CRUD/层级/人事/序列化逻辑。
## 纯数据层（RefCounted）测试：new 即用，不进场景树，确定性。
## 2026-08 补充：此前 424 行核心逻辑零测试触点（含 insert_tier 修复回归）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptOrgState := preload("res://core/entities/organization_state.gd")
const ScriptWS := preload("res://core/autoload/world_state.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("Org: 合法创建返回递增 org_id", _test_create_ok)
	_runner.add_test("Org: 无效层级/标签失败", _test_create_invalid)
	_runner.add_test("Org: 父组织校验（不存在/层级不连续）", _test_create_parent_validate)
	_runner.add_test("Org: 查询与子组织列表", _test_query)
	_runner.add_test("Org: 按标签/区域查询", _test_query_by_tag_region)
	_runner.add_test("Org: 编制模板与自主权限", _test_templates_autonomy)
	_runner.add_test("Org: 指挥官任免", _test_commander)
	_runner.add_test("Org: 人员分配/移除（重复/不存在边界）", _test_stickman_assign)
	_runner.add_test("Org: insert_tier above 连续层级拒绝（不变量）", _test_insert_tier_above)
	_runner.add_test("Org: insert_tier below 挂到目标组织之下", _test_insert_tier_below)
	_runner.add_test("Org: insert_tier 边界失败（根组织/无效位置/跳级）", _test_insert_tier_fail)
	_runner.add_test("Org: remove_tier 子组织上挂", _test_remove_tier)
	_runner.add_test("Org: disband 移除组织并子组织上挂", _test_disband)
	_runner.add_test("Org: 序列化 round-trip 含 next_id 防冲突", _test_save_load)
	_runner.add_test("Org: WorldState 容器同步（创建注册/删除注销）", _test_world_sync)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────── fixture：根(tier5) -> mid(tier4) -> leaf(tier3) ───────────────

## 构造标准三层组织树，返回 {root, mid, leaf} org_id
func _build_tree(m: ScriptOrgManager) -> Dictionary:
	var r_root: Dictionary = m.create_organization("军团部", "MILITARY", 5, "")
	var r_mid: Dictionary = m.create_organization("师部", "MILITARY", 4, r_root.data.org_id)
	var r_leaf: Dictionary = m.create_organization("连部", "MILITARY", 3, r_mid.data.org_id)
	return {"root": r_root.data.org_id, "mid": r_mid.data.org_id, "leaf": r_leaf.data.org_id}


# ─────────────── 创建 ───────────────

func _test_create_ok() -> void:
	var m := ScriptOrgManager.new()
	var r1: Dictionary = m.create_organization("连部", "MILITARY", 3, "")
	_runner.assert_true(r1.get("ok", false), "根组织创建应成功: " + str(r1))
	var r2: Dictionary = m.create_organization("连部二", "MILITARY", 3, "")
	_runner.assert_true(r2.get("ok", false), "第二个组织创建应成功")
	_runner.assert_not_equal(r1.data.org_id, r2.data.org_id, "org_id 应唯一递增")
	_runner.assert_true(r1.data.org_id == "org_1" and r2.data.org_id == "org_2", "org_id 应从 org_1 递增")


func _test_create_invalid() -> void:
	var m := ScriptOrgManager.new()
	_runner.assert_false(m.create_organization("x", "MILITARY", 0, "").get("ok", true), "tier=0 应失败")
	_runner.assert_false(m.create_organization("x", "MILITARY", 6, "").get("ok", true), "tier=6 应失败")
	_runner.assert_false(m.create_organization("x", "ILLEGAL", 3, "").get("ok", true), "无效 tag 应失败")


func _test_create_parent_validate() -> void:
	var m := ScriptOrgManager.new()
	m.create_organization("军团部", "MILITARY", 5, "")
	_runner.assert_false(m.create_organization("x", "MILITARY", 4, "org_999").get("ok", true), "父组织不存在应失败")
	# 父 tier5，子必须 tier4
	_runner.assert_false(m.create_organization("x", "MILITARY", 5, "org_1").get("ok", true), "子与父同级应失败")
	_runner.assert_false(m.create_organization("x", "MILITARY", 3, "org_1").get("ok", true), "子层级跳级应失败")
	var r: Dictionary = m.create_organization("x", "MILITARY", 4, "org_1")
	_runner.assert_true(r.get("ok", false), "连续层级子组织应成功")


# ─────────────── 查询 ───────────────

func _test_query() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	_runner.assert_true(m.get_organization("org_999").get("ok", false) == false, "不存在组织查询应失败")
	var q: Dictionary = m.get_organization(tree.leaf)
	_runner.assert_true(q.get("ok", false), "存在组织查询应成功")
	_runner.assert_equal(q.data.name, "连部", "名称保真")
	_runner.assert_equal(q.data.tier, 3, "层级保真")
	_runner.assert_equal(q.data.parent_org, tree.mid, "父组织保真")
	_runner.assert_equal(m.get_child_orgs(tree.root), [tree.mid], "根的子列表应为 [mid]")
	_runner.assert_equal(m.get_child_orgs(tree.leaf), [], "叶无子组织")
	_runner.assert_equal(m.get_child_orgs("org_999"), [], "不存在组织子列表为空")


func _test_query_by_tag_region() -> void:
	var m := ScriptOrgManager.new()
	_build_tree(m)
	m.create_organization("研究站", "RESEARCH", 4, "org_1")
	_runner.assert_equal(m.get_orgs_by_tag("MILITARY").size(), 3, "MILITARY 应有 3 个")
	_runner.assert_equal(m.get_orgs_by_tag("RESEARCH"), ["org_4"], "RESEARCH 应为 [org_4]")
	_runner.assert_equal(m.get_orgs_by_tag("INVALID"), [], "无效 tag 查询返回空")
	# location 恒为空（无 set_location API），区域查询返回空
	_runner.assert_equal(m.get_orgs_in_region("r1"), [], "无区域定位时应为空")


# ─────────────── 编制 / 人事 ───────────────

func _test_templates_autonomy() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	_runner.assert_true(m.set_personnel_template(tree.leaf, {"rifleman": 4}).get("ok", false), "设置人员编制")
	_runner.assert_equal(m.get_organization(tree.leaf).data.personnel_template, {"rifleman": 4}, "编制保真")
	_runner.assert_true(m.set_equipment_template(tree.leaf, {"rifle": 4}).get("ok", false), "设置装备模板")
	_runner.assert_equal(m.get_organization(tree.leaf).data.equipment_template["rifle"], 4, "装备保真")
	_runner.assert_true(m.set_autonomy(tree.leaf, "high").get("ok", false), "小写 high 应归一化成功")
	_runner.assert_equal(m.get_organization(tree.leaf).data.autonomy_level, ScriptOrgState.AutonomyLevel.HIGH, "自主权限归一化为 enum HIGH")
	_runner.assert_false(m.set_autonomy(tree.leaf, "RANDOM").get("ok", true), "无效权限级别应失败")
	_runner.assert_false(m.set_personnel_template("org_999", {}).get("ok", true), "不存在组织设置失败")


func _test_commander() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	_runner.assert_true(m.assign_commander(tree.leaf, "stick_1").get("ok", false), "任命指挥官")
	_runner.assert_equal(m.get_organization(tree.leaf).data.commander_id, "stick_1", "指挥官保真")
	_runner.assert_true(m.remove_commander(tree.leaf).get("ok", false), "撤除指挥官")
	_runner.assert_equal(m.get_organization(tree.leaf).data.commander_id, "", "指挥官清空")
	_runner.assert_false(m.assign_commander("org_999", "s").get("ok", true), "不存在组织任命失败")


func _test_stickman_assign() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	_runner.assert_true(m.assign_stickman(tree.leaf, "stick_1", "rifleman").get("ok", false), "分配人员")
	_runner.assert_false(m.assign_stickman(tree.leaf, "stick_1", "rifleman").get("ok", true), "重复分配应失败")
	_runner.assert_equal(m.get_organization(tree.leaf).data.personnel, ["stick_1"], "人员列表保真")
	_runner.assert_true(m.remove_stickman(tree.leaf, "stick_1").get("ok", false), "移除人员")
	_runner.assert_false(m.remove_stickman(tree.leaf, "stick_1").get("ok", true), "移除不存在人员失败")
	_runner.assert_equal(m.get_organization(tree.leaf).data.personnel, [], "人员列表清空")


# ─────────────── 层级调整 ───────────────

func _test_insert_tier_above() -> void:
	# 层级不变量：child.tier == parent.tier - 1。连续层级树（5→4→3）中，
	# org 与 parent 之间没有空层，above 必须拒绝（2026-08 审计修复：原实现
	# 放行 new_tier == parent.tier，制造"同级父子"）。
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	var r: Dictionary = m.insert_tier(tree.leaf, "加强连", "above")
	_runner.assert_false(r.get("ok", true), "连续层级树 above 插入应失败: " + str(r))
	# 树结构不能被破坏
	_runner.assert_equal(m.get_child_orgs(tree.mid), [tree.leaf], "mid 子列表不应变化")
	_runner.assert_equal(m.get_organization(tree.leaf).data.parent_org, tree.mid, "leaf 父组织不应变化")


func _test_insert_tier_below() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	var r: Dictionary = m.insert_tier(tree.leaf, "排部", "below")
	_runner.assert_true(r.get("ok", false), "below 插入应成功: " + str(r))
	var new_id: String = r.data.org_id
	var new_org: Dictionary = m.get_organization(new_id).data
	_runner.assert_equal(new_org.tier, 2, "新组织层级应为 leaf-1(tier2)")
	_runner.assert_equal(new_org.parent_org, tree.leaf, "新组织父应为 leaf（2026-08 修复：原实现错误挂到 mid）")
	_runner.assert_equal(new_org.child_orgs, [], "新组织应无子组织")
	_runner.assert_equal(m.get_child_orgs(tree.leaf), [new_id], "leaf 子列表应包含新组织")
	_runner.assert_equal(m.get_child_orgs(tree.mid), [tree.leaf], "mid 子列表不应变化")


func _test_insert_tier_fail() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	_runner.assert_false(m.insert_tier(tree.root, "x", "above").get("ok", true), "根组织上方插入应失败")
	_runner.assert_false(m.insert_tier(tree.leaf, "x", "sideways").get("ok", true), "无效位置应失败")
	_runner.assert_false(m.insert_tier("org_999", "x", "above").get("ok", true), "不存在组织应失败")
	# 连续层级树中 above 必然无空层
	_runner.assert_false(m.insert_tier(tree.mid, "x", "above").get("ok", true), "连续层级 above 应失败")
	# below 在 tier1 上应越界失败
	var l1: Dictionary = m.create_organization("班组", "MILITARY", 1, "")
	_runner.assert_false(m.insert_tier(l1.data.org_id, "x", "below").get("ok", true), "tier1 下方插入应失败")


func _test_remove_tier() -> void:
	var m := ScriptOrgManager.new()
	var tree := _build_tree(m)
	var r: Dictionary = m.remove_tier(tree.mid)
	_runner.assert_true(r.get("ok", false), "删除中间组织应成功")
	_runner.assert_false(m.get_organization(tree.mid).get("ok", false), "被删组织不应存在")
	_runner.assert_equal(m.get_organization(tree.leaf).data.parent_org, tree.root, "子组织应上挂到 root")
	_runner.assert_equal(m.get_child_orgs(tree.root), [tree.leaf], "root 子列表应更新为 leaf")
	_runner.assert_false(m.remove_tier(tree.root).get("ok", true), "根组织删除应失败")


func _test_disband() -> void:
	var m := ScriptOrgManager.new()
	var ws := ScriptWS.new()
	m.set_world(ws)
	var tree := _build_tree(m)
	m.assign_commander(tree.mid, "stick_c")
	m.assign_stickman(tree.mid, "stick_1", "rifleman")
	m.assign_stickman(tree.mid, "stick_2", "rifleman")
	var r: Dictionary = m.disband_organization(tree.mid)
	_runner.assert_true(r.get("ok", false), "解散应成功")
	_runner.assert_false(m.get_organization(tree.mid).get("ok", false), "解散后组织应被移除")
	_runner.assert_equal(m.get_organization(tree.leaf).data.parent_org, tree.root, "子组织应上挂到 root")
	_runner.assert_equal(m.get_child_orgs(tree.root), [tree.leaf], "root 子列表应更新")
	_runner.assert_null(ws.organizations.get(tree.mid, null), "WorldState 容器应同步注销")
	_runner.assert_equal(ws.organizations.size(), 2, "WorldState 容器剩余 2 个组织")


# ─────────────── 序列化 ───────────────

func _test_save_load() -> void:
	var m := ScriptOrgManager.new()
	m.set_world(ScriptWS.new())
	var tree := _build_tree(m)
	m.assign_stickman(tree.leaf, "stick_1", "rifleman")
	m.set_personnel_template(tree.leaf, {"rifleman": 4})
	m.set_autonomy(tree.mid, "LOW")
	var save: Dictionary = m.get_save_data()
	_runner.assert_equal(save.organizations.size(), 3, "存档应含 3 个组织")
	_runner.assert_equal(save.next_id, 4, "next_id 应为 4")

	var m2 := ScriptOrgManager.new()
	m2.set_world(ScriptWS.new())
	m2.load_save_data(save)
	_runner.assert_equal(m2.get_organization(tree.leaf).data.personnel, ["stick_1"], "读档后人员保真")
	_runner.assert_equal(m2.get_organization(tree.leaf).data.personnel_template, {"rifleman": 4}, "读档后编制保真")
	_runner.assert_equal(m2.get_organization(tree.mid).data.autonomy_level, ScriptOrgState.AutonomyLevel.LOW, "读档后自主权限保真")
	_runner.assert_equal(m2.get_organization(tree.leaf).data.parent_org, tree.mid, "读档后层级关系保真")
	# next_id 防冲突：读档后新建组织不应覆盖旧组织（leaf 为 tier3，新组织须 tier2 才连续）
	var r: Dictionary = m2.create_organization("新连", "MILITARY", 2, tree.leaf)
	_runner.assert_true(r.get("ok", false), "读档后新建组织应成功")
	_runner.assert_equal(r.data.org_id, "org_4", "新组织 ID 应从恢复的 next_id 继续")
	_runner.assert_equal(m2.organizations.size(), 4, "总组织数应为 4（不覆盖旧数据）")
	# 读档后组织应重新注册到 WorldState 容器
	_runner.assert_equal(m2._world.organizations.size(), 4, "WorldState 容器应与 manager 同步")


## WorldState 容器同步：创建注册、删除注销（2026-08 集中制 A 方案）
func _test_world_sync() -> void:
	var m := ScriptOrgManager.new()
	var ws := ScriptWS.new()
	m.set_world(ws)
	var tree := _build_tree(m)
	_runner.assert_equal(ws.organizations.size(), 3, "创建 3 个组织后 WorldState 容器应有 3 个")
	_runner.assert_not_null(ws.organizations.get(tree.mid, null), "mid 应注册进 WorldState 容器")
	_runner.assert_equal(ws.organizations[tree.mid].name, "师部", "容器内为 OrganizationState 对象且字段保真")
	m.remove_tier(tree.mid)
	_runner.assert_equal(ws.organizations.size(), 2, "删除后 WorldState 容器应同步注销")
	_runner.assert_null(ws.organizations.get(tree.mid, null), "被删组织应已注销")
