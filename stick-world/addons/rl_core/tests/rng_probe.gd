extends SceneTree
## RNG 校准探针（GDScript 侧）：dump Godot RandomNumberGenerator 序列与内置 hash，
## 供 C++ RngPcg/hash_djb2 对拍校准。只读设施，不改 tests/dev/rl。

const OUT := "res://temp/rl_core_mirror/rng_probe.json"


func _init() -> void:
	var out := {
		"seed": 12345,
		"randf": [], "randi": [], "randf_range": [], "randi_range": [],
		"hash": {},
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in 8:
		out["randf"].append(rng.randf())
	rng.seed = 12345
	for i in 5:
		out["randi"].append(rng.randi())
	rng.seed = 12345
	for i in 4:
		out["randf_range"].append(rng.randf_range(-250.0, 250.0))
	rng.seed = 12345
	for i in 4:
		out["randi_range"].append(rng.randi_range(0, 2))
	out["hash"] = {
		"20260930|0": hash("20260930|0"),
		"20260930|1": hash("20260930|1"),
		"20260930|eval|50": hash("20260930|eval|50"),
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f == null:
		push_error("[rng_probe] 写出失败")
		quit(1)
		return
	f.store_string(JSON.stringify(out))
	f.close()
	print("[rng_probe] 写出: %s" % OUT)
	quit(0)
