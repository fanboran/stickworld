extends Node
## C++ 长期训练 driver（rl_core · RLTrainer GDExtension 大颗粒接口消费端，v2 定稿）。
##
## 协议：装 user://rl/checkpoint_cpp.json（同维度档，只读续训起点；旧 57 维阿尔法
## 档装不进 125→64→40 网络 → load_checkpoint false = 从头训，属维度定稿预期内）
## → 课程学习 17→49→97 三阶段（iter<5000→17 / <15000→49 / 之后 97）
## → checkpoint/CSV 全部落 *_cpp 独立档（不覆写阿尔法资产）。分段 train(50) 便于打点。
##
## 运行：godot --headless --path . res://addons/rl_core/tests/train_driver.tscn -- --iters=100000

const CPP_CKPT := "user://rl/checkpoint_cpp.json"
const CPP_TRAIN_CSV := "user://rl/train_log_cpp.csv"
const CPP_EVAL_CSV := "user://rl/eval_log_cpp.csv"


func _ready() -> void:
	var total_iters := 100000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--iters="):
			total_iters = int(a.substr(8))
	var tr := RLTrainer.new()
	tr.setup(20260930, "")
	tr.set_paths(CPP_CKPT, CPP_TRAIN_CSV, CPP_EVAL_CSV)
	if tr.load_checkpoint():
		print("[train] 续训：从第 %d 轮起（baseline=%.4f）" % [tr.get_iteration(), tr.get_baseline()])
	else:
		print("[train] 无同维度档（或维度不符），从第 0 轮起从头训（课程 C1=17 档期）")
	var t0 := Time.get_ticks_msec()
	var seg := 50
	while tr.get_iteration() < total_iters:
		tr.train(seg)
		var m: Dictionary = tr.get_metrics()
		# 注：Godot String % 不支持 %g（遇之整串静默回退原样），梯度范数用 .3f
		var line := "[train] iter=%d mean_r=%.4f base=%.4f H=%.3f T=%.3f grad=%.3f wall=%.1fs" % [
			int(m["iterations"]), float(m["mean_r"]), float(m["baseline"]),
			float(m["entropy"]), float(m["temp"]), float(m["grad_norm"]), float(m["wall_s"])]
		if int(m["iterations"]) % 50 == 0:
			line += "  ← 评估点"
		print(line)
	print("[train] 完成 %d 轮，耗时 %.1fs（%.2f iter/s）" % [
		tr.get_iteration(), float(Time.get_ticks_msec() - t0) / 1000.0,
		float(tr.get_iteration()) / maxf(0.001, float(Time.get_ticks_msec() - t0) / 1000.0)])
	tr.save_checkpoint()
	print("[train] checkpoint 已存 %s（iter=%d）" % [CPP_CKPT, tr.get_iteration()])
	get_tree().quit(0)
