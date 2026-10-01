extends Node
## 权重衔接探针（GDScript 侧，v2 定稿维度）：
## 装 checkpoint（125→64→40 平铺权重）→ gdscript_mirror/mirror_net.gd 独立前向
## 出 logits → net_probe_out.json。C++ 侧 test_core.exe gen-net-probe 产出
## checkpoint 与确定性观察输入（门第 1 步）、verify-net 比对两侧 logits（第 3 步）。
##
## 运行：godot --headless --path . res://addons/rl_core/tests/policy_net_probe.tscn --
##       --ckpt=<绝对路径> --input=<绝对路径>

const MirrorNet: GDScript = preload("res://addons/rl_core/tests/gdscript_mirror/mirror_net.gd")
const OUT := "res://temp/rl_core_mirror/net_probe_out.json"


func _ready() -> void:
	var ckpt_path := ""
	var input_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ckpt="):
			ckpt_path = a.substr(7)
		elif a.begins_with("--input="):
			input_path = a.substr(8)
	if ckpt_path.is_empty() or input_path.is_empty():
		push_error("[net_probe] 需要 --ckpt=<绝对路径> --input=<绝对路径>")
		get_tree().quit(1)
		return
	# checkpoint（v2 定稿契约：net 平铺权重 125→64→40）
	var f := FileAccess.open(ckpt_path, FileAccess.READ)
	if f == null:
		push_error("[net_probe] checkpoint 打不开: " + ckpt_path)
		get_tree().quit(1)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary) or not data.has("net"):
		push_error("[net_probe] checkpoint 无 net 字段")
		get_tree().quit(1)
		return
	var net = MirrorNet.new()
	if not net.from_json(data["net"]):
		push_error("[net_probe] from_json 维度/形状不符")
		get_tree().quit(1)
		return
	# 观察输入（C++ gen-net-probe 产出的确定性 sin 组）
	var fi := FileAccess.open(input_path, FileAccess.READ)
	if fi == null:
		push_error("[net_probe] input 打不开: " + input_path)
		get_tree().quit(1)
		return
	var input_data: Dictionary = JSON.parse_string(fi.get_as_text())
	fi.close()
	var probes: Array = []
	for p_v in input_data["probes"]:
		var x: Array = p_v["obs"]
		var logits: Array = net.forward(x)
		probes.append({"obs": x, "logits": logits})
	var out := {
		"iteration": int(data.get("iteration", -1)),
		"net": data["net"],
		"probes": probes,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var of := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if of == null:
		push_error("[net_probe] 写出失败")
		get_tree().quit(1)
		return
	of.store_string(JSON.stringify(out))
	of.close()
	print("[net_probe] 写出 %s（probes=%d，%d→%d→%d）" % [OUT, probes.size(), net.input_dim, net.hidden_dim, net.out_dim])
	get_tree().quit(0)
