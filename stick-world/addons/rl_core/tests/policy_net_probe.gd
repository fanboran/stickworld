extends Node
## 权重衔接探针（GDScript 侧）：装 user://rl/checkpoint.json（阿尔法 420/426 轮档）
## → policy_net.gd 原版 forward 出 logits → probe_out.json。
## C++ 侧 test_core.exe verify-net 装同一 checkpoint 对同 obs 比对 logits。
## policy_net.gd 零依赖（RefCounted 纯算子），-s 模式可跑。
##
## 运行：godot --headless --path . -s res://addons/rl_core/tests/policy_net_probe.gd -- --ckpt=<绝对路径>

const PolicyNetScript: GDScript = preload("res://tests/dev/rl/policy_net.gd")
const OUT := "res://temp/rl_core_mirror/net_probe_out.json"


func _ready() -> void:
	var ckpt_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ckpt="):
			ckpt_path = a.substr(7)
	if ckpt_path.is_empty():
		push_error("[net_probe] 需要 --ckpt=<绝对路径>")
		get_tree().quit(1)
		return
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
	var net = PolicyNetScript.new()
	if not net.from_dict(data["net"]):
		push_error("[net_probe] from_dict 维度不符")
		get_tree().quit(1)
		return
	# 确定性观察 8 组（sin 公式；值随 dump 传给 C++，不要求两侧 sin 逐位一致）
	var probes: Array = []
	for pi in 8:
		var x := PackedFloat32Array()
		x.resize(57)
		for j in 57:
			x[j] = sin(float(pi * 13 + j * 7) * 0.37) * 0.9
		var logits: PackedFloat32Array = net.forward(x)
		var obs_arr: Array = []
		var lg_arr: Array = []
		for j in 57:
			obs_arr.append(x[j])
		for k in 15:
			lg_arr.append(logits[k])
		probes.append({"obs": obs_arr, "logits": lg_arr})
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
	print("[net_probe] 写出 %s（iter=%s，probes=%d）" % [OUT, str(data.get("iteration", -1)), probes.size()])
	get_tree().quit(0)
