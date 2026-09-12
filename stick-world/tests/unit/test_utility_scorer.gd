extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：A4 · C7 效用打分选择器 + W1 · WorldBox softmax 轮盘（设计文档12号 §三C7 / §五批次表 A4；
## W1 真值 docs/审计/worldbox-reverse/1-个体AI内核.md §二 M2/M6/M7 与 §三 Top1）。
## 覆盖：档案键（W1 五键默认 + A4 既有键）/ 三件套解析（含 W1 候选键透传）/ filter 资格过滤 fail-closed /
## demand ±分 / 方差扰动界 / 按小队错峰 / softmax 轮盘软优先（份额 + 采样胜率一致）/
## 数值稳定（极端量纲不溢出）/ 温度调节 / argmax 退化路径逐位一致锁 / weight_rules 状态调制 /
## weight_calculate_enabled=false 忽略权重 / 冷却窗口与恢复 / launch 失败入冷却 / cooldown_enabled=false /
## 空档案与非法值兜底 / 同种子确定性 / target 模式 / 行为名 -> OrderType 映射 /
## TeamAi 接入（默认关零回归 / v2 接管 / GARRISON 生存豁免）。
## 不进场景树（fixture 用 new() + 局部 add_child，用完即弃；BalanceConfig 只读，先例 test_task_board）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptUtilityScorer := preload("res://modules/combat/scripts/battle/utility_scorer.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

## 采样基准种子（"最高权重胜率 / 份额贴合"类用例统一口径，便于对照）
const SAMPLE_SEED: int = 20260911

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("档案键：W1 五键默认 + A4 既有键 + 空档案代码默认", _test_config_keys)
	_runner.add_test("三件套解析：规范候选保留 / 非法条目丢弃 / W1 候选键透传", _test_parse_candidates)
	_runner.add_test("filter 资格过滤：谓词 AND / 未知谓词 fail-closed", _test_filter)
	_runner.add_test("demand ±分：命中 +50 未命中 -50 / 倍率 / 无规则中性", _test_demand)
	_runner.add_test("方差扰动界：|扰动| ≤ variance × increment / variance=0 精确", _test_variance_bounds)
	_runner.add_test("按小队错峰：同局面不同小队扰动不同 / 同小队确定性一致", _test_squad_stagger)
	_runner.add_test("softmax 软优先：最高权重胜率 > 60% / 最低权重非零胜率（非 argmax）", _test_pick_behavior)
	_runner.add_test("轮盘份额：Σweight_share = 1 / 等权近似均匀 / 与采样胜率贴合", _test_rollout_distribution)
	_runner.add_test("数值稳定：demand_increment 5000 与 1e200 不溢出 / 份额仍按 softmax", _test_numeric_stability)
	_runner.add_test("温度：调大更均匀 / 调小更集中高权重", _test_temperature)
	_runner.add_test("退化路径锁：softmax_enabled=false 与升级前 argmax 逐位一致", _test_argmax_degradation)
	_runner.add_test("weight_rules 状态调制：命中取规则 / 未命中回退 weight / 缺省 0", _test_weight_rules)
	_runner.add_test("weight_calculate_enabled=false：权重被忽略（等价无权重布局）", _test_weight_calculate_disabled)
	_runner.add_test("冷却窗口：窗口内不被选中 / 到点恢复", _test_cooldown_window)
	_runner.add_test("launch 失败入冷却：target 非有限 → launch_failed + 入冷却", _test_cooldown_on_launch_failure)
	_runner.add_test("cooldown_enabled=false：冷却判定全跳过", _test_cooldown_disabled)
	_runner.add_test("空档案 / 非法数值：代码默认兜底不崩溃", _test_empty_profile)
	_runner.add_test("确定性：同 (base_seed, squad_id) 两次调用逐位一致", _test_determinism)
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
	# personality.tres global 行（配置真值）：A4 既有键
	_runner.assert_false(bool(BalanceConfig.get_value("ai.personality.global.default_behavior_v2_enabled")),
			"default_behavior_v2_enabled 默认关（零回归门）")
	_runner.assert_approx(float(BalanceConfig.get_value("ai.personality.global.demand_increment")), 50.0, 0.001,
			"demand_increment = 50（CoH s_demand_increment 真值）")
	# W1 五键档案真值（WorldBox M2/M6/M7）
	_runner.assert_true(bool(BalanceConfig.get_value("ai.personality.global.softmax_enabled")),
			"softmax_enabled 默认开（W1 轮盘是选择规则升级，先例 slot_kernel_enabled）")
	_runner.assert_approx(float(BalanceConfig.get_value("ai.personality.global.softmax_weight_scale")), 0.02, 1e-9,
			"softmax_weight_scale = 0.02（= 1/demand_increment，CoH 分 -> WorldBox 权重域归一）")
	_runner.assert_approx(float(BalanceConfig.get_value("ai.personality.global.softmax_temperature")), 1.0, 1e-9,
			"softmax_temperature = 1.0（WorldBox randomnessFactor 真值量纲）")
	_runner.assert_true(bool(BalanceConfig.get_value("ai.personality.global.weight_calculate_enabled")),
			"weight_calculate_enabled 默认开（M7 权重委托）")
	_runner.assert_true(bool(BalanceConfig.get_value("ai.personality.global.cooldown_enabled")),
			"cooldown_enabled 默认开（M6 launch 冷却）")
	# 装载器携带新键（TeamAi.setup 合并链可消费）
	var overlay: Dictionary = ScriptTeamAiProfiles.load_personality_overlay()
	_runner.assert_false(bool(overlay.get("default_behavior_v2_enabled", true)), "overlay 携带 A4 开关（默认关）")
	_runner.assert_approx(float(overlay.get("demand_increment", -1.0)), 50.0, 0.001, "overlay 携带 ±分增量")
	_runner.assert_true(bool(overlay.get("softmax_enabled", false)), "overlay 携带 W1 轮盘开关")
	_runner.assert_approx(float(overlay.get("softmax_weight_scale", -1.0)), 0.02, 1e-9, "overlay 携带量纲归一尺度")
	# 代码默认兜底（空档案）：scorer 语义不依赖配置存在性
	var scorer := _make_scorer({})
	_runner.assert_approx(scorer._increment(), 50.0, 0.001, "空档案回退 increment 50（代码默认）")
	_runner.assert_approx(scorer._variance(), 0.8, 0.001, "空档案回退 variance 0.8（A1 单旋钮既有默认）")
	_runner.assert_true(scorer._softmax_enabled(), "空档案回退 softmax_enabled = true（代码默认）")
	_runner.assert_approx(scorer._weight_scale(), 0.02, 1e-9, "空档案回退 softmax_weight_scale = 0.02")
	_runner.assert_approx(scorer._temperature(), 1.0, 1e-9, "空档案回退 softmax_temperature = 1.0")
	_runner.assert_true(scorer._weight_calculate_enabled(), "空档案回退 weight_calculate_enabled = true")
	_runner.assert_true(scorer._cooldown_enabled(), "空档案回退 cooldown_enabled = true")


func _test_parse_candidates() -> void:
	var behavior := {
		"candidates": [
			{"name": "advance", "filter": {}, "demand": {"rules": []}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold", "weight": 2.5, "weight_rules": [{"when": {"enemy_present": true}, "weight": 0.3}],
					"cooldown": 60.0, "cooldown_on_launch_failure": false},
			{"name": "flank"},  # 未知行为名（不可映射 OrderType）→ 丢弃
			{"nope": true},  # 缺 name → 丢弃
			"garbage",  # 非字典 → 丢弃
		],
	}
	var parsed: Array = ScriptUtilityScorer.parse_candidates(behavior)
	_runner.assert_equal(parsed.size(), 2, "非法条目丢弃，合法候选保留 2")
	if parsed.size() == 2:
		_runner.assert_equal(str(parsed[0]["name"]), "advance", "配置序保留（候选评估按序消耗随机流）")
		_runner.assert_equal(str(parsed[1]["name"]), "hold", "缺省 filter/demand/target 补空字典")
		# W1 候选键透传（weight 缺席 = 键不存在 = 权重 0 基线）
		_runner.assert_false(parsed[0].has("weight"), "无 weight 配置 = 键缺席（权重 0 基线）")
		_runner.assert_approx(float(parsed[0]["cooldown"]), 0.0, 1e-9, "cooldown 缺省 0（不冷却）")
		_runner.assert_true(bool(parsed[0]["cooldown_on_launch_failure"]),
				"cooldown_on_launch_failure 缺省 true（WorldBox DecisionAsset 真值）")
		_runner.assert_approx(float(parsed[1]["weight"]), 2.5, 1e-9, "静态 weight 透传")
		_runner.assert_equal((parsed[1]["weight_rules"] as Array).size(), 1, "weight_rules 透传")
		_runner.assert_approx(float(parsed[1]["cooldown"]), 60.0, 1e-9, "cooldown 透传（claim_land 60s 同构）")
		_runner.assert_false(bool(parsed[1]["cooldown_on_launch_failure"]), "失败入冷却开关透传")
	# 负 cooldown 钳 0（旋钮鲁棒）
	var neg: Array = ScriptUtilityScorer.parse_candidates({"candidates": [{"name": "hold", "cooldown": -5.0}]})
	_runner.assert_approx(float(neg[0]["cooldown"]), 0.0, 1e-9, "负 cooldown 钳 0")
	# weight_rules 非数组 = 键缺席（fail-closed 到静态 weight）
	var bad_rules: Array = ScriptUtilityScorer.parse_candidates(
			{"candidates": [{"name": "hold", "weight": 1.0, "weight_rules": "oops"}]})
	_runner.assert_false(bad_rules[0].has("weight_rules"), "weight_rules 非数组 = 键缺席")
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
	# 未知谓词 fail-closed（配置笔误不放开激进行为；weight_rules 同词汇复用此语义）
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
	var ctx := _basic_ctx()
	var candidate := {"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}}]}}
	var raw: float = scorer.score_candidate(candidate, ctx)
	_runner.assert_approx(raw, 50.0, 0.001, "原始分 50 基准")
	# 100 个小队流：扰动界 |perturbed - raw| ≤ 0.8 × 50 = 40（单候选必选中，观测面直达）
	var hit_low: bool = false
	var hit_high: bool = false
	for i in 100:
		var pick: Dictionary = scorer.pick_behavior({"candidates": [candidate]}, ctx, "sq_%03d" % i, SAMPLE_SEED)
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
	var pick0: Dictionary = scorer_v0.pick_behavior({"candidates": [candidate]}, ctx, "sq_x", SAMPLE_SEED)
	_runner.assert_approx(float(pick0["perturbed"]), raw, 0.001, "variance=0 扰动归零")
	# 负 variance 钳 0（旋钮鲁棒）
	var scorer_vn := _make_scorer({"demand_variance": -1.0})
	var pickn: Dictionary = scorer_vn.pick_behavior({"candidates": [candidate]}, ctx, "sq_x", SAMPLE_SEED)
	_runner.assert_approx(float(pickn["perturbed"]), raw, 0.001, "负 variance 钳 0")


func _test_squad_stagger() -> void:
	# 同局面同拍（同 base_seed）：不同小队各掷各的（防齐套），同小队跨调用确定一致
	var scorer := _make_scorer({"demand_variance": 0.8})
	var behavior := {"candidates": [{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}}]}}]}
	var ctx := _basic_ctx()
	var p1: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", SAMPLE_SEED)
	var p2: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_beta", SAMPLE_SEED)
	var p1_again: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", SAMPLE_SEED)
	_runner.assert_not_equal(float(p1["perturbed"]), float(p2["perturbed"]),
			"同拍不同小队扰动不同（错峰防齐套）")
	_runner.assert_approx(float(p1["perturbed"]), float(p1_again["perturbed"]), 0.0001,
			"同小队同局面确定性一致（battle_sim 可复现）")
	# base_seed 不同 → 流不同（逐局随机种子语义）
	var scorer2 := _make_scorer({"demand_variance": 0.8})
	var p_other_seed: Dictionary = scorer2.pick_behavior(behavior, ctx, "sq_alpha", 42)
	_runner.assert_not_equal(float(p1["perturbed"]), float(p_other_seed["perturbed"]),
			"base_seed 变 → 扰动流变")


## 轮盘软优先（WorldBox M2）：高分候选是"更可能"而非"必选"。
## hold 原始分 +50 → 权重域 w = 50 × 0.02 = 1.0 → 份额 e/(e+1) ≈ 0.731
func _test_pick_behavior() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0})  # 关方差锁份额（扰动不影响份额比较）
	var ctx := _basic_ctx()
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}},
		],
	}
	var ev := scorer.evaluate_candidates(behavior, ctx, "sq_a", 1)
	_runner.assert_equal(ev.size(), 2, "两候选均在评估集")
	_runner.assert_approx(_share_of(ev, "hold"), 0.7310586, 0.005,
			"份额 = softmax(w)：hold w=1 → 0.731（软优先，非必选）")
	_runner.assert_approx(_share_of(ev, "advance"), 1.0 - 0.7310586, 0.005, "低权重候选亦占份额")
	# 采样 200：最高权重胜率 > 60%，最低权重有非零胜率（argmax 下后者恒为 0）
	var rates := _sample_win_rates(scorer, behavior, ctx, 200, SAMPLE_SEED)
	_runner.assert_gt(rates.get("hold", 0.0), 0.6, "最高权重候选胜率 > 60%（软优先）")
	_runner.assert_gt(rates.get("advance", 0.0), 0.0, "最低权重候选有非零胜率（证明不是 argmax）")
	# 胜出候选携带映射号令 + W1 附加键
	var pick := scorer.pick_behavior(behavior, ctx, "sq_a", 1)
	_runner.assert_true(pick.has("weight") and pick.has("weight_share"), "返回字典额外携带 weight / weight_share")
	_runner.assert_equal(int(pick["order_type"]), ScriptUtilityScorer.order_type_of(str(pick["name"])),
			"胜出候选携带映射号令")
	_runner.assert_approx(float(pick["score"]), 50.0 if str(pick["name"]) == "hold" else 0.0, 0.001,
			"score = 未扰动原始分")
	# 资格过滤前置：唯一候选不合格 → 空（调用方走既有兜底）
	var pick_none: Dictionary = scorer.pick_behavior(
			{"candidates": [{"name": "hold", "filter": {"no_enemy": true}}]}, ctx, "sq_a", 1)
	_runner.assert_true(pick_none.is_empty(), "全不合格 → 空（既有兜底语义）")
	# 单合格候选 → 份额恒 1，必选中（退化为点质量）
	var solo := scorer.pick_behavior({"candidates": [{"name": "rally"}]}, ctx, "sq_a", 1)
	_runner.assert_equal(str(solo["name"]), "rally", "单候选恒选中")
	_runner.assert_approx(float(solo["weight_share"]), 1.0, 1e-9, "单候选份额 = 1")
	# 无候选（v1 透传字典）→ 空
	_runner.assert_true(scorer.pick_behavior({"stance": "hold"}, ctx, "sq_a", 1).is_empty(), "无候选 → 空")


## 轮盘份额（WorldBox M2）：Σshare = 1、等权候选近似均匀、份额与采样胜率贴合（N=400 偏离 < 0.1）
func _test_rollout_distribution() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0})
	var ctx := _basic_ctx()
	# 等权三候选（无 demand 无 weight）→ 份额各 1/3
	var tie := {"candidates": [{"name": "advance"}, {"name": "hold"}, {"name": "rally"}]}
	var ev := scorer.evaluate_candidates(tie, ctx, "sq", 7)
	_runner.assert_equal(ev.size(), 3, "三候选均在评估集")
	var share_sum: float = 0.0
	for e in ev:
		share_sum += float(e["weight_share"])
	_runner.assert_approx(share_sum, 1.0, 1e-4, "Σweight_share = 1（浮点容差 1e-4）")
	for e in ev:
		_runner.assert_approx(float(e["weight_share"]), 1.0 / 3.0, 1e-4,
				"等权候选份额 = 1/3（%s）" % str(e["name"]))
	var rates := _sample_win_rates(scorer, tie, ctx, 400, 7)
	for name in ["advance", "hold", "rally"]:
		var r := float(rates.get(name, 0.0))
		_runner.assert_true(r >= 1.0 / 3.0 - 0.1 and r <= 1.0 / 3.0 + 0.1,
				"等权候选采样胜率落在 1/3 ± 0.1（%s = %.3f）" % [name, r])
	# 非等权布局：份额与采样胜率一致（N=400 偏离 < 0.1）
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}},
		],
	}
	var ev2 := scorer.evaluate_candidates(behavior, ctx, "sq", 7)
	var rates2 := _sample_win_rates(scorer, behavior, ctx, 400, 7)
	for name in ["advance", "hold"]:
		var share := _share_of(ev2, name)
		var rate := float(rates2.get(name, 0.0))
		_runner.assert_true(absf(rate - share) < 0.1,
				"采样胜率贴合份额（%s：份额 %.3f vs 胜率 %.3f）" % [name, share, rate])


## 数值稳定：CoH 分数量纲远大于 WorldBox 权重域，softmax 须先减 max 再 exp（否则 exp(300) = INF）
func _test_numeric_stability() -> void:
	var ctx := _basic_ctx()
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 3.0}]}},
		],
	}
	# demand_increment = 5000（hold 原始分 15000 → w = 300，未移位 exp 必 INF）
	var big := _make_scorer({"demand_variance": 0.0, "demand_increment": 5000.0})
	var ev_big := big.evaluate_candidates(behavior, ctx, "sq", 1)
	_runner.assert_equal(ev_big.size(), 2, "大增量下两候选仍在评估集")
	var sum_big: float = 0.0
	for e in ev_big:
		_runner.assert_true(is_finite(float(e["weight"])), "轮盘权重有限（%s）" % str(e["name"]))
		_runner.assert_true(is_finite(float(e["weight_share"])), "份额有限（%s）" % str(e["name"]))
		sum_big += float(e["weight_share"])
	_runner.assert_approx(sum_big, 1.0, 1e-4, "Σ份额 = 1（无 INF/NaN）")
	_runner.assert_approx(_share_of(ev_big, "hold"), 1.0, 1e-4, "极大分差下高权重份额趋近 1（数值稳定）")
	var rates_big := _sample_win_rates(big, behavior, ctx, 100, 1)
	_runner.assert_approx(float(rates_big.get("hold", 0.0)), 1.0, 0.05, "采样胜率仍按份额（≈1）")
	# ±50 基准量纲（默认档案）：份额仍是 softmax 而非退化
	var base := _make_scorer({"demand_variance": 0.0})
	var ev_base := base.evaluate_candidates(behavior, ctx, "sq", 1)
	_runner.assert_approx(_share_of(ev_base, "hold"), 0.9525741, 0.005, "increment=50 时 hold w=3 → 份额 0.953")
	# 极端量纲 1e200（未做 max 移位的 exp 直接溢出）
	var huge := _make_scorer({"demand_variance": 0.0, "demand_increment": 1.0e200})
	var ev_huge := huge.evaluate_candidates(behavior, ctx, "sq", 1)
	var sum_huge: float = 0.0
	for e in ev_huge:
		_runner.assert_true(is_finite(float(e["weight"])), "1e200 量纲权重有限（%s）" % str(e["name"]))
		_runner.assert_true(is_finite(float(e["weight_share"])), "1e200 量纲份额有限（%s）" % str(e["name"]))
		_runner.assert_true(not is_nan(float(e["weight_share"])), "1e200 量纲份额非 NaN（%s）" % str(e["name"]))
		sum_huge += float(e["weight_share"])
	_runner.assert_approx(sum_huge, 1.0, 1e-4, "1e200 量纲 Σ份额 = 1")


## 温度（WorldBox randomnessFactor 量纲）：>1 更均匀、<1 更集中于最高权重
func _test_temperature() -> void:
	var ctx := _basic_ctx()
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 2.0}]}},
		],
	}
	var h1 := _share_of(_make_scorer({"demand_variance": 0.0}).evaluate_candidates(behavior, ctx, "sq", 1), "hold")
	var h_hot := _share_of(_make_scorer({"demand_variance": 0.0, "softmax_temperature": 3.0})
			.evaluate_candidates(behavior, ctx, "sq", 1), "hold")
	var h_cold := _share_of(_make_scorer({"demand_variance": 0.0, "softmax_temperature": 0.3})
			.evaluate_candidates(behavior, ctx, "sq", 1), "hold")
	_runner.assert_approx(h1, 0.8807971, 0.005, "T=1：hold w=2 → 份额 e²/(e²+1) = 0.881")
	_runner.assert_lt(h_hot, h1, "温度调大 → 分布更均匀（最高权重份额下降）")
	_runner.assert_gt(h_cold, h1, "温度调小 → 更集中于最高权重")
	# 采样佐证（N=200，高温档胜率下降 / 低温档上升）
	var rates_hot := _sample_win_rates(_make_scorer({"demand_variance": 0.0, "softmax_temperature": 3.0}),
			behavior, ctx, 200, SAMPLE_SEED)
	_runner.assert_lt(float(rates_hot.get("hold", 1.0)), 0.8, "高温档采样胜率下降")
	var rates_cold := _sample_win_rates(_make_scorer({"demand_variance": 0.0, "softmax_temperature": 0.3}),
			behavior, ctx, 200, SAMPLE_SEED)
	_runner.assert_gt(float(rates_cold.get("hold", 0.0)), 0.95, "低温档采样胜率上升")
	# 非法温度回退默认（防除零/反向温度）
	var bad := _make_scorer({"softmax_temperature": -2.0})
	_runner.assert_approx(bad._temperature(), 1.0, 1e-9, "非正温度回退默认 1.0")


## 退化路径锁：softmax_enabled=false 必须与升级前 argmax 逐位一致（含 RNG 消耗序与五键结构）
func _test_argmax_degradation() -> void:
	var ctx := _basic_ctx()
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}},
			{"name": "rally", "demand": {"rules": [{"when": {"threatened": true}, "score": 2.0}]}},
		],
	}
	var scorer := _make_scorer({"softmax_enabled": false})  # demand_variance 保持既有默认 0.8
	var cands: Array = ScriptUtilityScorer.parse_candidates(behavior)
	var got: Dictionary = {}
	# 与升级前 argmax 的独立重实现逐位对比（12 个小队流，覆盖不同扰动抽签）
	for i in 12:
		var squad := "sq_%02d" % i
		got = scorer.pick_behavior(behavior, ctx, squad, SAMPLE_SEED)
		var want: Dictionary = _legacy_argmax(scorer, cands, ctx, 0.8, 50.0,
				hash(str(SAMPLE_SEED) + ":" + squad))
		_runner.assert_equal(str(got.get("name", "")), str(want.get("name", "")), "条 %d：胜者一致" % i)
		_runner.assert_equal(int(got.get("order_type", -2)), int(want.get("order_type", -1)),
				"条 %d：号令映射一致" % i)
		_runner.assert_approx(float(got.get("score", 0.0)), float(want.get("score", 0.0)), 0.0,
				"条 %d：原始分逐位一致" % i)
		_runner.assert_approx(float(got.get("perturbed", 0.0)), float(want.get("perturbed", 0.0)), 0.0,
				"条 %d：扰动后分逐位一致" % i)
		_runner.assert_true(Vector2(got.get("target", Vector2.ZERO)) == Vector2(want.get("target", Vector2.ZERO)),
				"条 %d：目标一致" % i)
	# 退化返回结构 = 升级前原样五键（无 W1 附加键）
	_runner.assert_false(got.has("weight"), "退化结构不带 weight（与升级前逐位一致）")
	_runner.assert_false(got.has("weight_share"), "退化结构不带 weight_share")
	# 零方差下 = 纯 argmax 点质量（variance=0 时扰动为 0，最高原始分恒胜）
	var argmax0 := _make_scorer({"softmax_enabled": false, "demand_variance": 0.0})
	var rates_arg := _sample_win_rates(argmax0, behavior, ctx, 50, SAMPLE_SEED)
	_runner.assert_equal(rates_arg.size(), 1, "variance=0 的退化路径恒选同一候选（点质量）")
	_runner.assert_true(rates_arg.has("hold"), "胜者 = 最高原始分候选 hold")
	# 升级路径确实不是 argmax：同布局同种子下低权重候选有非零胜率
	var softmax0 := _make_scorer({"demand_variance": 0.0})
	var rates_sm := _sample_win_rates(softmax0, behavior, ctx, 200, SAMPLE_SEED)
	_runner.assert_gt(float(rates_sm.get("advance", 0.0)), 0.0, "softmax 路径低权重候选有非零胜率（非 argmax）")
	_runner.assert_true(rates_sm.size() >= 2, "softmax 路径出现多个胜者（软优先级）")


## weight_rules 状态调制（WorldBox M7）：命中第一条规则取规则权重，全不命中回退静态 weight
func _test_weight_rules() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0})
	var ctx := _basic_ctx()  # 有敌（enemy_present 真）
	# 命中第一条规则（enemy_present）
	var c1 := {"candidates": [{"name": "hold", "weight": 1.0, "weight_rules": [
		{"when": {"enemy_present": true}, "weight": 5.0},
		{"when": {"no_enemy": true}, "weight": 0.1},
	]}]}
	_runner.assert_approx(_weight_of(scorer.evaluate_candidates(c1, ctx, "sq", 1), "hold"), 5.0, 1e-6,
			"命中第一条规则取规则权重 5（WorldBox run_away 量级）")
	# 规则按序短路：第一条不命中取第二条
	var c2 := {"candidates": [{"name": "hold", "weight": 1.0, "weight_rules": [
		{"when": {"no_enemy": true}, "weight": 9.0},
		{"when": {"enemy_present": true}, "weight": 3.0},
	]}]}
	_runner.assert_approx(_weight_of(scorer.evaluate_candidates(c2, ctx, "sq", 1), "hold"), 3.0, 1e-6,
			"第一条不命中 → 短路到第二条")
	# 全部未命中 → 回退静态 weight
	var c3 := {"candidates": [{"name": "hold", "weight": 2.0, "weight_rules": [
		{"when": {"no_enemy": true}, "weight": 9.0},
	]}]}
	_runner.assert_approx(_weight_of(scorer.evaluate_candidates(c3, ctx, "sq", 1), "hold"), 2.0, 1e-6,
			"规则全不命中 → 回退静态 weight（2.0）")
	# 未知谓词 fail-closed：规则视为不命中 → 回退静态 weight
	var c4 := {"candidates": [{"name": "hold", "weight": 0.7, "weight_rules": [
		{"when": {"flank_speed": 1.0}, "weight": 9.0},
	]}]}
	_runner.assert_approx(_weight_of(scorer.evaluate_candidates(c4, ctx, "sq", 1), "hold"), 0.7, 1e-6,
			"未知谓词 = 不命中 → 回退静态 weight")
	# 两者都缺省 = 权重 0，与"无 weight 键"布局完全等价
	var with_w := {"candidates": [{"name": "hold", "weight": 0.0}]}
	var no_w := {"candidates": [{"name": "hold"}]}
	var ev_with := scorer.evaluate_candidates(with_w, ctx, "sq", 1)
	var ev_no := scorer.evaluate_candidates(no_w, ctx, "sq", 1)
	_runner.assert_approx(_weight_of(ev_with, "hold"), 0.0, 1e-9, "weight=0 与缺省同义（权重 0 基线）")
	_runner.assert_approx(_weight_of(ev_with, "hold"), _weight_of(ev_no, "hold"), 0.0, "权重逐位一致")
	_runner.assert_approx(_share_of(ev_with, "hold"), _share_of(ev_no, "hold"), 0.0,
			"份额逐位一致（既有配置零变化）")
	# 带 demand 时同理：weight=0 与不带 weight 的总权重/份额逐位一致（既有配置零变化）
	var demand_with := {"candidates": [{"name": "hold", "weight": 0.0,
			"demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}}]}
	var demand_no := {"candidates": [{"name": "hold",
			"demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}}]}
	var ev_dw := scorer.evaluate_candidates(demand_with, ctx, "sq", 1)
	var ev_dn := scorer.evaluate_candidates(demand_no, ctx, "sq", 1)
	_runner.assert_approx(_weight_of(ev_dw, "hold"), _weight_of(ev_dn, "hold"), 0.0,
			"静态权重 0 不改变 demand 分导出的权重")
	_runner.assert_approx(_share_of(ev_dw, "hold"), _share_of(ev_dn, "hold"), 0.0, "份额逐位一致")


## weight_calculate_enabled=false（W1 退化闸门）：忽略 weight/weight_rules，只用 demand 分
func _test_weight_calculate_disabled() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0, "weight_calculate_enabled": false})
	var ctx := _basic_ctx()
	var with_w := {"candidates": [
		{"name": "hold", "weight": 5.0, "weight_rules": [{"when": {"enemy_present": true}, "weight": 9.0}],
				"demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}},
	]}
	var ev := scorer.evaluate_candidates(with_w, ctx, "sq", 1)
	_runner.assert_approx(_weight_of(ev, "hold"), 1.0, 1e-6,
			"权重被忽略：只剩 demand 分 50 × 0.02 = 1.0")
	var no_w := {"candidates": [
		{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 1.0}]}},
	]}
	var ev_no := scorer.evaluate_candidates(no_w, ctx, "sq", 1)
	_runner.assert_approx(_weight_of(ev, "hold"), _weight_of(ev_no, "hold"), 0.0,
			"与不带 weight 的布局逐位等价（权重通道彻底旁路）")


## 冷却窗口（WorldBox M6）：窗口内候选等价 filter 不合格，到点恢复可选
func _test_cooldown_window() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0})
	var ctx := _basic_ctx()
	var behavior := {"candidates": [
		{"name": "advance", "weight": 5.0, "cooldown": 10.0},
		{"name": "hold"},
	]}
	_runner.assert_false(scorer.is_on_cooldown("advance", 0.0), "无登记不冷却")
	_runner.assert_equal(scorer.evaluate_candidates(behavior, ctx, "sq", 1, 0.0).size(), 2, "初始两候选均在")
	# 记账后窗口内：候选被摘出可选集
	scorer.note_launched("advance", 100.0)
	_runner.assert_true(scorer.is_on_cooldown("advance", 105.0), "窗口内冷却中")
	_runner.assert_false(scorer.is_on_cooldown("advance", 110.0), "到点解除（世界时刻口径）")
	_runner.assert_false(scorer.is_on_cooldown("hold", 105.0), "未记账行为不受影响")
	var ev_cd := scorer.evaluate_candidates(behavior, ctx, "sq", 1, 105.0)
	_runner.assert_equal(ev_cd.size(), 1, "冷却中候选等价不合格（只剩 hold）")
	if ev_cd.size() == 1:
		_runner.assert_equal(str(ev_cd[0]["name"]), "hold", "冷却把 advance 摘出可选集")
	var pick_cd: Dictionary = scorer.pick_behavior(behavior, ctx, "sq", 1, 105.0)
	_runner.assert_equal(str(pick_cd.get("name", "")), "hold", "窗口内不选中冷却候选")
	# 窗口过后恢复：高权重候选份额回归主导
	var ev_after := scorer.evaluate_candidates(behavior, ctx, "sq", 1, 200.0)
	_runner.assert_equal(ev_after.size(), 2, "窗口过后恢复可选")
	_runner.assert_gt(_share_of(ev_after, "advance"), 0.9, "恢复后高权重候选（w=5）份额回归主导")


## launch 失败入冷却（WorldBox DecisionAsset.cs:8,30 + UBDS.cs:131-138）
func _test_cooldown_on_launch_failure() -> void:
	var behavior := {"candidates": [
		{"name": "advance", "cooldown": 60.0, "target": {"mode": "squad_pos"}},
	]}
	# target 非有限 = launch 失败 → 入冷却
	var scorer := _make_scorer({"demand_variance": 0.0})
	var ctx := _basic_ctx()
	ctx["squad_pos"] = Vector2.INF
	var pick: Dictionary = scorer.pick_behavior_and_commit(behavior, ctx, "sq", 1, 0.0)
	_runner.assert_false(pick.is_empty(), "命中候选（返回非空字典）")
	_runner.assert_true(bool(pick.get("launch_failed", false)), "target 非有限 → launch_failed = true")
	_runner.assert_true(scorer.is_on_cooldown("advance", 30.0), "失败也入冷却（claim_land 60s 同构）")
	_runner.assert_false(scorer.is_on_cooldown("advance", 60.0), "冷却到点解除")
	# 成功路径：有限 target → note_launched，不带 launch_failed
	var scorer2 := _make_scorer({"demand_variance": 0.0})
	var pick2: Dictionary = scorer2.pick_behavior_and_commit(behavior, _basic_ctx(), "sq", 1, 0.0)
	_runner.assert_false(pick2.has("launch_failed"), "成功路径不带 launch_failed")
	_runner.assert_true(scorer2.is_on_cooldown("advance", 30.0), "成功即入冷却")
	# cooldown_on_launch_failure=false → 失败不登记冷却
	var b_off := {"candidates": [
		{"name": "advance", "cooldown": 60.0, "cooldown_on_launch_failure": false,
				"target": {"mode": "squad_pos"}},
	]}
	var scorer3 := _make_scorer({"demand_variance": 0.0})
	var ctx3 := _basic_ctx()
	ctx3["squad_pos"] = Vector2.INF
	var pick3: Dictionary = scorer3.pick_behavior_and_commit(b_off, ctx3, "sq", 1, 0.0)
	_runner.assert_true(bool(pick3.get("launch_failed", false)), "仍标记 launch_failed")
	_runner.assert_false(scorer3.is_on_cooldown("advance", 30.0), "关闭失败入冷却 → 不登记")
	# 空候选 → 空返回（commit 入口零副作用）
	_runner.assert_true(scorer3.pick_behavior_and_commit({"stance": "hold"}, ctx3, "sq", 1, 0.0).is_empty(),
			"无候选 → 空返回")


## cooldown_enabled=false：冷却判定全跳过（零回归退化闸门）
func _test_cooldown_disabled() -> void:
	var scorer := _make_scorer({"demand_variance": 0.0, "cooldown_enabled": false})
	var ctx := _basic_ctx()
	var behavior := {"candidates": [{"name": "advance", "cooldown": 60.0}]}
	scorer.pick_behavior(behavior, ctx, "sq", 1, 0.0)  # 先评估以缓存候选冷却参数
	scorer.note_launched("advance", 0.0)
	_runner.assert_false(scorer.is_on_cooldown("advance", 1.0), "开关关：冷却判定全跳过")
	_runner.assert_equal(scorer.evaluate_candidates(behavior, ctx, "sq", 1, 1.0).size(), 1,
			"开关关：候选不被摘出可选集")
	_runner.assert_false(scorer.pick_behavior(behavior, ctx, "sq", 1, 1.0).is_empty(),
			"开关关：冷却候选仍可被选中")


## 档案缺载（空 profile 字典）/ 非法数值：代码默认兜底，不崩溃
func _test_empty_profile() -> void:
	var bare: ScriptUtilityScorer = ScriptUtilityScorer.new()
	bare.setup({})
	_runner.assert_approx(bare._increment(), 50.0, 1e-9, "空档案 increment 兜底 50")
	_runner.assert_true(bare._softmax_enabled(), "空档案 softmax_enabled 兜底 true")
	_runner.assert_approx(bare._weight_scale(), 0.02, 1e-9, "空档案 softmax_weight_scale 兜底 0.02")
	_runner.assert_approx(bare._temperature(), 1.0, 1e-9, "空档案 softmax_temperature 兜底 1.0")
	_runner.assert_true(bare._weight_calculate_enabled(), "空档案 weight_calculate_enabled 兜底 true")
	_runner.assert_true(bare._cooldown_enabled(), "空档案 cooldown_enabled 兜底 true")
	var ctx := _basic_ctx()
	var behavior := {"candidates": [{"name": "advance"}, {"name": "hold"}]}
	var pick: Dictionary = bare.pick_behavior(behavior, ctx, "sq", 1)
	_runner.assert_true(pick.has("name"), "空档案仍能选中（不崩溃）")
	var ev := bare.evaluate_candidates(behavior, ctx, "sq", 1)
	var sum: float = 0.0
	for e in ev:
		sum += float(e["weight_share"])
	_runner.assert_approx(sum, 1.0, 1e-4, "空档案份额仍归一")
	# 非法数值（缩放 0 / 温度负）回退代码默认，不产生除零或 INF
	var bad := _make_scorer({"softmax_weight_scale": 0.0, "softmax_temperature": -3.0})
	_runner.assert_approx(bad._weight_scale(), 0.02, 1e-9, "缩放 ≤0 回退默认（防除零）")
	_runner.assert_approx(bad._temperature(), 1.0, 1e-9, "温度 ≤0 回退默认（防反向温度）")
	var ev_bad := bad.evaluate_candidates(behavior, ctx, "sq", 1)
	var sum_bad: float = 0.0
	for e in ev_bad:
		_runner.assert_true(is_finite(float(e["weight_share"])), "非法档案份额有限")
		sum_bad += float(e["weight_share"])
	_runner.assert_approx(sum_bad, 1.0, 1e-4, "非法档案份额仍归一（不产生 NaN）")


## 确定性：同 (base_seed, squad_id) 两次调用逐位一致；不同小队/种子流不同
func _test_determinism() -> void:
	var scorer := _make_scorer({})  # demand_variance 默认 0.8（含扰动流确定性）
	var ctx := _basic_ctx()
	var behavior := {
		"candidates": [
			{"name": "advance", "demand": {}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 2.0}]}},
		],
	}
	var p1: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", SAMPLE_SEED)
	var p2: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_alpha", SAMPLE_SEED)
	_runner.assert_equal(str(p1.get("name", "")), str(p2.get("name", "")), "两次调用胜者一致")
	_runner.assert_approx(float(p1.get("score", 0.0)), float(p2.get("score", 0.0)), 0.0, "原始分逐位一致")
	_runner.assert_approx(float(p1.get("perturbed", 0.0)), float(p2.get("perturbed", 0.0)), 0.0,
			"扰动后分逐位一致（含轮盘掷骰）")
	_runner.assert_approx(float(p1.get("weight", 0.0)), float(p2.get("weight", 0.0)), 0.0, "轮盘权重逐位一致")
	_runner.assert_approx(float(p1.get("weight_share", 0.0)), float(p2.get("weight_share", 0.0)), 0.0,
			"份额逐位一致")
	_runner.assert_true(Vector2(p1.get("target", Vector2.ZERO)) == Vector2(p2.get("target", Vector2.ZERO)),
			"目标一致")
	# 选中项必为评估快照的一员（同一播种、同一 RNG 消耗序）
	var ev := scorer.evaluate_candidates(behavior, ctx, "sq_alpha", SAMPLE_SEED)
	var matched: Dictionary = {}
	for e in ev:
		if str(e["name"]) == str(p1.get("name", "")):
			matched = e
	_runner.assert_false(matched.is_empty(), "选中项来自评估快照")
	_runner.assert_approx(float(matched.get("perturbed", 0.0)), float(p1.get("perturbed", 0.0)), 0.0,
			"快照与选中项扰动一致（同播种）")
	_runner.assert_approx(float(matched.get("weight_share", 0.0)), float(p1.get("weight_share", 0.0)), 0.0,
			"快照与选中项份额一致（同播种）")
	# 不同小队 → 扰动流不同（错峰）
	var p_beta: Dictionary = scorer.pick_behavior(behavior, ctx, "sq_beta", SAMPLE_SEED)
	_runner.assert_not_equal(float(p_beta.get("perturbed", 0.0)), float(p1.get("perturbed", 0.0)),
			"不同小队扰动流不同（错峰防齐套）")


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
	# 第三组防守槽：default_behavior 接管 → hold（hold 份额 ≈ 1，轮盘下近乎必然选中）
	if call_of.has("root_c"):
		_runner.assert_equal(int(call_of["root_c"]["order_type"]), ScriptTacticalOrders.OrderType.HOLD_POSITION,
				"防守兜底组按打分选 hold（轮盘高份额候选）")
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

## hold-on-enemy 行为配置（提案 schema）：敌情时高权重 hold（w=12，份额 ≈ 1，轮盘下近乎必然选中）
func _hold_on_enemy_behavior() -> Dictionary:
	return {
		"candidates": [
			{"name": "advance", "demand": {}, "target": {"mode": "enemy_centroid"}},
			{"name": "hold", "demand": {"rules": [{"when": {"enemy_present": true}, "score": 12.0}]}},
		],
	}


## 参数齐全的打分器（脱离 BalanceConfig 单测内核；RefCounted 无需 teardown）。
## get_profile 只透传 DEFAULTS 既有键，W1 新键不在其键集内，故档案层二次补挂 overrides
## （与 TeamAi.setup 对 A4 键的补挂同构）。
func _make_scorer(overrides: Dictionary) -> ScriptUtilityScorer:
	var scorer: ScriptUtilityScorer = ScriptUtilityScorer.new()
	var profile: Dictionary = ScriptTeamAiProfiles.get_profile(overrides)
	profile.merge(overrides, true)
	scorer.setup(profile)
	return scorer


## 标准战斗上下文（有敌 300px；各质心/锚点齐备）
func _basic_ctx() -> Dictionary:
	return {
		"squad_pos": Vector2.ZERO,
		"enemies": [{"pos": Vector2(300, 0), "weight": 2.0}],
		"enemy_centroid": Vector2(300, 0),
		"own_centroid": Vector2.ZERO,
		"anchor": Vector2(-500, 0),
		"threatened": false,
		"own_strength": 10.0,
		"initial_own_strength": 10.0,
	}


## 按小队流采样胜率（每样本换 squad_id = 换随机流；配合 demand_variance=0 时份额恒定）
func _sample_win_rates(scorer: ScriptUtilityScorer, behavior: Dictionary, ctx: Dictionary,
		n: int, base_seed: int) -> Dictionary:
	var wins: Dictionary = {}
	for i in n:
		var pick: Dictionary = scorer.pick_behavior(behavior, ctx, "smpl_%05d" % i, base_seed)
		if pick.is_empty():
			continue
		var name := str(pick.get("name", ""))
		wins[name] = int(wins.get(name, 0)) + 1
	var rates: Dictionary = {}
	for name in wins:
		rates[name] = float(wins[name]) / float(n)
	return rates


## 评估集内某候选的轮盘权重（不存在返回 -1）
func _weight_of(entries: Array, name: String) -> float:
	for e in entries:
		if str(e.get("name", "")) == name:
			return float(e.get("weight", 0.0))
	return -1.0


## 评估集内某候选的选中概率份额（不存在返回 -1）
func _share_of(entries: Array, name: String) -> float:
	for e in entries:
		if str(e.get("name", "")) == name:
			return float(e.get("weight_share", 0.0))
	return -1.0


## 升级前 argmax 算法的独立重实现（退化路径逐位一致锁的对照物）：
## 与 utility_scorer._pick_argmax 同 RNG 消耗序、同比较语义（严格大于 = 平局取序首位）、同五键结构。
func _legacy_argmax(scorer: ScriptUtilityScorer, candidates: Array, ctx: Dictionary,
		variance: float, increment: float, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var best: Dictionary = {}
	var best_perturbed: float = -1.0e18
	for c in candidates:
		if not scorer.filter_passes(c, ctx):
			continue
		var raw: float = scorer.score_candidate(c, ctx)
		var perturbed: float = raw + rng.randf_range(-1.0, 1.0) * variance * increment
		if perturbed > best_perturbed:
			best_perturbed = perturbed
			best = {
				"name": c["name"],
				"order_type": ScriptUtilityScorer.order_type_of(str(c["name"])),
				"target": scorer.resolve_target(c, ctx),
				"score": raw,
				"perturbed": perturbed,
			}
	return best


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
