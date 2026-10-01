extends Node
## rl_core · GDExtension 集成冒烟 v2 定稿（验证 .gdextension 真加载 + v2 大颗粒 API 通路）
##
## 运行（项目根 = stick-world/，需先 scons 出 bin/*.dll）：
##   godot --headless --path . res://addons/rl_core/tests/integration_smoke.tscn
##
## 检查项：三类注册 / 125 维前向 / 温度采样（8 班）/ 环境完整局（斩首字段）/
## 军师镜像对手 / 训练指标 / 奖励零和。退出码 0 = 全过。

var _fails := 0


func check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _ready() -> void:
	print("== rl_core 集成冒烟 v2 定稿 ==")

	check(ClassDB.class_exists("RLPolicyNet"), "ClassDB 有 RLPolicyNet")
	check(ClassDB.class_exists("RLBattleEnv"), "ClassDB 有 RLBattleEnv")
	check(ClassDB.class_exists("RLTrainer"), "ClassDB 有 RLTrainer")

	# 网络（125→64→40 定稿规格）
	var net := RLPolicyNet.new()
	net.setup(125, 64, 40, 12345)
	check(net.param_count() == 125 * 64 + 64 + 40 * 64 + 40, "参数量 = %d（Glorot 初始化完成）" % net.param_count())
	var obs := PackedFloat32Array()
	obs.resize(125)
	for i in 125:
		obs[i] = 0.1 * (i % 7) - 0.3
	var logits := net.forward(obs)
	check(logits.size() == 40, "前向出 40 logits（8 班 × 5 意图）")
	var mask := PackedInt32Array([1, 1, 1, 0, 1, 1, 0, 1])
	var sampled: Array = net.sample_actions(logits, 1.1, mask)
	check(sampled.size() == 11 and int(sampled[0]) >= 0 and int(sampled[2]) <= 4,
			"温度采样出 8 意图 + logπ/熵/有效班数")
	var greedy: PackedInt32Array = net.greedy_actions(logits, mask)
	check(greedy.size() == 8, "greedy 出 8 班意图")

	# 环境
	var env := RLBattleEnv.new()
	env.load_config("")
	var matchup: Dictionary = env.gen_matchup(777)
	check(matchup.has("total") and int(matchup["total"]) in [17, 49, 97],
			"对阵抽样（真镜像单套编制）: total=%d tier=%d 排=%d" % [int(matchup["total"]), int(matchup["tier"]), int(matchup["n_platoons"])])
	env.reset(777, false)
	var obs_a := env.observe(1)
	check(obs_a.size() == 125, "观察 125 维（定稿布局）")
	var mask_a: PackedInt32Array = env.active_mask(1)
	check(mask_a.size() == 8, "active_mask 8 班（空班 0）")
	var planner: PackedInt32Array = env.planner_intents(1)
	check(planner.size() == 8, "军师镜像对手出 8 班意图")
	var guard := 0
	var acts := PackedInt32Array([0, 1, 2, 3, 4, 0, 1, 2])
	while not env.is_done() and guard < 260:
		guard += 1
		var ad := env.planner_intents(2)
		env.step(acts, ad)
	var res: Dictionary = env.get_result()
	check(int(res["decisions"]) > 0 and int(res["winner"]) in [0, 1, 2],
			"环境跑完整局（decisions=%d winner=%s reason=%s）" % [int(res["decisions"]), str(res["winner"]), str(res["reason"])])
	check(res.has("reason") and int(res["reason"]) in [0, 1], "结算 reason 字段（0 正常 / 1 斩首）")
	check(absf(float(res["reward_f1"]) + float(res["reward_f2"])) < 1e-9, "奖励零和")

	# 训练通路（checkpoint 往返已在 train_driver 链路验收，此处验指标可读）
	var tr := RLTrainer.new()
	tr.setup(20260930, "")
	var m: Dictionary = tr.get_metrics()
	check(int(m["iterations"]) == 0, "trainer 初始化（iterations=0）")

	print("集成冒烟 v2 定稿 %s（fails=%d）" % ["ALL PASS" if _fails == 0 else "HAS FAILURES", _fails])
	get_tree().quit(0 if _fails == 0 else 1)
