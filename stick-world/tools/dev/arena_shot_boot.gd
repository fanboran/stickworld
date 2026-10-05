extends Control
## 观察场快照 boot（工位跑批入口）——复刻 diag_arena_shots 的已验证 boot 模式：
## 解析参数 → 预设写入 arena static → 挂 driver 到 SceneTree.root（跨场景存活）
## → 切观察场场景 → 自身随场景释放退场。
## 由 tools/dev/arena_shot.sh 包装启动（必须带显示，headless 无 viewport 纹理）：
##   godot --path stick-world res://tools/dev/arena_shot_boot.tscn --resolution 1920x1080 -- --preset 1 --secs 20 --every 5 --tag mytag


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var preset := 1
	var secs := 20
	var every := 5
	var tag := "workbench"
	var i := 0
	while i < args.size():
		match args[i]:
			"--preset":
				preset = int(args[i + 1]); i += 2
			"--secs":
				secs = int(args[i + 1]); i += 2
			"--every":
				every = int(args[i + 1]); i += 2
			"--tag":
				tag = args[i + 1]; i += 2
			_:
				i += 1
	# 预设写入 arena 脚本 static（battle_arena._start 读 PRESETS[_preset_idx]）
	var arena_script: GDScript = load("res://tests/dev/battle_arena.gd")
	arena_script._preset_idx = preset
	var driver := Node.new()
	driver.set_script(preload("res://tools/dev/arena_shot_driver.gd"))
	driver.name = "ArenaShotDriver"
	get_tree().root.add_child(driver)
	driver.call("run", tag, preset, secs, every)
	get_tree().change_scene_to_file("res://tests/dev/battle_arena.tscn")
