extends SceneTree
## rl_core · GDExtension 集成冒烟（验证 .gdextension 真加载 + 大颗粒 API 通路）
##
## 运行（项目根 = stick-world/，需先 scons 出 bin/*.dll）：
##   Godot --headless --path . -s res://addons/rl_core/tests/integration_smoke.gd
##
## 检查项：三类注册可用 / 前向维度 / 采样 / 环境 step / 训练 5 轮 /
## checkpoint 往返 / 加载后前向逐位一致。退出码 0 = 全过。

const CKPT_PATH := "res://temp/rl_core_mirror/integration_ckpt.json"

var _fails := 0


func check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _init() -> void:
	print("== rl_core 集成冒烟 ==")

	# 类型注册
	check(ClassDB.class_exists("RLPolicyNet"), "ClassDB 有 RLPolicyNet")
	check(ClassDB.class_exists("RLBattleEnv"), "ClassDB 有 RLBattleEnv")
	check(ClassDB.class_exists("RLTrainer"), "ClassDB 有 RLTrainer")

	# 网络
	var net := RLPolicyNet.new()
	net.setup(47, 24, 15, 12345)
	check(net.param_count() == 47 * 24 + 24 + 24 * 15 + 15, "参数量 = %d（Glorot 初始化完成）" % net.param_count())
	var obs := PackedFloat32Array()
	obs.resize(47)
	for i in 47:
		obs[i] = 0.1 * (i % 7) - 0.3
	var logits := net.forward(obs)
	check(logits.size() == 15, "前向出 15 logits")
	var sampled: Array = net.sample_actions(logits)
	check(sampled.size() == 4 and int(sampled[0]) >= 0 and int(sampled[2]) <= 4, "采样出 3 意图 + logπ")

	# 环境
	var env := RLBattleEnv.new()
	env.load_config("")
	env.reset(777)
	var comp_a: Dictionary = env.get_comp_attacker()
	var comp_d: Dictionary = env.get_comp_defender()
	check(int(comp_a["spear"]) + int(comp_a["sword"]) + int(comp_a["staff"]) + int(comp_a["bow"]) >= 10,
			"攻方编制抽样合法（%s）" % str(comp_a))
	var obs_a := env.observe(0)
	check(obs_a.size() == 47, "观察 47 维")
	var guard := 0
	while not env.is_done() and guard < 130:
		guard += 1
		var aa := PackedInt32Array([0, 1, 2])
		var ad := PackedInt32Array([4, 3, 4])
		env.step(aa, ad)
	var res: Dictionary = env.get_result()
	check(int(res["decisions"]) > 0 and int(res["winner"]) in [0, 1, 2],
			"环境跑完整局（decisions=%d winner=%s）" % [int(res["decisions"]), str(res["winner"])])
	check(absf(float(res["reward_attacker"]) + float(res["reward_defender"])) < 1e-9, "奖励零和")

	# 训练 + checkpoint 往返
	var tr := RLTrainer.new()
	tr.setup(42, "")
	tr.train(5)
	var m: Dictionary = tr.get_metrics()
	check(int(m["episodes"]) == 10, "训练 5 轮 = 10 局（正反局）")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	check(tr.save_checkpoint(ProjectSettings.globalize_path(CKPT_PATH)), "checkpoint 落盘")
	var tr2 := RLTrainer.new()
	tr2.setup(999, "")
	check(tr2.load_checkpoint(ProjectSettings.globalize_path(CKPT_PATH)), "checkpoint 读回")
	var m2: Dictionary = tr2.get_metrics()
	check(int(m2["iterations"]) == 5, "读回迭代数一致")
	var net2 := tr2.get_net()
	var l1 := tr.get_net().forward(obs)
	var l2 := net2.forward(obs)
	var same := true
	for i in l1.size():
		if l1[i] != l2[i]:
			same = false
	check(same, "往返后前向逐位一致")
	tr2.train(2)
	check(int(tr2.get_metrics()["episodes"]) > 10, "恢复后继续训练")

	print("集成冒烟 %s（fails=%d）" % ["ALL PASS" if _fails == 0 else "HAS FAILURES", _fails])
	quit(0 if _fails == 0 else 1)
