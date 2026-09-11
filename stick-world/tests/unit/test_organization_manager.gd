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
	_runner.add_test("Org: load_preset 查表整树创建（军事编制）", _test_load_preset_from_config)
	_runner.add_test("Org: load_preset 错误路径（未知预设/坏参数/层级不衔接）", _test_load_preset_errors)
	_runner.add_test("Org: load_preset Dictionary 直灌挂接到 parent", _test_load_preset_attach)
	_runner.add_test("Org: load_preset 中途失败整体回滚", _test_load_preset_rollback)
	_runner.add_test("Org: export_as_preset 子树导出 + 往返同构", _test_export_roundtrip)
	_runner.add_test("Org: 蓝图模板字段往返保真（编制/装备/权限/行为）", _test_preset_template_roundtrip)
	_runner.add_test("Org: api 层信号契约（insert_tier 补发 org_created+restructured）", _test_api_signals)
	_runner.add_test("Org: 补位 RANK_HIGHEST cmd 最高顶上（EventBus+上报必发）", _test_succession_rank_highest)
	_runner.add_test("Org: 补位平局按池序（personnel 先于子指挥官）", _test_succession_tie_pool_order)
	_runner.add_test("Org: 补位池口径（L1 班内/中间层下级指挥官/并池去重/剔除被移除者）", _test_succession_pools)
	_runner.add_test("Org: 补位候选空持续空缺 / PLAYER_CHOSEN 不自动", _test_succession_vacancy)
	_runner.add_test("Org: get_succession_candidates 排序（cmd 降序）", _test_succession_candidates_api)
	_runner.add_test("Org: 上报门控三档×三 type 全矩阵（含阈值边界/覆盖）", _test_report_gate_matrix)
	_runner.add_test("Org: file_report schema 校验与 api 层转发", _test_file_report_schema)
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


# ─────────────── 预设（load_preset / export_as_preset） ───────────────

func _test_load_preset_from_config() -> void:
	var m := ScriptOrgManager.new()
	var r: Dictionary = m.load_preset("军事编制", "")
	_runner.assert_true(r.get("ok", false), "军事编制预设应加载成功: " + str(r))
	var created: Array = r.data.created
	_runner.assert_equal(created.size(), 5, "军事编制应创建 5 层组织")
	var root: Dictionary = m.get_organization(r.data.org_id).data
	_runner.assert_equal(root.name, "师", "根组织应为师")
	_runner.assert_equal(root.tier, 5, "根组织应为 L5")
	_runner.assert_equal(root.tag, ScriptOrgState.Tag.MILITARY, "预设组织应带 MILITARY 标签")
	# 链式结构：师→团→营→连→排
	var expected := ["团", "营", "连", "排"]
	var parent_id: String = r.data.org_id
	for i in expected.size():
		var children: Array[String] = m.get_child_orgs(parent_id)
		_runner.assert_equal(children.size(), 1, "每层应只有一个子组织")
		var child: Dictionary = m.get_organization(children[0]).data
		_runner.assert_equal(child.name, expected[i], "第 %d 层应为%s" % [i, expected[i]])
		_runner.assert_equal(child.tier, 4 - i, "层级应逐层递减")
		parent_id = child.id
	_runner.assert_equal(m.organizations.size(), 5, "总组织数应为 5")


func _test_load_preset_errors() -> void:
	var m := ScriptOrgManager.new()
	var r1: Dictionary = m.load_preset("不存在的预设", "")
	_runner.assert_false(r1.get("ok", true), "未知预设名应失败")
	_runner.assert_true(str(r1.get("error", "")).contains("可用"), "错误信息应列出可用预设")
	var r2: Dictionary = m.apply_preset({"entries": []}, "")
	_runner.assert_false(r2.get("ok", true), "空 entries 蓝图应失败")
	var r_bad: Dictionary = m.apply_preset({"entries": [{"key": "a", "name": "x", "level": 9}]}, "")
	_runner.assert_false(r_bad.get("ok", true), "层级越界条目应失败")
	# 层级不衔接：预设顶层 L5 无法挂到 L5 父组织下（须 parent.tier-1 = L4）
	var root: Dictionary = m.create_organization("司令部", "MILITARY", 5, "")
	var r3: Dictionary = m.load_preset("军事编制", root.data.org_id)
	_runner.assert_false(r3.get("ok", true), "预设顶层与父组织层级不衔接应失败")
	_runner.assert_equal(m.organizations.size(), 1, "失败后不应留下预设组织")


func _test_load_preset_attach() -> void:
	var m := ScriptOrgManager.new()
	var root: Dictionary = m.create_organization("野战军", "MILITARY", 5, "")
	# v2 蓝图直灌（export_as_preset 同格式）：顶层 L4 恰好衔接 L5 父组织
	var preset := {
		"name": "附属师", "tag": "MILITARY",
		"entries": [
			{"key": "a", "name": "师", "level": 4, "tag": "MILITARY", "parent_key": ""},
			{"key": "b", "name": "团", "level": 3, "tag": "MILITARY", "parent_key": "a"},
			{"key": "c", "name": "连", "level": 2, "tag": "MILITARY", "parent_key": "b"},
		],
	}
	var r: Dictionary = m.apply_preset(preset, root.data.org_id)
	_runner.assert_true(r.get("ok", false), "衔接层级的预设应挂接成功: " + str(r))
	_runner.assert_equal(m.organizations.size(), 4, "挂接后共 4 个组织")
	var children: Array[String] = m.get_child_orgs(root.data.org_id)
	_runner.assert_equal(children, [r.data.org_id], "预设根应挂到指定父组织")
	_runner.assert_equal(m.get_organization(r.data.org_id).data.name, "师", "预设根名称保真")


func _test_load_preset_rollback() -> void:
	var m := ScriptOrgManager.new()
	# 条目层级断链（连的子级标 L5 越界）→ 中途失败，已创建组织须回滚
	var preset := {
		"name": "坏预设", "tag": "MILITARY",
		"entries": [
			{"key": "a", "name": "师", "level": 5, "tag": "MILITARY", "parent_key": ""},
			{"key": "b", "name": "团", "level": 4, "tag": "MILITARY", "parent_key": "a"},
			{"key": "c", "name": "幽灵层", "level": 5, "tag": "MILITARY", "parent_key": "b"},
		],
	}
	var r: Dictionary = m.apply_preset(preset, "")
	_runner.assert_false(r.get("ok", true), "断链预设应失败")
	_runner.assert_true(str(r.get("error", "")).contains("回滚"), "错误信息应说明已回滚")
	_runner.assert_equal(m.organizations.size(), 0, "回滚后不应残留任何组织")


func _test_export_roundtrip() -> void:
	var m := ScriptOrgManager.new()
	var r: Dictionary = m.load_preset("军事编制", "")
	var root_id: String = r.data.org_id
	# 只导出子树（从团开始）：导出根 = 团，parent_id 恒为 ""
	var regiment_id: String = m.get_child_orgs(root_id)[0]
	var exported: Dictionary = m.export_as_preset(regiment_id)
	_runner.assert_true(exported.get("ok", false), "子树导出应成功")
	_runner.assert_equal(exported.data.name, "团", "导出根名称应为团")
	_runner.assert_equal(exported.data.tag, "MILITARY", "导出根标签应为 MILITARY")
	_runner.assert_equal(exported.data.entries.size(), 4, "团子树应含 4 个条目")
	_runner.assert_equal(String(exported.data.entries[0].parent_key), "", "导出根条目 parent_key 应为空")
	_runner.assert_equal(String(exported.data.entries[0].key), "n1", "条目 key 应为语义键（先根序重编，无运行时 org_id）")
	_runner.assert_true(str(exported.data.entries[0].key).begins_with("n"), "key 不应携带 org_ 前缀")
	# 往返：回灌到全新 manager，结构应同构
	var m2 := ScriptOrgManager.new()
	var r2: Dictionary = m2.apply_preset(exported.data, "")
	_runner.assert_true(r2.get("ok", false), "导出数据应可直接回灌: " + str(r2))
	var exported2: Dictionary = m2.export_as_preset(r2.data.org_id)
	_runner.assert_equal(_preset_shape(exported.data), _preset_shape(exported2.data), "往返后结构应同构")
	# 整树导出对照：5 条目
	var full: Dictionary = m.export_as_preset(root_id)
	_runner.assert_equal(full.data.entries.size(), 5, "整树导出应含 5 个条目")
	# 导出不存在的组织
	_runner.assert_false(m.export_as_preset("org_999").get("ok", true), "导出不存在的组织应失败")


## 预设数据规范化形状：[(name, level, tag, 父名)] 排序后比较（org_id 差异无关结构）
func _preset_shape(data: Dictionary) -> Array:
	var name_by_id := {}
	for e in data.entries:
		name_by_id[String(e.id)] = String(e.name)
	var rows: Array = []
	for e in data.entries:
		var pid := String(e.parent_id)
		rows.append([String(e.name), int(e.level), String(e.tag), name_by_id.get(pid, "") if pid != "" else ""])
	rows.sort()
	return rows


# ─────────────── 蓝图模板字段往返（v2：模板导、实例不导） ───────────────

func _test_preset_template_roundtrip() -> void:
	var m := ScriptOrgManager.new()
	var r: Dictionary = m.load_preset("军事编制", "")
	var root_id: String = r.data.org_id
	var regiment_id: String = m.get_child_orgs(root_id)[0]
	# 给团级配模板 + 权限
	m.set_personnel_template(regiment_id, {"rifleman": 4, "mage": 1})
	m.set_equipment_template(regiment_id, {"armor": "leather"})
	m.set_autonomy(regiment_id, "LOW")
	m.set_default_behavior(regiment_id, {"stance": "hold"})
	var exported: Dictionary = m.export_as_preset(root_id)
	var reg_entry: Dictionary = {}
	for e in exported.data.entries:
		if String(e.name) == "团":
			reg_entry = e
	_runner.assert_equal(reg_entry.personnel_template, {"rifleman": 4, "mage": 1}, "导出条目应含人员编制模板")
	_runner.assert_equal(reg_entry.equipment_template, {"armor": "leather"}, "导出条目应含装备模板")
	_runner.assert_equal(String(reg_entry.autonomy), "LOW", "导出条目应含自主权限")
	_runner.assert_equal(reg_entry.default_behavior, {"stance": "hold"}, "导出条目应含默认行为")
	# 实例字段不应出现
	_runner.assert_false(reg_entry.has("personnel") or reg_entry.has("commander_id"), "实例字段（成员/指挥官）不应进蓝图")
	# 回灌：模板字段逐项落到新组织
	var m2 := ScriptOrgManager.new()
	var r2: Dictionary = m2.apply_preset(exported.data, "")
	var reg2: String = m2.get_child_orgs(r2.data.org_id)[0]
	_runner.assert_equal(m2.get_organization(reg2).data.personnel_template, {"rifleman": 4, "mage": 1}, "回灌后编制模板保真")
	_runner.assert_equal(m2.get_organization(reg2).data.autonomy_level, ScriptOrgState.AutonomyLevel.LOW, "回灌后自主权限保真")
	_runner.assert_equal(m2.get_organization(reg2).data.default_behavior, {"stance": "hold"}, "回灌后默认行为保真")


# ─────────────── api 层信号契约（层级调整补发信号） ───────────────

func _test_api_signals() -> void:
	var api := preload("res://modules/organization/api.gd").new()
	var m := ScriptOrgManager.new()
	api.setup(m)
	var tree := _build_tree(m)
	var created_ids: Array = []
	var restructured_ids: Array = []
	api.org_created.connect(func(org_id: String): created_ids.append(org_id))
	api.org_restructured.connect(func(org_id: String): restructured_ids.append(org_id))
	# insert_tier：above 在 root 与 mid 之间无空层（连续层级）会失败——用 below 在 leaf 下插 L2
	var r: Dictionary = api.insert_tier(tree.leaf, "新连", "below")
	_runner.assert_true(r.get("ok", false), "below 插层应成功: " + str(r))
	_runner.assert_equal(created_ids.size(), 1, "insert_tier 应补发 1 次 org_created")
	_runner.assert_true(restructured_ids.has(tree.leaf), "insert_tier 应对原节点发 org_restructured")
	# remove_tier：应发 org_restructured
	restructured_ids.clear()
	var r2: Dictionary = api.remove_tier(created_ids[0])
	_runner.assert_true(r2.get("ok", false), "删层应成功")
	_runner.assert_equal(restructured_ids.size(), 1, "remove_tier 应补发 org_restructured")
	api.free()

# ─────────────── 批次 3-F1：补位引擎（架构文档 §4.3.1） ───────────────

## 构造 L1 班：personnel 依次入列，首位任命指挥官。返回 org_id
func _build_l1_squad(m: ScriptOrgManager, members: Array) -> String:
	var org: String = m.create_organization("排", "MILITARY", 1, "").data.org_id
	for sid in members:
		m.assign_stickman(org, str(sid), "fighter")
	m.assign_commander(org, str(members[0]))
	return org


func _test_succession_rank_highest() -> void:
	var m := ScriptOrgManager.new()
	var cmd_table := {"101": 1.0, "102": 3.0, "103": 2.0}
	m.set_attribute_provider(func(id: String) -> float: return float(cmd_table.get(id, -1.0)))
	var org := _build_l1_squad(m, ["101", "102", "103"])
	# 断言 EventBus.commander_assigned 与 manager.report_filed 双信号
	var assigned: Array = []
	var cb := func(squad_id: String, unit_id: int): assigned.append([squad_id, unit_id])
	EventBus.commander_assigned.connect(cb)
	var reports: Array = []
	m.report_filed.connect(func(oid: String, report: Dictionary): reports.append([oid, report]))
	var r: Dictionary = m.remove_stickman(org, "101")  # 指挥官阵亡（成员表移除 + 补位）
	_runner.assert_true(r.get("ok", false), "移除指挥官应成功")
	_runner.assert_equal(String(m.get_organization(org).data.commander_id), "102", "cmd 最高者(102=3.0)应顶上")
	_runner.assert_equal(assigned, [[org, 102]], "EventBus.commander_assigned 应发射(org, 102)")
	_runner.assert_equal(reports.size(), 1, "commander_lost 上报必发一次")
	var rep: Dictionary = reports[0][1]
	_runner.assert_equal(String(rep.type), "commander_lost", "上报 type=commander_lost")
	_runner.assert_true(int(rep.filed_at) > 0, "filed_at 应为时间戳")
	_runner.assert_equal(String(rep.payload.prev_commander_id), "101", "payload 记录前任")
	_runner.assert_true(bool(rep.payload.filled), "payload filled=true")
	_runner.assert_equal(String(rep.payload.successor_id), "102", "payload 记录继任者")
	EventBus.commander_assigned.disconnect(cb)


func _test_succession_tie_pool_order() -> void:
	var m := ScriptOrgManager.new()  # 不注入 attribute_provider → 全员 -1 平局 → 池序定胜负
	var root: String = m.create_organization("连", "MILITARY", 2, "").data.org_id
	m.assign_stickman(root, "201", "fighter")  # 连部直属副官
	m.assign_stickman(root, "202", "fighter")
	var l1a: String = m.create_organization("一排", "MILITARY", 1, root).data.org_id
	var l1b: String = m.create_organization("二排", "MILITARY", 1, root).data.org_id
	m.assign_stickman(l1a, "301", "fighter")
	m.assign_commander(l1a, "301")
	m.assign_stickman(l1b, "302", "fighter")
	m.assign_commander(l1b, "302")
	m.assign_commander(root, "202")
	var r: Dictionary = m.remove_commander(root)  # 撤职 → 同一入口触发补位
	_runner.assert_true(r.get("ok", false), "撤职应成功")
	# 平局时池序：personnel（201）先于子指挥官（301/302）
	_runner.assert_equal(String(m.get_organization(root).data.commander_id), "201", "平局按池序，personnel 先于子指挥官")
	# 中间层无 personnel → 完全退化为下级指挥官（child_orgs 注册序）
	var m2 := ScriptOrgManager.new()
	var root2: String = m2.create_organization("连", "MILITARY", 2, "").data.org_id
	var p1: String = m2.create_organization("一排", "MILITARY", 1, root2).data.org_id
	var p2: String = m2.create_organization("二排", "MILITARY", 1, root2).data.org_id
	m2.assign_stickman(p1, "401", "fighter")
	m2.assign_commander(p1, "401")
	m2.assign_stickman(p2, "402", "fighter")
	m2.assign_commander(p2, "402")
	m2.assign_commander(root2, "501")
	var r2: Dictionary = m2.remove_commander(root2)
	_runner.assert_true(r2.get("ok", false), "撤职应成功")
	_runner.assert_equal(String(m2.get_organization(root2).data.commander_id), "401", "中间层补位取下级指挥官（一排长顶上）")


func _test_succession_pools() -> void:
	# 并池去重：同一人既是父 personnel 又是子组织指挥官 → 候选只出现一次
	var m := ScriptOrgManager.new()
	var root: String = m.create_organization("连", "MILITARY", 2, "").data.org_id
	m.assign_stickman(root, "601", "fighter")
	var l1: String = m.create_organization("排", "MILITARY", 1, root).data.org_id
	m.assign_stickman(l1, "601", "fighter")  # 双重身份
	m.assign_commander(l1, "601")
	var candidates: Array = m.get_succession_candidates(root)
	_runner.assert_equal(candidates.size(), 1, "并池去重：双重身份只出现一次")
	# L1 退化为班内（无子组织）；现任指挥官不能继承自己，不在候选池
	var squad := _build_l1_squad(m, ["701", "702"])
	var ids: Array = []
	for c in m.get_succession_candidates(squad):
		ids.append(String(c.id))
	_runner.assert_false(ids.has("701"), "现任指挥官不在候选池")
	_runner.assert_true(ids.has("702"), "班内其余成员在候选池")
	# remove_stickman 触发补位：死者本人被剔除（指挥官阵亡后由 702 顶上）
	var r: Dictionary = m.remove_stickman(squad, "701")
	_runner.assert_true(r.get("ok", false), "移除应成功")
	_runner.assert_equal(String(m.get_organization(squad).data.commander_id), "702", "死者被剔除，班内次序顶上")


func _test_succession_vacancy() -> void:
	# 候选池空 → 持续空缺（filled=false，report 仍必发）
	var m := ScriptOrgManager.new()
	var root: String = m.create_organization("连", "MILITARY", 2, "").data.org_id
	m.assign_commander(root, "801")
	var reports: Array = []
	m.report_filed.connect(func(oid: String, report: Dictionary): reports.append(report))
	var r: Dictionary = m.remove_commander(root)
	_runner.assert_true(r.get("ok", false), "撤职应成功")
	_runner.assert_equal(String(m.get_organization(root).data.commander_id), "", "无人可用应持续空缺")
	_runner.assert_equal(reports.size(), 1, "空缺也必发 commander_lost")
	_runner.assert_false(bool(reports[0].payload.filled), "filled=false")
	_runner.assert_equal(String(reports[0].payload.successor_id), "", "successor_id 为空")
	# PLAYER_CHOSEN：不自动补（等玩家任命），EventBus 不发射
	var m2 := ScriptOrgManager.new()
	var squad2 := _build_l1_squad(m2, ["811", "812"])
	m2.organizations[squad2].succession_rule = ScriptOrgState.SuccessionRule.PLAYER_CHOSEN
	var assigned: Array = []
	var cb := func(squad_id: String, unit_id: int): assigned.append([squad_id, unit_id])
	EventBus.commander_assigned.connect(cb)
	var r2: Dictionary = m2.remove_stickman(squad2, "811")
	_runner.assert_true(r2.get("ok", false), "移除应成功")
	_runner.assert_equal(String(m2.get_organization(squad2).data.commander_id), "", "PLAYER_CHOSEN 不自动补位")
	_runner.assert_equal(assigned, [], "PLAYER_CHOSEN 不发 commander_assigned")
	EventBus.commander_assigned.disconnect(cb)


func _test_succession_candidates_api() -> void:
	var m := ScriptOrgManager.new()
	var cmd_table := {"901": 2.0, "902": 5.0, "903": 3.5}
	m.set_attribute_provider(func(id: String) -> float: return float(cmd_table.get(id, -1.0)))
	var squad := _build_l1_squad(m, ["901", "902", "903"])
	var cands: Array = m.get_succession_candidates(squad)
	_runner.assert_equal(cands.size(), 2, "候选 = 班内其余成员（现任 901 剔除）")
	# cmd 降序：902(5.0) > 903(3.5)
	_runner.assert_equal(String(cands[0].id), "902", "cmd 最高者排首位")
	_runner.assert_equal(String(cands[1].id), "903", "次高第二")
	_runner.assert_equal(float(cands[0].cmd), 5.0, "候选携带 cmd 值")
	# 不存在的组织 → 空表
	_runner.assert_equal(m.get_succession_candidates("org_nope").size(), 0, "未知组织候选为空")


# ─────────────── 批次 3-F1：信息上报门控（架构文档 §4.4） ───────────────

func _test_report_gate_matrix() -> void:
	var m := ScriptOrgManager.new()
	var org: String = m.create_organization("排", "MILITARY", 1, "").data.org_id
	# HIGH：全自主——仅 commander_lost 必报
	m.set_autonomy(org, "HIGH")
	_runner.assert_true(m.evaluate_report_gate(org, "commander_lost", {}), "commander_lost 三档必报（HIGH）")
	_runner.assert_false(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 1, "total": 10}), "HIGH casualty 不报")
	_runner.assert_false(m.evaluate_report_gate(org, "contact", {}), "HIGH contact 不报")
	# MEDIUM：阈值门控（默认 0.30）
	m.set_autonomy(org, "MEDIUM")
	_runner.assert_true(m.evaluate_report_gate(org, "commander_lost", {}), "commander_lost 必报（MEDIUM）")
	_runner.assert_true(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 29, "total": 100}), "存活比 0.29 < 0.30 应报")
	_runner.assert_false(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 30, "total": 100}), "存活比恰 0.30 不报（跌破才报）")
	_runner.assert_false(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 70, "total": 100}), "存活比 0.70 不报")
	_runner.assert_false(m.evaluate_report_gate(org, "casualty_threshold", {"total": 0, "alive": 0}), "total=0 防御不报")
	_runner.assert_true(m.evaluate_report_gate(org, "contact", {}), "MEDIUM contact 报（首次性由 combat 挂点把关）")
	# 阈值覆盖入口（balance 行覆盖语义）
	m.set_casualty_report_threshold(0.5)
	_runner.assert_false(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 50, "total": 100}), "覆盖阈值 0.50 后 0.50 不报")
	_runner.assert_true(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 49, "total": 100}), "覆盖阈值 0.50 后 0.49 应报")
	# LOW：全量
	m.set_autonomy(org, "LOW")
	_runner.assert_true(m.evaluate_report_gate(org, "commander_lost", {}), "commander_lost 必报（LOW）")
	_runner.assert_true(m.evaluate_report_gate(org, "casualty_threshold", {"alive": 9, "total": 10}), "LOW casualty 恒报（阈值形同虚设）")
	_runner.assert_true(m.evaluate_report_gate(org, "contact", {}), "LOW contact 恒报")
	# 边界外
	_runner.assert_false(m.evaluate_report_gate("org_nope", "commander_lost", {}), "未知组织不报")
	_runner.assert_false(m.evaluate_report_gate(org, "unknown_type", {}), "未知 type 防御不报")


func _test_file_report_schema() -> void:
	var m := ScriptOrgManager.new()
	var org: String = m.create_organization("排", "MILITARY", 1, "").data.org_id
	var reports: Array = []
	m.report_filed.connect(func(oid: String, report: Dictionary): reports.append([oid, report]))
	# 合法上报透传（filed_at 缺省补当前时间）
	m.file_report(org, {"type": "contact", "payload": {"enemy_count": 3, "position": Vector2(1, 2)}})
	_runner.assert_equal(reports.size(), 1, "合法上报应发一次信号")
	_runner.assert_equal(String(reports[0][0]), org, "信号载荷 = 发起方 org_id")
	var rep: Dictionary = reports[0][1]
	_runner.assert_equal(String(rep.type), "contact", "type 透传")
	_runner.assert_true(int(rep.filed_at) > 0, "filed_at 缺省自动补")
	_runner.assert_equal(rep.payload, {"enemy_count": 3, "position": Vector2(1, 2)}, "payload 透传不解释")
	# schema 校验：type 必填 / 未知组织静默丢弃
	m.file_report(org, {"payload": {}})
	_runner.assert_equal(reports.size(), 1, "缺 type 不发")
	m.file_report("org_nope", {"type": "contact"})
	_runner.assert_equal(reports.size(), 1, "未知组织不发")
	# api 层转发：combat 挂点 → api.file_report → api.report_filed
	var api := preload("res://modules/organization/api.gd").new()
	api.setup(m)
	var api_reports: Array = []
	api.report_filed.connect(func(oid: String, report: Dictionary): api_reports.append(report))
	api.file_report(org, {"type": "casualty_threshold", "filed_at": 42, "payload": {"alive": 2, "dead": 1, "total": 3, "loss_rate": 0.333}})
	_runner.assert_equal(api_reports.size(), 1, "api 层应转发 manager 上报")
	_runner.assert_equal(int(api_reports[0].filed_at), 42, "filed_at 透传")
	api.free()
