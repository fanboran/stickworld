extends SceneTree
const OUT := "res://temp/rl_core_mirror/rng_probe3.json"
func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var s0: int = rng.state
	var v: float = rng.randf()
	var s1: int = rng.state
	var v2: int = rng.randi()
	var s2: int = rng.state
	var v3: float = rng.randf()
	var s3: int = rng.state
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"s0": s0, "s1": s1, "s2": s2, "s3": s3,
		"randf0": v, "randi1": v2, "randf2": v3,
	}))
	f.close()
	print("[rng_probe3] done randf0=", v)
	quit(0)
