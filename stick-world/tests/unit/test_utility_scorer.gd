extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：A4 · C7 效用打分选择器（设计文档12号 §三C7 / §五批次表 A4，AI集大成）。
## 覆盖：personality global 行新键（开关默认关=零回归门 / demand_increment=CoH 真值）/
## 三件套解析（filter 资格过滤 fail-closed / demand ±分 / target 模式映射）/
## 方差扰动界（demand_variance 单旋钮 ±v×increment）/ 按小队错峰（同拍不同扰动、
## 同小队确定性）/ pick_behavior argmax 与平局序 / 行为名 -> OrderType 映射 /
## TeamAi 接入（默认关零回归 / 开关开接管无显式号令小队 / 攻击槽绑定不受接管 /
## GARRISON 生存模式豁免）。
## 不进场景树（fixture 用 new() + 局部 add_child，用完即弃；BalanceConfig 只读，
## 先例 test_task_board）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptUtilityScorer := preload("res://modules/combat/scripts/battle/utility_scorer.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("档案新键：开关默认关（零回归门）+ demand_increment = CoH 50", _test_config_keys)
	_runner.add_test("三件套解析：规范候选保留 / 非法条目丢弃 / v1 透传字典无候选", _test_parse_candidates)
	_runner.add_test("filter 资格过滤：谓词 AND / 未知谓词 fail-closed", _test_filter)
	_runner.add_test("demand ±分：命中 +50 未命中 -50 / 倍率 / 无规则中性", _test_demand)
	_runner.add_test("方差扰动界：|扰动| ≤ variance × increment / variance=0 精确", _test_variance_bounds)
	_runner.add_test("按小队错峰：同局面不同小队扰动不同 / 同小队确定性一致", _test_squad_stagger)
	_runner.add_test("pick_behavior：argmax / 全不合格空 / 平局取配置序首位", _test_pick_behavior)
	_runner.add_test("target 解析：五种模式 + 未知模式兜底", _test_target_modes)
	_runner.add_test("行为名映射：六号令全对齐 + 未知名 -1", _test_order_mapping)
	_runner.add_test("TeamAi 零回归门：默认关，无显式号令小队走防守兜底", _test_team_ai_zero_regression)
	_runner.add_test("TeamAi v2 接管：开关开按打分选行为 / 攻击槽绑定不受接管", _test_team_ai_v2_override)
	_runner.add_test("GARRISON 豁免：生存模式号令不被 default_behavior 接管", _test_team_ai_garrison_exempt)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_config_keys() -> void:
	# personality.tres global 行（配置真值）：开关默认关 + CoH demand_increment 50
	_runner.assert_false(bool(BalanceConfig.get_value("ai.personality.global.default_behavior_v2_enabled")),
			"default_behavior_v2_enabled 默认关（零回归门）")
	_runner.assert_approx(float(BalanceConfig.get_value("ai.personality.global.demand_increment")), 50.0, 0.001,
			"demand_increment = 50（CoH s_demand_increment 真值）")
	# 装载器携带新键（TeamAi.setup 合并链可消费）
	var overlay: Dictionary = ScriptTeamAiProfiles.load_personality_overlay("standard")
	_runner.assert_false(bool(overlay.get("default_behavior_v2_enabled", true)), "overlay 携带开关（默认关）")
	_runner.assert_approx(float(overlay.get("demand_increment", -1.0)), 50.0, 0.001, "overlay 携带 ±分增量")
	# 代码默认兜底（空档案）：scorer 语义不依赖配置存在性
	var scorer := _make_scorer({})
	_runner.assert_approx(scorer._increment(), 50.0, 0.001, "空档案回退 increment 50（代码默认）")
	_runner.assert_approx(scorer._variance(), 0.8, 0.001, "空档案回退 variance 0.8（A1 单旋钮既有默认）")


func _test_parse_candidates() -> void:
	var behavior := {
		"candidates": [
			{"name": "advance", "filter": {}, "demand": {"rules": []}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold"},
			{"name": "flank"},  # 未知行为名（不可映射 OrderType）→ 丢弃
			{"nope": true},  # 缺 name → 丢弃
			"garbage",  # 非字典 → 丢弃
		],
	}
	var parsed: Array = ScriptUtilityScorer.parse_candidates(behavior)
	_runner.assert_equal(parsed.size(), 2, "非法条目丢弃，合法候选保留 2")
	if parsed.size() == 2:
		_runner.assert_equal(str(parsed[0]["name"]), "advance", "配置序保留（argmax 平局取序首位的前提）")
		_runner.assert_equal(str(parsed[1]["name"]), "hold", "缺省 filter/demand/target 补空字典")
	# v1 透传字典（无 candidates 键）与垃圾输入 = 无候选
	_runner.assert_true(ScriptUtilityScorer.parse_candidates({"stance": "hold"}).is_empty(),
			"v1 透传字典无 candidates = 无候选")
	_runner.assert_true(ScriptUtilityScorer.parse_candidates({"candidates": "oops"}).is_empty(),
			"candidates 非数组 = 无候选")
	_runner.assert_true(ScriptUtilityScorer.parse_candidates("garbage").is_empty(), "非字典输入 = 无候选")
	_runner.assert_true(ScriptUtilityScorer.parse_candidates({}).is_empty(), "空字典 = 无候选")


func _test_filter() -> void:
	var scorer := _make_scorer({})
	var ctx := {
		"squad_pos": Vector2.ZERO,
		"enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
		"threatened": true,
		"own_strength": 5.0,
		"initial_own_strength": 10.0,
	}
	_runner.assert_true(scorer.predicates_pass({}, ctx), "空谓词恒过（缺省 filter 无门槛）")
	_runner.assert_true(scorer.predicates_pass({"enemy_within": 400.0}, ctx), "敌 300px < 400 通过")
	_runner.assert_false(scorer.predicates_pass({"enemy_within": 100.0}, ctx), "敌 300px ≥ 100 不过")
	_runner.assert_true(scorer.predicates_pass({"enemy_present": true}, ctx), "有敌命中 enemy_present")
	_runner.assert_false(scorer.predicates_pass({"enemy_present": false}, ctx), "enemy_present=false 不过")
	_runner.assert_true(scorer.predicates_pass({"no_enemy": false}, ctx), "no_enemy=false（有敌）通过")
	_runner.assert_false(scorer.predicates_pass({"no_enemy": true}, ctx), "no_enemy=true（有敌）不过")
	_runner.assert_true(scorer.predicates_pass({"threatened": true}, ctx), "来袭窗口命中 threatened")
	_runner.assert_false(scorer.predicates_pass({"threatened": false}, ctx), "threatened=false 不过")
	# 力量比 0.5（基线 10）
	_runner.assert_true(scorer.predicates_pass({"own_strength_ratio_min": 0.4}, ctx), "比例 0.5 ≥ 0.4 通过")
	_runner.assert_false(scorer.predicates_pass({"own_strength_ratio_min": 0.6}, ctx), "比例 0.5 < 0.6 不过")
	_runner.assert_true(scorer.predicates_pass({"own_strength_ratio_max": 0.6}, ctx), "比例 0.5 ≤ 0.6 通过")
	_runner.assert_false(scorer.predicates_pass({"own_strength_ratio_max": 0.4}, ctx), "比例 0.5 > 0.4 不过")
	# 基线缺失按 1.0（无基准不判比例）
	var ctx_nobase := ctx.duplicate()
	ctx_nobase["initial_own_strength"] = 0.0
	_runner.assert_true(scorer.predicates_pass({"own_strength_ratio_min": 1.0}, ctx_nobase),
			"基线缺失按 1.0（不误判残兵）")
	# 未知谓词 fail-closed（配置笔误不放开激进行为）
	_runner.assert_false(scorer.predicates_pass({"flank_speed": 1.0}, ctx), "未知谓词 = 不合格（fail-closed）")
	# AND 组合：一票否决
	_runner.assert_false(scorer.predicates_pass({"enemy_present": true, "threatened": false}, ctx),
			"AND 组合一票否决")
	# 空敌列表：enemy_present / enemy_within 均不过
	var ctx_empty := {"squad_pos": Vector2.ZERO, "enemies": [], "threatened": false,
			"own_strength": 10.0, "initial_own_strength": 10.0}
	_runner.assert_false(scorer.predicates_pass({"enemy_present": true}, ctx_empty), "空敌列表无 enemy_present")
	_runner.assert_false(scorer.predicates_pass({"enemy_within": 5000.0}, ctx_empty), "空敌列表无 enemy_within")


func _test_demand() -> void:
	var scorer := _make_scorer({})
	var ctx := {"squad_pos": Vector2.ZERO, "enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
			"threatened": false, "own_strength": 10.0, "initial_own_strength": 10.0}
	# 命中 +50 / 未命中 -50（CoH s_demand_increment 真值）
	_runner.assert_approx(scorer.score_candidate(
			{"demand": {"rules": [{"when": {"enemy_present": true}}]}}, ctx), 50.0, 0.001,
			"命中 +50（CoH）")
	_runner.assert_approx(scorer.score_candidate(
			{"demand": {"rules": [{"when": {"no_enemy": true}}]}}, ctx), -50.0, 0.001,
			"未命中 -50（CoH）")
	# score 倍率（进建筑 1~6 倍同构的放大通道）
	_runner.assert_approx(scorer.score_candidate(
			{"demand": {"rules": [{"when": {"enemy_present": true}, "score": 2.0}]}}, ctx), 100.0, 0.001,
			"score=2 命中 +100（CoH 倍率同构）")
	# 多规则求和（+50 与 -50 抵消）
	_runner.assert_approx(scorer.score_candidate(
			{"demand": {"rules": [{"when": {"enemy_present": true}}, {"when": {"threatened": true}}]}}, ctx),
			0.0, 0.001, "多规则求和（+50 -50 抵消）")
	# 无规则 / 无 demand = 中性 0
	_runner.assert_approx(scorer.score_candidate({"demand": {}}, ctx), 0.0, 0.001, "无规则 = 中性 0")
	_runner.assert_approx(scorer.score_candidate({"name": "hold"}, ctx), 0.0, 0.001, "无 demand = 中性 0")


func _test_variance_bounds() -> void:
	var scorer := _make_scorer({"demand_variance": 0.8})
	var ctx := {"squad_pos": Vector2.ZERO, "enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
			"threatened": false, "own_strength": 10.0, "initial_own_strength": 10.0}
	var candidate := {"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}}]}}
	var raw: float = scorer.score_candidate(candidate, ctx)
	_runner.assert_approx(raw, 50.0, 0.001, "原始分 50 基准")
	# 100 个小队流：扰动界 |perturbed - raw| ≤ 0.8 × 50 = 40
	var hit_low: bool = false
	var hit_high: bool = false
	for i in 100:
		var pick: Dictionary = scorer.pick_behavior({"candidates": [candidate]}, ctx, "sq_%03d" % i, 20260911)
		var perturbed := float(pick["perturbed"])
		_runner.assert_true(perturbed >= raw - 40.0 - 0.001 and perturbed <= raw + 40.0 + 0.001,
				"扰动界内（sq_%03d）" % i)
		if perturbed < raw:
			hit_low = true
		if perturbed > raw:
			hit_high = true
	_runner.assert_true(hit_low and hit_high, "100 流双向触界（扰动真实生效）")
	# variance = 0：精确等于原始分（扰动旋钮归零 = 无方差档）
	var scorer_v0 := _make_scorer({"demand_variance": 0.0})
	var pick0: Dictionary = scorer_v0.pick_behavior({"candidates": [candidate]}, ctx, "sq_x", 20260911)
	_runner.assert_approx(float(pick0["perturbed"]), raw, 0.001, "variance=0 扰动归零")
	# 负 variance 钳 0（旋钮鲁棒）
	var scorer_vn := _make_scorer({"demand_variance": -1.0})
	var pickn: Dictionary = scorer_vn.pick_behavior({"candidates": [candidate]}, ctx, "sq_x", 20260911)
	_runner.assert_approx(float(pickn["perturbed"]), raw, 0.001, "负 variance 钳 0")


func _test_squad_stagger() -> void:
	# 同局面同拍（同 base_seed）：不同小队各掷各的（防齐套），同小队跨调用确定一致
	var scorer := _make_scorer({"demand_variance": 0.8})
	var behavior := {"candidates": [{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}}]}}]}
	var ctx := {"squad_pos": Vector2.ZERO, "enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
			"threatened": false, "own_strength": 10.0, "initial_own_strength": 10.0}
	var p1: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", 20260911)
	var p2: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_beta", 20260911)
	var p1_again: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", 20260911)
	_runner.assert_not_equal(float(p1["perturbed"]), float(p2["perturbed"]),
			"同拍不同小队扰动不同（错峰防齐套）")
	_runner.assert_approx(float(p1["perturbed"]), float(p1_again["perturbed"]), 0.0001,
			"同小队同局面确定性一致（battle_sim 可复现）")
	# base_seed 不同 → 流不同（逐局随机种子语义）
	var scorer2 := _make_scorer({"demand_variance": 0.8})
	var p_other_seed: Dictionary = scorer2.pick_behavior(behavior, ctx, "sq_alpha", 42)
	_runner.assert_not_equal(float(p1["perturbed"]), float(p_other_seed["perturbed"]),
			"base_seed 变 → 扰动流变")


func _test_pick_behavior() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0})  # 关方差锁确定性
	var ctx := {"squad_pos": Vector2.ZERO, "enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
			"enemy_centroid": Vector2(300, 0), "own_centroid": Vector2.ZERO,
			"anchor": Vector2(-500, 0), "threatened": false,
			"own_strength": 10.0, "initial_own_strength": 10.0}
	# argmax：hold（敌情 +150）压过 advance（中性 0）
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 3.0}]}},
		],
	}
	var pick: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_a", 1)
	_runner.assert_equal(str(pick["name"]), "hold", "argmax：高分候选胜出")
	_runner.assert_equal(int(pick["order_type"]), ScriptTacticalOrders.OrderType.HOLD_POSITION,
			"胜出候选携带映射号令")
	# 资格过滤前置：唯一候选不合格 → 空（调用方走既有兜底）
	var pick_none: Dictionary = scorer.pick_behavior(
			{"candidates": [{"name": "hold", "filter": {"no_enemy": true}}]}, ctx, "sq_a", 1)
	_runner.assert_true(pick_none.is_empty(), "全不合格 → 空（既有兜底语义）")
	# 平局取配置序首位（variance=0 双候选同中性分）
	var tie := {"candidates": [
		{"name": "advance", "demand": {}},
		{"name": "rally", "demand": {}},
	]}
	var pick_tie: Dictionary = scorer.pick_behavior(tie, ctx, "sq_a", 1)
	_runner.assert_equal(str(pick_tie["name"]), "advance", "平局取配置序首位（确定性）")
	# 无候选（v1 透传字典）→ 空
	_runner.assert_true(scorer.pick_behavior({"stance": "hold"}, ctx, "sq_a", 1).is_empty(),
			"无候选 → 空")


func _test_target_modes() -> void:
	var scorer := _make_scorer({})
	var ctx := {
		"squad_pos": Vector2(10, 20),
		"enemies": [{"pos": Vector2(300, 0), "weight": 2.0}, {"pos": Vector2(100, 0), "weight": 1.0}],
		"enemy_centroid": Vector2(200, 0),
		"own_centroid": Vector2(30, 40),
		"anchor": Vector2(-500, 0),
	}
	var modes := {
		"enemy_centroid": Vector2(200, 0),
		"enemy_nearest": Vector2(100, 0),  # 300 与 100 取近者
		"own_centroid": Vector2(30, 40),
		"garrison_anchor": Vector2(-500, 0),
		"squad_pos": Vector2(10, 20),
	}
	for mode in modes:
		var got: Vector2 = scorer.resolve_target({"target": {"mode": mode}}, ctx)
		_runner.assert_true(got == modes[mode], "target mode=%s 解析正确" % mode)
	# 缺省 / 未知模式 → own_centroid 兜底（防守语义）
	_runner.assert_true(scorer.resolve_target({}, ctx) == Vector2(30, 40), "缺省 target 兜底 own_centroid")
	_runner.assert_true(scorer.resolve_target({"target": {"mode": "flank_route"}}, ctx) == Vector2(30, 40),
			"未知模式兜底 own_centroid")
	# enemy_nearest 空敌 → 敌方质心兜底
	var ctx_noenemy := {"squad_pos": Vector2.ZERO, "enemies": [], "enemy_centroid": Vector2(200, 0)}
	_runner.assert_true(scorer.resolve_target({"target": {"mode": "enemy_nearest"}}, ctx_noenemy)
			== Vector2(200, 0), "enemy_nearest 空敌兜底敌质心")


func _test_order_mapping() -> void:
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("advance"), ScriptTacticalOrders.OrderType.ADVANCE_ALL, "advance")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("sprint"), ScriptTacticalOrders.OrderType.SPRINT, "sprint")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("hold"), ScriptTacticalOrders.OrderType.HOLD_POSITION, "hold")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("retreat"), ScriptTacticalOrders.OrderType.RETREAT, "retreat")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("take_cover"), ScriptTacticalOrders.OrderType.TAKE_COVER, "take_cover")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("rally"), ScriptTacticalOrders.OrderType.RALLY, "rally")
	_runner.assert_equal(ScriptUtilityScorer.order_type_of("flank"), -1, "未知行为名 -1（解析期丢弃）")


func _test_team_ai_zero_regression() -> void:
	# 开关默认关（零回归门）：root_c 配置了 default_behavior 也不消费——
	# 无显式号令小队维持防守兜底（ADVANCE_ALL 本方质心），选择观测面为空
	# （4v3：adv=(8-6)/14=0.143 < 优势递增起点 0.4 → attack%=0.6 → 2 攻 1 防）
	var ctx := _make_org_ctx({})
	ctx.org_api.set_behavior("root_c", _hold_on_enemy_behavior())
	for i in 4:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	for i in 3:
		ctx.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_a", "root_a")
	ctx.add_squad("s_b", "root_b")
	ctx.add_squad("s_c", "root_c")
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	_runner.assert_equal(ctx.ai.get_task_board().slot_count(ScriptTaskBoard.KIND_ATTACK), 2,
			"期望进攻槽数 = ceil(0.6×3) = 2")
	var call_of := {}
	for c in ctx.orders.org_calls:
		call_of[c["org_id"]] = c
	_runner.assert_equal(call_of.size(), 3, "三编制组各一号令")
	if call_of.has("root_c"):
		_runner.assert_equal(int(call_of["root_c"]["order_type"]), ScriptTacticalOrders.OrderType.ADVANCE_ALL,
				"开关关：root_c 走防守兜底 ADVANCE_ALL")
		_runner.assert_approx(call_of["root_c"]["target"].x, 530.0, 1.0, "开关关：目标 = 本方质心")
	_runner.assert_true(ctx.ai.get_default_behavior_choices().is_empty(), "选择观测面为空（未消费）")
	ctx.teardown()


func _test_team_ai_v2_override() -> void:
	# 开关开：无显式号令（防守槽）小队按效用打分选行为；攻击槽绑定小队保持任务号令
	# （4v3 场景同零回归门：attack%=0.6 → 序位前两攻击槽 + 第三防守槽）
	var ctx := _make_org_ctx({"default_behavior_v2_enabled": true})
	ctx.org_api.set_behavior("root_c", _hold_on_enemy_behavior())
	for i in 4:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	for i in 3:
		ctx.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_a", "root_a")
	ctx.add_squad("s_b", "root_b")
	ctx.add_squad("s_c", "root_c")
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 前置链路自证：开关经 overlay/补挂入 _p；org_api 经 duck 探测到手
	_runner.assert_true(bool(ctx.ai._p.get("default_behavior_v2_enabled", false)), "开关已入 _p")
	_runner.assert_true(ctx.ai._org_api != null, "org_api 已探测")
	var call_of := {}
	for c in ctx.orders.org_calls:
		call_of[c["org_id"]] = c
	_runner.assert_equal(call_of.size(), 3, "三编制组各一号令")
	# 序位前两组绑攻击槽：保持槽目标号令（显式任务 > default_behavior）
	if call_of.has("root_a") and call_of.has("root_b"):
		_runner.assert_equal(int(call_of["root_a"]["order_type"]), ScriptTacticalOrders.OrderType.ADVANCE_ALL,
				"攻击槽组保持 ADVANCE_ALL")
		_runner.assert_gt(call_of["root_a"]["target"].x, 1000.0, "攻击槽组目标在敌方向（槽目标）")
	# 第三组防守槽：default_behavior 接管 → hold（敌情 +150 稳压中性候选）
	if call_of.has("root_c"):
		_runner.assert_equal(int(call_of["root_c"]["order_type"]), ScriptTacticalOrders.OrderType.HOLD_POSITION,
				"防守兜底组按打分选 hold")
		_runner.assert_approx(call_of["root_c"]["target"].x, 530.0, 1.0, "hold 目标 = own_centroid 模式解析")
	var choices: Dictionary = ctx.ai.get_default_behavior_choices()
	_runner.assert_equal(str(choices.get("s_c", "")), "hold", "选择观测面记录 hold")
	_runner.assert_false(choices.has("s_a"), "攻击槽组不留选择记录（未被接管）")
	ctx.teardown()


func _test_team_ai_garrison_exempt() -> void:
	# GARRISON 生存模式：号令 RALLY 己方锚点，default_behavior 不接管（生存 > 战术偏好）
	var ctx := _make_org_ctx({"default_behavior_v2_enabled": true})
	ctx.org_api.set_behavior("root_a", _hold_on_enemy_behavior())
	ctx.org_api.set_behavior("root_b", _hold_on_enemy_behavior())
	ctx.org_api.set_behavior("root_c", _hold_on_enemy_behavior())
	for i in 3:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(600, 300), ScriptTeamAiProfiles.SPEAR)  # 锚点 900 内 → 敌近触发驻守
	ctx.add_squad("s_a", "root_a")
	ctx.add_squad("s_b", "root_b")
	ctx.add_squad("s_c", "root_c")
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_GARRISON, "敌近触发 GARRISON")
	_runner.assert_equal(ctx.orders.org_calls.size(), 3, "三编制组各一号令（RALLY）")
	for c in ctx.orders.org_calls:
		_runner.assert_equal(int(c["order_type"]), ScriptTacticalOrders.OrderType.RALLY,
				"GARRISON 号令不被 default_behavior 接管（%s）" % c["org_id"])
	_runner.assert_true(ctx.ai.get_default_behavior_choices().is_empty(), "生存模式不留选择记录")
	ctx.teardown()


# ─────────────────────────────── 夹具 ────────────────────────────────

## hold-on-enemy 行为配置（提案 schema）：敌情时高需求 hold（±150 稳压中性候选，与种子无关）
func _hold_on_enemy_behavior() -> Dictionary:
	return {
		"candidates": [
			{"name": "advance", "demand": {}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 3.0}]}},
		],
	}


## 参数齐全的打分器（脱离 BalanceConfig 单测内核；RefCounted 无需 teardown）
func _make_scorer(overrides: Dictionary) -> ScriptUtilityScorer:
	var scorer: ScriptUtilityScorer = ScriptUtilityScorer.new()
	scorer.setup(ScriptTeamAiProfiles.get_profile(overrides))
	return scorer


func _make_org_ctx(overrides: Dictionary) -> _Ctx:
	var ctx := _Ctx.new()
	ctx.setup(overrides)
	return ctx


class _Ctx:
	var battle: _FakeBattle
	var orders: _FakeOrders
	var formation: _FakeFormation
	var org_api: _FakeOrgApi
	var ai: TeamAi

	func setup(overrides: Dictionary = {}) -> void:
		battle = _FakeBattle.new()
		org_api = _FakeOrgApi.new()
		orders = _FakeOrders.new()
		orders._org_api = org_api  # TeamAi._resolve_org_api 同模块 duck 探测消费
		formation = _FakeFormation.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, orders, formation, overrides)

	func teardown() -> void:
		if ai != null:
			ai.dispose()
		if battle != null:
			battle.queue_free()
		if orders != null:
			orders.queue_free()
		if formation != null:
			formation.queue_free()
		if org_api != null:
			org_api.queue_free()

	func add_own_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 1, wtype)

	func add_enemy_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 2, wtype)

	func add_squad(squad_id: String, root: String) -> void:
		formation.add_squad(squad_id, 1, true, 3)
		orders.org_roots[squad_id] = root


class _FakeBattle extends Node:
	var duration: float = 0.0
	var _units: Array = []
	var _anchor_faction1 := Vector2(500, 300)
	var _anchor_faction2 := Vector2(1500, 300)

	func add_unit(pos: Vector2, faction: int, wtype: int) -> void:
		var u := _FakeUnit.new()
		u.global_position = pos
		u.faction = faction
		u.weapon_type = wtype
		u.dead = false
		_units.append(u)

	func get_allies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction == faction)

	func get_enemies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction != faction)

	func get_duration() -> float:
		return duration

	func is_active() -> bool:
		return true

	func get_battle_id() -> String:
		return "test_battle"

	func get_faction_side_anchor(faction: int) -> Vector2:
		return _anchor_faction1 if faction == 1 else _anchor_faction2


## 编制号令桩（issue/issue_to_org 记录 + get_org_root_for_squad 代理 + _org_api duck 探测面）
class _FakeOrders extends Node:
	var calls: Array = []
	var org_calls: Array = []
	var org_roots: Dictionary = {}
	var _org_api: Node = null

	func issue(order_type: int, squad_id: String, target_pos: Vector2, source_tier: int,
			extra_params: Dictionary = {}) -> bool:
		calls.append({
			"order_type": order_type,
			"squad_id": squad_id,
			"target": target_pos,
			"source_tier": source_tier,
			"extra_params": extra_params,
		})
		return true

	func issue_to_org(org_id: String, order_type: int, target_pos: Vector2,
			extra_params: Dictionary = {}) -> bool:
		org_calls.append({
			"org_id": org_id,
			"order_type": order_type,
			"target": target_pos,
			"extra": extra_params,
		})
		return true

	func get_org_root_for_squad(squad_id: String) -> String:
		return str(org_roots.get(squad_id, ""))


## 组织 API 桩（get_organization 只喂 default_behavior；organization 侧只读消费契约）
class _FakeOrgApi extends Node:
	var _behaviors: Dictionary = {}

	func set_behavior(org_id: String, behavior: Dictionary) -> void:
		_behaviors[org_id] = behavior

	func get_organization(org_id: String) -> Dictionary:
		return {"ok": true, "data": {"id": org_id, "default_behavior": _behaviors.get(org_id, {})}}


class _FakeFormation extends Node:
	var _squads: Dictionary = {}  # squad_id -> {faction, is_combat, units}

	func add_squad(squad_id: String, faction: int, is_combat: bool, unit_count: int) -> void:
		var units: Array = []
		for i in unit_count:
			var u := _FakeUnit.new()
			u.faction = faction
			u.weapon_type = ScriptTeamAiProfiles.SPEAR
			u.dead = false
			units.append(u)
		_squads[squad_id] = {"faction": faction, "is_combat": is_combat, "units": units}

	func get_all_squads() -> Array:
		return _squads.keys()

	func get_squad_units(squad_id: String) -> Array:
		if not _squads.has(squad_id):
			return []
		return _squads[squad_id]["units"]

	func is_combat_squad(squad_id: String) -> bool:
		if not _squads.has(squad_id):
			return false
		return _squads[squad_id]["is_combat"]


class _FakeUnit extends Node2D:
	var faction: int = 0
	var weapon_type: int = 0
	var dead: bool = false

	func is_dead() -> bool:
		return dead

	func get_faction() -> int:
		return faction

	func get_weapon() -> Node:
		return self
