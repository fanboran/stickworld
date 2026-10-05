extends SceneTree
## RNG 状态级探针：dump PCG state 序列，反推步进公式与输出函数输入选择
const OUT := "res://temp/rl_core_mirror/rng_probe2.json"

func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var out := {
		"state_after_seed": rng.state,
		"u32": [], "states": [], "randf": [],
	}
	for i in 4:
		out["u32"].append(rng.randi())
		out["states"].append(rng.state)
	rng.seed = 12345
	for i in 4:
		out["randf"].append(rng.randf())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("[rng_probe2] done")
	quit(0)
