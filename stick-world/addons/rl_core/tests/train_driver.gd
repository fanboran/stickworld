extends Node
## C++ 长期训练 driver（rl_core · RLTrainer GDExtension 大颗粒接口消费端）。
##
## 协议：装 user://rl/checkpoint.json（阿尔法 GDScript 版档，只读）→ 续训 →
## checkpoint/CSV 全部落 *_cpp 独立档（不覆写阿尔法资产；曲线格式与 GDScript 版
## 一致，评估对手 = 军师规划器打分逻辑的 C++ 镜像）。分段 train(50) 便于打点。
##
## 运行：godot --headless --path . res://addons/rl_core/tests/train_driver.tscn -- --iters=2500

const ALPHA_CKPT := "user://rl/checkpoint.json"
const CPP_CKPT := "user://rl/checkpoint_cpp.json"
const CPP_TRAIN_CSV := "user://rl/train_log_cpp.csv"
const CPP_EVAL_CSV := "user://rl/eval_log_cpp.csv"


func _ready() -> void:
	var total_iters := 2500
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--iters="):
			total_iters = int(a.substr(8))
	var tr := RLTrainer.new()
	tr.setup(20260930, "")
	# 装阿尔法档（只读续训起点）
	tr.set_paths(ALPHA_CKPT, CPP_TRAIN_CSV, CPP_EVAL_CSV)
	if tr.load_checkpoint():
		print("[train] 续训：从第 %d 轮起（阿尔法档 baseline=%.4f）" % [tr.get_iteration(), tr.get_baseline()])
	else:
		print("[train] 阿尔法档装载失败，从头训练")
	# 存档切到 C++ 独立档
	tr.set_paths(CPP_CKPT, CPP_TRAIN_CSV, CPP_EVAL_CSV)
	var t0 := Time.get_ticks_msec()
	var seg := 50
	var evals: Array = []
	while tr.get_iteration() < total_iters:
		var n: int = mini(seg, total_iters - tr.get_iteration())
		tr.train(n)
		var m: Dictionary = tr.get_metrics()
		var line := "[train] iter=%d mean_r=%.4f base=%.4f H=%.3f T=%.3f grad=%.3g wall=%.1fs" % [
			int(m["iterations"]), float(m["mean_r"]), float(m["baseline"]),
			float(m["entropy"]), float(m["temp"]), float(m["grad_norm"]), float(m["wall_s"])]
		if int(m["iterations"]) % 50 == 0:
			line += "  ← 评估点"
		print(line)
	print("[train] 完成 %d 轮，耗时 %.1fs（%.0f iter/s）" % [
		tr.get_iteration(), float(Time.get_ticks_msec() - t0) / 1000.0,
		float(tr.get_iteration()) / maxf(0.001, float(Time.get_ticks_msec() - t0) / 1000.0)])
	tr.save_checkpoint()
	print("[train] checkpoint 已存 %s（iter=%d）" % [CPP_CKPT, tr.get_iteration()])
	get_tree().quit(0)
