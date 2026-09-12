extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：组织侧 default_behavior 配置写入方（GK-5 前置批——补 A4 效用打分器的配置生产端）。
## 覆盖：档案 schema（总闸+标签行+候选）/ 闸关零写入 / 闸开按标签命中（精确行 > 全域兜底行）/
## 写入字典与 UtilityScorer.parse_candidates 链路语法兼容 / 写入方单元（resolve/apply_to 闸关不改状态）/
## insert_tier 创建路径同样写入 / 预设分层（档案默认 < 蓝图显式）/ api 只读深拷贝视图。
## 不进场景树（fixture 用 new()，确定性；api 用例沿用 test_organization_manager 先例，用完 free）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptWriter := preload("res://modules/organization/scripts/default_behavior_writer.gd")
const ScriptOrgState := preload("res://core/entities/organization_state.gd")
const ScriptUtilityScorer := preload("res://modules/combat/scripts/battle/utility_scorer.gd")
const ScriptApi := preload("res://modules/organization/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("档案 schema：总闸关 + config/default/military 行 + 候选可解析", _test_archive_schema)
	_runner.add_test("闸关零写入：档案缺省下创建组织不触碰 default_behavior", _test_gate_off_no_write)
	_runner.add_test("闸开按标签命中：MILITARY 精确行 / 其他标签全域兜底行", _test_gate_on_tag_match)
	_runner.add_test("链路兼容：写入字典可被 UtilityScorer 解析并选出行为", _test_written_dict_consumable)
	_runner.add_test("写入方单元：闸关不改状态 / 闸开大小写与兜底 / 缺总闸行退化", _test_writer_unit)
	_runner.add_test("insert_tier 创建路径同样写入（_make_state 单点接线）", _test_insert_tier_path)
	_runner.add_test("预设分层：蓝图未供保留档案默认 / 显式提供则覆盖", _test_preset_layering)
	_runner.add_test("api 只读视图：get_default_behavior 深拷贝不泄漏内部字典", _test_api_readonly)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── fixture ────────────────────────────────

## 档案行（经写入方装载器，与生产同路径）
func _archive_rows() -> Array:
	return ScriptWriter.load_rows(ScriptWriter.CONFIG_PATH)


func _row_by_id(rows: Array, id: String) -> Dictionary:
	for r in rows:
		if r is Dictionary and String(r.get("id", "")) == id:
			return r
	return {}


## 档案行的可写副本，总闸翻 true（模拟开闸；不改动被缓存资源）
func _enabled_rows() -> Array:
	var out: Array = []
	for r in _archive_rows():
		if r is Dictionary:
			out.append((r as Dictionary).duplicate(true))
	for r in out:
		if String(r.get("id", "")) == "config":
			r["writer_enabled"] = true
	return out


## 建一个注入了开闸写入方的 manager
func _manager_with_writer_enabled() -> ScriptOrgManager:
	var w := ScriptWriter.new()
	w.configure(_enabled_rows())
	var m := ScriptOrgManager.new()
	m.set_default_behavior_writer(w)
	return m


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_archive_schema() -> void:
	var rows: Array = _archive_rows()
	_runner.assert_gt(rows.size(), 0, "档案应可装载（config/ai/org_default_behavior.tres）")
	# 总闸行：本批缺省关（零回归门）
	var gate: Dictionary = _row_by_id(rows, "config")
	_runner.assert_false(gate.is_empty(), "档案应含 config 总闸行")
	_runner.assert_false(bool(gate.get("writer_enabled", true)), "总闸缺省关（零回归门）")
	# BalanceConfig 统一装载惯例：config/ai/*.tres 自动登记为类型路径 ai.<文件名>，无需改装载器
	_runner.assert_true(BalanceConfig.get_value("ai.org_default_behavior") is Array,
			"BalanceConfig 应自动装载 ai.org_default_behavior（类型路径惯例，零登记）")
	var gate_v: Variant = BalanceConfig.get_value("ai.org_default_behavior.config.writer_enabled")
	_runner.assert_true(gate_v is bool, "行路径 ai.org_default_behavior.config.writer_enabled 应可读")
	_runner.assert_false(bool(gate_v), "BalanceConfig 读到的总闸应为 false")
	# 全域兜底行与军事精确行
	var default_row: Dictionary = _row_by_id(rows, "default")
	var military_row: Dictionary = _row_by_id(rows, "military")
	_runner.assert_equal(String(default_row.get("match_tag", "")), "*", "全域行 match_tag 应为 \"*\"")
	_runner.assert_equal(String(military_row.get("match_tag", "")), "MILITARY", "军事行 match_tag = MILITARY")
	# 候选可解析（v2 schema：行为名可映射 OrderType）
	var parsed: Array = ScriptUtilityScorer.parse_candidates(default_row.get("default_behavior", {}))
	_runner.assert_equal(parsed.size(), 3, "全域行三候选（advance/hold/take_cover）")
	if parsed.size() == 3:
		_runner.assert_equal(String(parsed[0]["name"]), "advance", "候选序保留（主业在前）")
		_runner.assert_gt(ScriptUtilityScorer.order_type_of("take_cover"), -1, "take_cover 可映射号令")
		# M7 权重锚点（威胁保命 4~5 / 主业 2~3 / 习惯 0.5~1）
		_runner.assert_approx(float(parsed[0]["weight"]), 2.5, 1e-9, "advance 主业权重 2.5（M7 2~3）")
		_runner.assert_approx(float(parsed[1]["weight"]), 0.8, 1e-9, "hold 习惯权重 0.8（M7 0.5~1）")
		_runner.assert_approx(float(parsed[2]["weight"]), 4.5, 1e-9, "take_cover 保命权重 4.5（M7 4~5）")
	# military 行演示 W1 weight_rules 状态调制
	var mil_parsed: Array = ScriptUtilityScorer.parse_candidates(military_row.get("default_behavior", {}))
	_runner.assert_equal(mil_parsed.size(), 2, "军事行两候选")
	if mil_parsed.size() == 2:
		_runner.assert_true(mil_parsed[0].has("weight_rules"), "军事行 advance 带 weight_rules（M7 状态调制示例）")


func _test_gate_off_no_write() -> void:
	# 生产缺省：manager 惰性自建写入方，档案总闸关
	var m := ScriptOrgManager.new()
	var org: String = m.create_organization("连部", "MILITARY", 3, "").data.org_id
	_runner.assert_true(m.get_default_behavior(org).is_empty(), "闸关：组织 default_behavior 不应被填充")
	# 其他标签同样不写（闸是全局的，与标签无关）
	var org2: String = m.create_organization("科学院", "RESEARCH", 3, "").data.org_id
	_runner.assert_true(m.get_default_behavior(org2).is_empty(), "闸关：其他标签亦不写")
	# 惰性自建出的写入方读到的就是档案总闸
	var w := m._behavior_writer
	_runner.assert_not_null(w, "创建后应已惰性自建写入方")
	if w != null:
		_runner.assert_false(w.is_enabled(), "自建写入方应读档案总闸（false）")
		_runner.assert_true(w.resolve("MILITARY").is_empty(), "闸关 resolve 恒空")


func _test_gate_on_tag_match() -> void:
	var m := _manager_with_writer_enabled()
	var rows: Array = _archive_rows()
	var expected_mil: Dictionary = _row_by_id(rows, "military").get("default_behavior", {})
	var expected_default: Dictionary = _row_by_id(rows, "default").get("default_behavior", {})
	# 精确标签行命中
	var mil: String = m.create_organization("连部", "MILITARY", 3, "").data.org_id
	_runner.assert_equal(m.get_default_behavior(mil), expected_mil, "MILITARY 应命中军事精确行（非兜底行）")
	# 无精确行的标签回落全域兜底行
	var res: String = m.create_organization("科学院", "RESEARCH", 3, "").data.org_id
	_runner.assert_equal(m.get_default_behavior(res), expected_default, "RESEARCH 应回落全域兜底行")
	var com: String = m.create_organization("商队", "COMMERCE", 1, "").data.org_id
	_runner.assert_equal(m.get_default_behavior(com), expected_default, "COMMERCE 应回落全域兜底行")
	# 写入的是深拷贝：篡改返回值不影响组织内部状态
	var view: Dictionary = m.get_default_behavior(res)
	view["candidates"] = []
	_runner.assert_equal(m.get_default_behavior(res), expected_default, "读取视图为深拷贝（篡改不回写）")


func _test_written_dict_consumable() -> void:
	var m := _manager_with_writer_enabled()
	var org: String = m.create_organization("连部", "MILITARY", 3, "").data.org_id
	var behavior: Dictionary = m.get_default_behavior(org)
	# 链路语法兼容：写入字典 -> UtilityScorer 静态解析出候选
	var parsed: Array = ScriptUtilityScorer.parse_candidates(behavior)
	_runner.assert_equal(parsed.size(), 2, "写入字典应解析出 2 候选（advance/hold）")
	if parsed.is_empty():
		return
	for c in parsed:
		_runner.assert_gt(ScriptUtilityScorer.order_type_of(String(c["name"])), -1, "候选行为名可映射号令")
	# 全链路：打分器消费写入字典选出行为（有敌局面）
	var scorer := ScriptUtilityScorer.new()
	scorer.setup({})
	var ctx := {
		"squad_pos": Vector2.ZERO,
		"enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
		"threatened": false,
		"own_strength": 10.0,
		"initial_own_strength": 10.0,
	}
	var pick: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_001", 20260913)
	_runner.assert_false(pick.is_empty(), "打分器应能从写入字典选出行为（链路打通）")
	if not pick.is_empty():
		_runner.assert_true(String(pick["name"]) in ["advance", "hold"], "选中名应为配置候选之一")


func _test_writer_unit() -> void:
	# 闸关：resolve 恒空、apply_to 恒 false 且完全不改状态
	var wd := ScriptWriter.new()
	_runner.assert_false(wd.is_enabled(), "档案缺省闸关")
	_runner.assert_true(wd.resolve("MILITARY").is_empty(), "闸关 resolve 恒空")
	var st := ScriptOrgState.new()
	st.default_behavior = {"stance": "hold"}
	_runner.assert_false(wd.apply_to(st, "MILITARY"), "闸关 apply_to 返回 false")
	_runner.assert_equal(st.default_behavior, {"stance": "hold"}, "闸关不得触碰既有状态")
	# 缺总闸行 = 退化闸关（防档案漏行时静默开闸）
	var wn := ScriptWriter.new()
	wn.configure([{"id": "default", "match_tag": "*", "default_behavior": {"candidates": [{"name": "hold"}]}}])
	_runner.assert_false(wn.is_enabled(), "无 config 行应退化闸关（安全方向）")
	# 闸开：大小写不敏感 / 兜底 / 空标签取兜底
	var we := ScriptWriter.new()
	we.configure(_enabled_rows())
	var rows: Array = _archive_rows()
	var expected_mil: Dictionary = _row_by_id(rows, "military").get("default_behavior", {})
	var expected_default: Dictionary = _row_by_id(rows, "default").get("default_behavior", {})
	_runner.assert_true(we.is_enabled(), "闸开 is_enabled")
	_runner.assert_equal(we.resolve("military"), expected_mil, "标签匹配大小写不敏感")
	_runner.assert_equal(we.resolve("MILITARY"), expected_mil, "精确标签行优先")
	_runner.assert_equal(we.resolve("RESEARCH"), expected_default, "无精确行取兜底行")
	_runner.assert_equal(we.resolve(""), expected_default, "空标签取兜底行")
	# apply_to 写入新状态
	var st2 := ScriptOrgState.new()
	_runner.assert_true(we.apply_to(st2, "MILITARY"), "闸开且有命中应写入")
	_runner.assert_equal(st2.default_behavior, expected_mil, "写入内容 = 命中行字典")
	# 非法状态/空对象防御
	_runner.assert_false(we.apply_to(null, "MILITARY"), "null 状态不写入")
	_runner.assert_false(we.apply_to(RefCounted.new(), "MILITARY"), "无 default_behavior 字段的对象不写入")


func _test_insert_tier_path() -> void:
	var m := _manager_with_writer_enabled()
	var expected_mil: Dictionary = _row_by_id(_archive_rows(), "military").get("default_behavior", {})
	# insert_tier 要求非根组织（根组织拒绝插入，既有语义）；建 根(5) -> 师(4) 后在其下插旅(3)
	var root: String = m.create_organization("军团部", "MILITARY", 5, "").data.org_id
	var mid: String = m.create_organization("师部", "MILITARY", 4, root).data.org_id
	var ins: Dictionary = m.insert_tier(mid, "旅部", "below")
	_runner.assert_true(ins.get("ok", false), "insert_tier 应成功: " + str(ins))
	if not ins.get("ok", false):
		return
	var new_id: String = ins.data.org_id
	_runner.assert_equal(m.get_default_behavior(new_id), expected_mil, "insert_tier 新组织同样按档案写入")


func _test_preset_layering() -> void:
	var m := _manager_with_writer_enabled()
	var expected_mil: Dictionary = _row_by_id(_archive_rows(), "military").get("default_behavior", {})
	# 蓝图未供 default_behavior：保留档案默认
	var r1: Dictionary = m.apply_preset({
		"name": "独立连", "tag": "MILITARY",
		"entries": [{"key": "n1", "name": "连", "level": 1, "tag": "MILITARY", "parent_key": ""}],
	}, "")
	_runner.assert_true(r1.get("ok", false), "蓝图创建应成功: " + str(r1))
	if r1.get("ok", false):
		_runner.assert_equal(m.get_default_behavior(r1.data.org_id), expected_mil,
				"蓝图未显式配置 → 保留档案默认（档案默认 < 蓝图显式）")
	# 蓝图显式提供 default_behavior：覆盖档案默认
	var explicit := {"candidates": [{"name": "hold", "weight": 1.0}]}
	var r2: Dictionary = m.apply_preset({
		"name": "独立排", "tag": "MILITARY",
		"entries": [{"key": "n1", "name": "排", "level": 1, "tag": "MILITARY", "parent_key": "",
				"default_behavior": explicit}],
	}, "")
	_runner.assert_true(r2.get("ok", false), "蓝图创建应成功: " + str(r2))
	if r2.get("ok", false):
		_runner.assert_equal(m.get_default_behavior(r2.data.org_id), explicit, "蓝图显式配置覆盖档案默认")


func _test_api_readonly() -> void:
	var m := ScriptOrgManager.new()
	var org: String = m.create_organization("连部", "MILITARY", 3, "").data.org_id
	var api: Node = ScriptApi.new()
	api.setup(m)
	# 闸关：api 视图为空
	_runner.assert_true(api.get_default_behavior(org).is_empty(), "闸关时 api 只读视图为空")
	# 手工配置后可读；返回深拷贝
	var beh := {"candidates": [{"name": "hold", "weight": 0.8}]}
	m.set_default_behavior(org, beh)
	_runner.assert_equal(api.get_default_behavior(org), beh, "api 应读到写入方/手工配置的字典")
	var view: Dictionary = api.get_default_behavior(org)
	view["candidates"] = []
	_runner.assert_equal(api.get_default_behavior(org), beh, "api 视图为深拷贝（篡改不泄漏）")
	# 未知组织防御
	_runner.assert_true(api.get_default_behavior("org_nope").is_empty(), "未知组织返回空字典")
	api.free()
