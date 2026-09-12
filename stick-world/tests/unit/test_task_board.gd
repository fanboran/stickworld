extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TeamAi A2 任务槽 + 目标评分 + 攻击百分比（设计文档12号 C3/C4/C5，AI集大成）。
## 覆盖：BalanceConfig 装载 A2 参数（单一 global 行，难度分档已裁决移除·开放问题#3）/
## 槽同步与生命周期（集结超时杀槽/目标超时重定向）/
## 四因子评分（threat/avoid_clumps/distance/inertia）/ pick_target 确定性 /
## 小队匹配 / 攻击百分比四规则（门禁/基调/优势递增/基地威胁封顶/VP 缺省关闭）/
## 槽驱动姿态与滞回带 / SWL 退化路径 / 下令路径分流（散兵 issue / 编制 issue_to_org）/
## 编制整组手动号令避让 / 多小队槽匹配号令。
## 不进场景树，确定性（FakeBattle/FakeOrders/FakeFormation；只读 BalanceConfig autoload，
## 先例 test_team_ai_personality）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("BalanceConfig 装载 A2 参数（单一 global 行）", _test_config_loaded)
	_runner.add_test("槽同步：只增删空槽/槽带目标与集结点/超额杀最旧", _test_slot_sync)
	_runner.add_test("槽生命周期：目标超时重定向记脏 / 集结超时杀槽", _test_slot_lifecycle)
	_runner.add_test("四因子评分：threat 加分", _test_score_threat)
	_runner.add_test("四因子评分：无威胁时敌群聚集惩罚", _test_score_clump)
	_runner.add_test("四因子评分：距离惩罚 + inertia 防振荡奖励", _test_score_distance_inertia)
	_runner.add_test("pick_target 确定性：单候选/空候选 fallback/平局取近", _test_pick_target)
	_runner.add_test("小队匹配：攻击槽序位绑定，超出部分绑防守/落空", _test_match_groups)
	_runner.add_test("攻击百分比：门禁内 0 / 基调 0.6 / 优势递增封顶 0.70", _test_attack_pct_rules)
	_runner.add_test("攻击百分比：基地威胁封顶硬帽 / VP 规则缺省关闭", _test_attack_pct_caps)
	_runner.add_test("槽驱动姿态：有攻击槽→ATTACK / 滞回带保持 / 槽清空→DEFEND", _test_slot_driven_stance)
	_runner.add_test("SWL 退化路径：内核关闭走比例条件，号令目标=敌质心", _test_degenerate_path)
	_runner.add_test("下令路径分流：散兵 issue / 编制 issue_to_org 同根去重", _test_order_path_routing)
	_runner.add_test("编制整组手动号令避让 + 散兵逐队避让", _test_org_group_manual_guard)
	_runner.add_test("多小队槽匹配号令：攻击组收槽目标 / 防守位收本方质心", _test_multi_squad_slot_orders)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_config_loaded() -> void:
	# global 行：C4 四因子权重（CoH 真值）+ C3 槽超时（CoH 真值）+ 内核开关
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.score_threat"), 5.0, 0.001, "score_threat = 5.0（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.score_avoid_clumps_at_no_threat"), 10.0, 0.001, "avoid_clumps = 10.0（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.score_inertia"), 1.4, 0.001, "inertia = 1.4（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.attack_rally_timeout"), 180.0, 0.001, "攻击槽集结超时 3min（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.attack_target_timeout"), 30.0, 0.001, "攻击槽目标超时 30s（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.defend_target_timeout"), 120.0, 0.001, "防守槽目标超时 2min（CoH）")
	_runner.assert_true(bool(BalanceConfig.get_value("ai.personality.global.slot_kernel_enabled")), "槽内核默认开")
	_runner.assert_false(bool(BalanceConfig.get_value("ai.personality.global.vp_rule_enabled")), "VP 规则缺省关闭（开放问题#1 提案/待定）")
	# global 行：C5 攻击百分比参数上移（原 standard 档数值 = 代码默认镜像，零回归基线）
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.attack_pct_baseline"), 0.6, 0.001, "基调 0.6（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.attack_pct_growth_per_min"), 0.01, 0.001, "每分钟 +0.01（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.max_attack_percentage"), 0.70, 0.001, "封顶 0.70（CoH）")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.superiority_gain"), 1.0, 0.001, "优势增益 1.0")
	# 难度分档维度已裁决移除：仅余单一 global 行（开放问题#3）
	var rows: Variant = BalanceConfig.get("data").get("ai.personality", [])
	_runner.assert_true(rows is Array and (rows as Array).size() == 1, "personality 仅单一行（难度行已移除）")
	if rows is Array and (rows as Array).size() == 1:
		_runner.assert_equal(str((rows[0] as Dictionary).get("id", "")), "global", "唯一行 = global")
	# 装载器：无参 overlay 合并携带内核与基调参数
	var overlay: Dictionary = ScriptTeamAiProfiles.load_personality_overlay()
	_runner.assert_approx(float(overlay.get("score_threat", -1.0)), 5.0, 0.001, "overlay 含 C4 权重")
	_runner.assert_approx(float(overlay.get("attack_pct_baseline", -1.0)), 0.6, 0.001, "overlay 含 C5 基调")


func _test_slot_sync() -> void:
	var board: ScriptTaskBoard = _make_board()
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 0, Vector2.ZERO, Vector2.ZERO, 0.0)
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_ATTACK), 0, "初始 0 槽")
	# 增：新建槽带目标/集结点/创建时刻
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 2, Vector2(100, 50), Vector2(10, 20), 5.0)
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_ATTACK), 2, "增到 2 攻击槽")
	var s1: Variant = board.get_slot("atk_001")
	_runner.assert_true(s1 != null, "槽 id 稳定可断言（atk_001）")
	if s1 != null:
		_runner.assert_true(s1.target == Vector2(100, 50), "槽带攻击目标")
		_runner.assert_true(s1.rally == Vector2(10, 20), "槽带集结点")
		_runner.assert_approx(float(s1.created_at), 5.0, 0.001, "槽带创建时刻")
	# 删：超额杀最旧（创建序即优先序）——atk_001 保留，atk_002 被杀
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 1, Vector2(100, 50), Vector2(10, 20), 6.0)
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_ATTACK), 1, "缩到 1 攻击槽")
	_runner.assert_true(board.get_slot("atk_001") != null, "最旧槽保留")
	_runner.assert_true(board.get_slot("atk_002") == null, "较新槽被杀")
	# 现存槽不因 sync 重定位（防逐拍振荡）
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 1, Vector2(999, 999), Vector2.ZERO, 7.0)
	if board.get_slot("atk_001") != null:
		_runner.assert_true(board.get_slot("atk_001").target == Vector2(100, 50), "现存槽不随 sync 重定位")


func _test_slot_lifecycle() -> void:
	var board: ScriptTaskBoard = _make_board()
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 1, Vector2(100, 0), Vector2.ZERO, 0.0)
	var rescore_hits: Array = []
	var rescore: Callable = func(_slot: Variant) -> Vector2:
		rescore_hits.append(1)
		return Vector2(200, 0)
	# 目标超时前（< 30s）：无重定向
	var dirty: Array = board.tick(10.0, rescore)
	_runner.assert_true(dirty.is_empty(), "目标超时前不重定向")
	# 目标超时（≥ 30s）：重评分重定向 + 记脏（下令方重发号令）
	dirty = board.tick(30.0, rescore)
	_runner.assert_equal(dirty.size(), 1, "目标超时记脏 1 槽")
	_runner.assert_equal(rescore_hits.size(), 1, "重评分回调消费 1 次")
	if dirty.size() == 1:
		var slot: Variant = board.get_slot(str(dirty[0]))
		_runner.assert_true(slot != null and slot.target == Vector2(200, 0), "槽目标已重定位")
	# 集结超时（≥ 180s）：杀槽（战略侧 sync 下拍按 desired 重建）
	board.tick(180.0, rescore)
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_ATTACK), 0, "集结超时杀槽（CoH 杀不活跃任务）")
	# 匹配表随杀槽解绑
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 1, Vector2.ZERO, Vector2.ZERO, 200.0)
	board.match_groups([{"key": "s1", "squads": ["s1"]}])
	_runner.assert_equal(board.slot_of_squad("s1"), "atk_002", "重建槽后重新匹配")
	board.tick(400.0, rescore)
	_runner.assert_equal(board.slot_of_squad("s1"), "", "杀槽解绑匹配")


func _test_score_threat() -> void:
	var board: ScriptTaskBoard = _make_board()
	var base_ctx := {
		"squad_pos": Vector2.ZERO,
		"base_pos": Vector2.ZERO,
		"enemies": [],
		"own_strength": 10.0,
		"last_target": Vector2.INF,
	}
	var empty_score: float = board.score_target(Vector2(500, 0), base_ctx)
	# 单敌 weight 10 在候选点 260 半径内：threat = min(10/10, 1) = 1.0 → +5.0
	var ctx_enemy := base_ctx.duplicate()
	ctx_enemy["enemies"] = [{"pos": Vector2(520, 0), "weight": 10.0}]
	var enemy_score: float = board.score_target(Vector2(500, 0), ctx_enemy)
	_runner.assert_approx(enemy_score - empty_score, 5.0, 0.01, "威胁因子：周边敌军力量 → +w_threat")
	# 敌军远离候选点（> 260px）：threat = 0 → 不加分
	var ctx_far := base_ctx.duplicate()
	ctx_far["enemies"] = [{"pos": Vector2(900, 0), "weight": 10.0}]
	_runner.assert_approx(board.score_target(Vector2(500, 0), ctx_far), empty_score, 0.01, "半径外敌军不计威胁")


func _test_score_clump() -> void:
	var board: ScriptTaskBoard = _make_board()
	var ctx := {
		"squad_pos": Vector2.ZERO,
		"base_pos": Vector2.ZERO,
		"enemies": [],
		"own_strength": 10.0,
		"last_target": Vector2.INF,
	}
	var clean_score: float = board.score_target(Vector2(500, 0), ctx)
	# 敌 weight 2 距候选 280px：威胁半径 260 外（threat=0）、聚集半径 300 内
	# → clump = 2/10 = 0.2 → -10 × 0.2 = -2.0（CoH avoid_clumps_at_no_threat 语义）
	var ctx_clump := ctx.duplicate()
	ctx_clump["enemies"] = [{"pos": Vector2(780, 0), "weight": 2.0}]
	var clump_score: float = board.score_target(Vector2(500, 0), ctx_clump)
	_runner.assert_approx(clump_score - clean_score, -2.0, 0.01, "无威胁敌群聚集 → -w_clump 惩罚")
	# 有威胁时不罚聚集（有仗打不避人堆）：敌 weight 10 在 260 内既给威胁又成群
	var ctx_hot := ctx.duplicate()
	ctx_hot["enemies"] = [{"pos": Vector2(520, 0), "weight": 10.0}]
	_runner.assert_approx(board.score_target(Vector2(500, 0), ctx_hot) - clean_score, 5.0, 0.01,
			"有威胁时只计威胁不罚聚集")


func _test_score_distance_inertia() -> void:
	var board: ScriptTaskBoard = _make_board()
	var ctx := {
		"squad_pos": Vector2.ZERO,
		"base_pos": Vector2.ZERO,
		"enemies": [],
		"own_strength": 10.0,
		"last_target": Vector2.INF,
	}
	var near_score: float = board.score_target(Vector2(300, 0), ctx)
	var far_score: float = board.score_target(Vector2(900, 0), ctx)
	# 距小队/基地各差 600px = 0.5 归一 → 近者少扣 2 × 5.0 × 0.5 = 5.0
	_runner.assert_approx(near_score - far_score, 5.0, 0.01, "距离因子：近者优（距小队+距基地双计）")
	# inertia：候选 = last_target（120 容差内）→ +1.4
	var ctx_a := ctx.duplicate()
	ctx_a["last_target"] = Vector2(300, 0)
	var a_score: float = board.score_target(Vector2(300, 0), ctx_a)
	_runner.assert_approx(a_score - near_score, 1.4, 0.01, "惯性因子：与上次目标一致 → +w_inertia")
	# 容差外不给惯性
	var ctx_b := ctx.duplicate()
	ctx_b["last_target"] = Vector2(0, 500)
	_runner.assert_approx(board.score_target(Vector2(300, 0), ctx_b), near_score, 0.01, "容差外无惯性奖励")


func _test_pick_target() -> void:
	var board: ScriptTaskBoard = _make_board()
	var ctx := {
		"squad_pos": Vector2.ZERO,
		"base_pos": Vector2.ZERO,
		"enemies": [],
		"own_strength": 10.0,
		"last_target": Vector2.INF,
		"fallback": Vector2(77, 77),
	}
	_runner.assert_true(board.pick_target([], ctx) == Vector2(77, 77), "空候选 → fallback")
	_runner.assert_true(board.pick_target([Vector2(42, 0)], ctx) == Vector2(42, 0), "单候选直取")
	# 平局（对称等距同威胁）取更近小队者——两者等距 → 保持候选序首位（确定性）
	var picked: Vector2 = board.pick_target([Vector2(300, 0), Vector2(-300, 0)], ctx)
	_runner.assert_true(picked == Vector2(300, 0), "平局保持候选序首位（确定性）")
	# inertia 翻转：等距双候选，last_target 在后者 → 惯性加分让后者胜出（防振荡）
	var ctx_inertia := ctx.duplicate()
	ctx_inertia["last_target"] = Vector2(-300, 0)
	picked = board.pick_target([Vector2(300, 0), Vector2(-300, 0)], ctx_inertia)
	_runner.assert_true(picked == Vector2(-300, 0), "惯性保持上次目标（防振荡）")


func _test_match_groups() -> void:
	var board: ScriptTaskBoard = _make_board()
	board.sync_slots(ScriptTaskBoard.KIND_ATTACK, 1, Vector2(100, 0), Vector2.ZERO, 0.0)
	board.sync_slots(ScriptTaskBoard.KIND_DEFEND, 1, Vector2.ZERO, Vector2.ZERO, 0.0)
	var mapping: Dictionary = board.match_groups([
		{"key": "g0", "squads": ["s0a", "s0b"]},
		{"key": "g1", "squads": ["s1a"]},
		{"key": "g2", "squads": ["s2a"]},
	])
	_runner.assert_equal(board.slot_of_squad("s0a"), "atk_001", "序位第一组绑攻击槽")
	_runner.assert_equal(board.slot_of_squad("s0b"), "atk_001", "编制组成员同槽（原子）")
	_runner.assert_equal(board.slot_of_squad("s1a"), "def_001", "次位组绑防守槽")
	_runner.assert_equal(str(mapping.get("s2a", "")), "", "槽不足的组不绑定")


func _test_attack_pct_rules() -> void:
	# 门禁内（standard 10±2，duration 3 必未开）→ 0（CoH start_attack_time 前攻击% = 0）
	var ctx := _make_ctx({})
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 3.0
	ctx.ai.update()
	_runner.assert_approx(ctx.ai.recalculate_attack_percentage(), 0.0, 0.001, "开局门禁内 attack% = 0")
	ctx.teardown()
	# 门禁过 + 力量均势（ratio 1.0，无优势递增）→ 基调 0.6（增长 ≤0.12min 可忽略）
	var ctx2 := _make_ctx({})
	for i in 3:
		ctx2.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
		ctx2.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.battle.duration = 15.0
	ctx2.ai.update()
	_runner.assert_approx(ctx2.ai.recalculate_attack_percentage(), 0.6, 0.01, "门禁过 + 均势 → 难度基调 0.6")
	ctx2.teardown()
	# 军力优势递增：adv = (20-2)/22 = 0.818 > 0.4 → 0.6 + 0.418 → 封顶 0.70
	var ctx3 := _make_ctx({})
	for i in 10:
		ctx3.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx3.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx3.battle.duration = 15.0
	ctx3.ai.update()
	_runner.assert_approx(ctx3.ai.recalculate_attack_percentage(), 0.70, 0.001, "优势递增受 max 封顶 0.70")
	ctx3.teardown()
	# 遗留键 difficulty 宽容忽略（难度分档已裁决移除·开放问题#3）：传入不炸，
	# attack% 仍走单一参数曲线（与 ctx3 同局面同结果：优势递增封顶 0.70）
	var ctx4 := _make_ctx({"difficulty": "easy"})
	for i in 10:
		ctx4.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx4.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx4.battle.duration = 30.0
	ctx4.ai.update()
	_runner.assert_approx(ctx4.ai.recalculate_attack_percentage(), 0.70, 0.001, "遗留 difficulty 键忽略，单一曲线封顶 0.70")
	ctx4.teardown()


func _test_attack_pct_caps() -> void:
	# 基地威胁封顶：敌军全部压在锚点 900 半径内 → threat = 6/6×100 = 100
	# → cap = max(100-100, 5)/100 = 0.05（CoH max(100-threat, 5)）
	var ctx := _make_ctx({})
	for i in 3:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(600, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(620, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(640, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_approx(ctx.ai.threat_at_base(), 100.0, 0.01, "基地威胁 = 半径内敌力/初始基线 × 100")
	_runner.assert_approx(ctx.ai.recalculate_attack_percentage(), 0.05, 0.001, "基地威胁封顶 → 0.05（CoH floor 5%）")
	ctx.teardown()
	# 敌军远离锚点 → 威胁 0，不触封顶
	var ctx2 := _make_ctx({})
	ctx2.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.add_enemy_unit(Vector2(1800, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.battle.duration = 15.0
	ctx2.ai.update()
	_runner.assert_approx(ctx2.ai.threat_at_base(), 0.0, 0.01, "远敌不构成基地威胁")
	ctx2.teardown()
	# VP 规则缺省关闭：开关打开也只是钩子透传（无 VP 等价物，开放问题#1 提案/待定）
	var ctx3 := _make_ctx({"vp_rule_enabled": true})
	ctx3.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx3.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx3.battle.duration = 15.0
	ctx3.ai.update()
	var pct_vpon: float = ctx3.ai.recalculate_attack_percentage()
	_runner.assert_true(pct_vpon > 0.0 and pct_vpon <= 1.0, "VP 开关打开不崩溃（钩子透传）")
	ctx3.teardown()


func _test_slot_driven_stance() -> void:
	# 占优 + 门禁过 → 攻击槽创建 → ATTACK（槽驱动；编队缺失退化 atomic=1）
	var ctx := _make_ctx({})
	_add_ratio3_setup(ctx)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "槽内核：攻击槽存在 → ATTACK")
	_runner.assert_true(ctx.ai.get_task_board().has_attack_slots(), "攻击槽已创建")
	ctx.teardown()
	# 滞回带（SWL attack_exit 语义转写）：6 矛(12) v 1 矛(2) → ratio 6 ATTACK；
	# 补敌到 5 矛(10) → ratio 1.2 ∈ (1.10, 1.30) 带内不塌槽保持 ATTACK；
	# 再补 1 矛(12) → ratio 1.0 ≤ attack_exit → 槽清空 → DEFEND
	var ctx2 := _make_ctx({})
	for i in 6:
		ctx2.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.battle.duration = 15.0
	ctx2.ai.update()
	_runner.assert_equal(ctx2.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK（ratio 6）")
	for i in 4:
		ctx2.add_enemy_unit(Vector2(1520 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.battle.duration = 21.0
	ctx2.ai.update()
	_runner.assert_equal(ctx2.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "滞回带内（ratio 1.2）槽不塌、姿态保持")
	ctx2.add_enemy_unit(Vector2(1620, 300), ScriptTeamAiProfiles.SPEAR)
	ctx2.battle.duration = 27.0
	ctx2.ai.update()
	_runner.assert_equal(ctx2.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "ratio ≤ attack_exit → 槽清空 → DEFEND")
	_runner.assert_false(ctx2.ai.get_task_board().has_attack_slots(), "攻击槽已清空")
	ctx2.teardown()


func _test_degenerate_path() -> void:
	# slot_kernel_enabled=false：SWL 比例条件内核接手（签名保留的退化路径）
	var ctx := _make_ctx({"slot_kernel_enabled": false})
	_add_ratio3_setup(ctx)
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "退化路径：ratio≥enter → ATTACK")
	# 退化路径号令目标 = 敌方质心（旧语义），不走槽目标
	var calls: Array = ctx.orders.calls
	_runner.assert_true(calls.size() > 0, "退化路径照常发号令")
	if calls.size() > 0:
		_runner.assert_approx(calls[0]["target"].x, 1500.0, 1.0, "退化路径 ATTACK 目标 = 敌质心")
		_runner.assert_equal(calls[0]["source_tier"], 1, "AI tier=1 语义不变")
	ctx.teardown()


func _test_order_path_routing() -> void:
	# 组织化编制（同 root 两小队）+ 散兵：编制走 issue_to_org 同根去重，散兵走 issue
	var ctx := _make_org_ctx({"s_org_a": "root_a", "s_org_b": "root_a", "s_loose": ""})
	for i in 4:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	for i in 3:
		ctx.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_org_a", 1)
	ctx.add_squad("s_org_b", 1)
	ctx.add_squad("s_loose", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "应切 ATTACK")
	var org_calls: Array = ctx.orders.org_calls
	var loose_calls: Array = ctx.orders.calls
	_runner.assert_equal(org_calls.size(), 1, "编制同根一号令（去重）")
	if org_calls.size() == 1:
		_runner.assert_equal(org_calls[0]["org_id"], "root_a", "下令到组织根")
		_runner.assert_equal(org_calls[0]["order_type"], ScriptTacticalOrders.OrderType.ADVANCE_ALL, "ADVANCE_ALL")
	_runner.assert_equal(loose_calls.size(), 1, "散兵走 issue 直令")
	if loose_calls.size() == 1:
		_runner.assert_equal(loose_calls[0]["squad_id"], "s_loose", "散兵 squad_id 直令")
	ctx.teardown()


func _test_org_group_manual_guard() -> void:
	# 编制组任一成员手动号令保护期内 → 整组避让；散兵逐队避让
	var ctx := _make_org_ctx({"s_org_a": "root_a", "s_org_b": "root_a", "s_loose": ""})
	for i in 4:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	for i in 3:
		ctx.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_org_a", 1)
	ctx.add_squad("s_org_b", 1)
	ctx.add_squad("s_loose", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	ctx.orders.calls.clear()
	ctx.orders.org_calls.clear()
	# 玩家手动号令：编制组一员 + 散兵（tier=0）
	EventBus.order_issued.emit(ScriptTacticalOrders.OrderType.HOLD_POSITION, "s_org_a", 0)
	EventBus.order_issued.emit(ScriptTacticalOrders.OrderType.HOLD_POSITION, "s_loose", 0)
	# 力量反转切 DEFEND（冷却 5s 过，保护期 8s 未过）
	ctx.kill_own_units(3)
	ctx.add_enemy_unit(Vector2(1560, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1580, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 21.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "切 DEFEND")
	var org_calls: Array = ctx.orders.org_calls
	_runner.assert_equal(org_calls.size(), 0, "编制组任一成员保护期内 → 整组避让（root_a 无号令）")
	var issued: Array = []
	for c in ctx.orders.calls:
		issued.append(c["squad_id"])
	_runner.assert_false(issued.has("s_loose"), "散兵保护期内避让")
	ctx.teardown()


func _test_multi_squad_slot_orders() -> void:
	# 3 散兵 + attack% 0.6 → ceil(0.6×3)=2 攻击槽：前 2 组收槽目标，第 3 组收本方质心
	var ctx := _make_org_ctx({})
	for i in 4:
		ctx.add_own_unit(Vector2(500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	for i in 3:
		ctx.add_enemy_unit(Vector2(1500 + 20.0 * i, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)
	ctx.add_squad("s2", 1)
	ctx.add_squad("s3", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "应切 ATTACK")
	var board: Variant = ctx.ai.get_task_board()
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_ATTACK), 2, "期望进攻槽数 = ceil(0.6×3) = 2")
	_runner.assert_equal(board.slot_count(ScriptTaskBoard.KIND_DEFEND), 1, "防守槽 = 余量 1")
	var slot_of := {}
	for sid in ["s1", "s2", "s3"]:
		slot_of[sid] = board.slot_of_squad(sid)
	_runner.assert_true(String(slot_of["s1"]).begins_with("atk"), "s1 绑攻击槽")
	_runner.assert_true(String(slot_of["s2"]).begins_with("atk"), "s2 绑攻击槽")
	_runner.assert_true(String(slot_of["s3"]).begins_with("def"), "s3 绑防守槽")
	# 号令目标：攻击槽绑定 → 槽目标（敌位），防守 → 本方质心
	var target_of := {}
	for c in ctx.orders.calls:
		target_of[c["squad_id"]] = c["target"]
	_runner.assert_true(target_of.has("s1") and target_of.has("s2") and target_of.has("s3"), "三小队均收号令")
	if target_of.has("s1") and target_of.has("s3"):
		_runner.assert_true(target_of["s1"] != target_of["s3"], "攻击目标 ≠ 防守位")
		_runner.assert_approx(target_of["s3"].x, 530.0, 1.0, "防守位 = 本方质心")
		# 槽目标 = 评分最优敌位（敌群在 1500+，远离本方质心）
		_runner.assert_true(target_of["s1"].x > 1000.0, "攻击目标在敌方向")
	ctx.teardown()


# ─────────────────────────────── 夹具 ────────────────────────────────

## 力量占优局面（3 矛 vs 1 矛 → ratio=3.0 ≥ attack_enter 1.30）
func _add_ratio3_setup(ctx: _Ctx) -> void:
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)


## 参数齐全的任务槽板（TeamAiProfiles 代码默认档案，脱离 BalanceConfig 单测内核；
## RefCounted 无需 teardown）
func _make_board() -> ScriptTaskBoard:
	var board: ScriptTaskBoard = ScriptTaskBoard.new()
	board.setup(ScriptTeamAiProfiles.get_profile({}))
	return board


func _make_ctx(overrides: Dictionary) -> _Ctx:
	var ctx := _Ctx.new()
	ctx.setup(overrides)
	return ctx


## 带组织根映射的上下文（FakeOrdersOrg 代理 get_org_root_for_squad）
func _make_org_ctx(org_roots: Dictionary) -> _Ctx:
	var ctx := _Ctx.new()
	ctx.setup_org(org_roots)
	return ctx


class _Ctx:
	var battle: _FakeBattle
	var orders: Node
	var formation: _FakeFormation
	var ai: TeamAi

	func setup(overrides: Dictionary = {}) -> void:
		battle = _FakeBattle.new()
		orders = _FakeOrders.new()
		formation = _FakeFormation.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, orders, formation, overrides)

	func setup_org(org_roots: Dictionary) -> void:
		battle = _FakeBattle.new()
		orders = _FakeOrdersOrg.new(org_roots)
		formation = _FakeFormation.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, orders, formation, {})

	func teardown() -> void:
		if ai != null:
			ai.dispose()
		if battle != null:
			battle.queue_free()
		if orders != null:
			orders.queue_free()
		if formation != null:
			formation.queue_free()

	func add_own_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 1, wtype)

	func add_enemy_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 2, wtype)

	func kill_own_units(n: int) -> void:
		battle.kill_units(1, n)

	func add_squad(squad_id: String, faction: int, is_combat: bool = true, unit_count: int = 3) -> void:
		formation.add_squad(squad_id, faction, is_combat, unit_count)


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

	func kill_units(faction: int, n: int) -> void:
		var killed: int = 0
		for u in _units:
			if u.faction == faction and not u.dead:
				u.dead = true
				killed += 1
				if killed >= n:
					break

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


## 散兵号令桩（仅 issue——退化/散兵路径；无 get_org_root_for_squad = 散兵口径）
class _FakeOrders extends Node:
	var calls: Array = []

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


## 编制+散兵混合号令桩（A2 下令路径分流消费：get_org_root_for_squad 代理 +
## issue_to_org 记录；org_calls 专门记录组织路径）
class _FakeOrdersOrg extends Node:
	var calls: Array = []
	var org_calls: Array = []
	var _org_roots: Dictionary = {}

	func _init(org_roots: Dictionary = {}) -> void:
		_org_roots = org_roots

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
		return str(_org_roots.get(squad_id, ""))


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
		_squads[squad_id] = {
			"faction": faction,
			"is_combat": is_combat,
			"units": units,
		}

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
