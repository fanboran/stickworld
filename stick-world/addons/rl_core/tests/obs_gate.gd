extends Node
## 观察对拍门（GDScript 侧，v2 定稿 125 维）——状态注入式对拍。
##
## 原理：fixture（C++ dump_obs_fixture v3 产物）是紧凑环境跑出的**状态帧序列**
## （单位位置/血比/旗归属进度/上拍意图 + rank/is_commander/squad_initial/
## platoons 分组）。本脚本把每帧状态喂给 gdscript_mirror/mirror_encoder.gd
## （新维度的独立 GDScript 实现）重算 125 维观察 → obs_gate_out.json。
## C++ 侧 test_core.exe verify-obs 帧对帧比对（fixture 内含 C++ 同状态编码）。
##
## 旧版（57 维）走"注入阿尔法原版 battle_env 调它自己的 _encode_obs"——
## 阿尔法设施是 3 班旧维度且只读，v2 定稿维度改走本镜像编码器。
##
## 运行：godot --headless --path . -s res://addons/rl_core/tests/obs_gate.gd -- --fixture=<绝对路径>

const MirrorEncoder: GDScript = preload("res://addons/rl_core/tests/gdscript_mirror/mirror_encoder.gd")
const OUT := "res://temp/rl_core_mirror/obs_gate_out.json"


func _ready() -> void:
	var fixture_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fixture="):
			fixture_path = a.substr(10)
	if fixture_path.is_empty():
		push_error("[obs_gate] 需要 --fixture=<绝对路径>")
		get_tree().quit(1)
		return
	var f := FileAccess.open(fixture_path, FileAccess.READ)
	if f == null:
		push_error("[obs_gate] fixture 打不开: " + fixture_path)
		get_tree().quit(1)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary) or not data.has("frames"):
		push_error("[obs_gate] fixture 解析失败")
		get_tree().quit(1)
		return
	if data.get("format", "") != "rl_core.obs_fixture.v3":
		push_error("[obs_gate] fixture 格式不是 v3（当前维度契约）: " + str(data.get("format")))
		get_tree().quit(1)
		return

	var out_frames: Array = []
	for fr_v in data["frames"]:
		var fr: Dictionary = fr_v
		out_frames.append({
			"obs_f1": MirrorEncoder.encode(data, fr, 1),
			"obs_f2": MirrorEncoder.encode(data, fr, 2),
		})

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var of := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if of == null:
		push_error("[obs_gate] 写出失败")
		get_tree().quit(1)
		return
	of.store_string(JSON.stringify({"frames": out_frames, "count": out_frames.size()}))
	of.close()
	print("[obs_gate] 写出 %s（frames=%d，obs_dim=%d）" % [OUT, out_frames.size(), MirrorEncoder.OBS_DIM])
	get_tree().quit(0)
