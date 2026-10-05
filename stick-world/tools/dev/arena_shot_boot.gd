extends SceneTree
## 观察场快照 boot（工位跑批入口）——参数化复刻 diag_arena_shots 模式。
## 用法（bash 经 tools/dev/arena_shot.sh 包装，也可直跑）：
##   godot --path stick-world --headless --script res://tools/dev/arena_shot_boot.gd -- --preset 1 --secs 20 --tag mytag
## 参数（--key value 形式，全部可选）：
##   --preset 0|1|2   观察场预设（0 遭遇16 / 1 标准48 / 2 大军96），默认 1
##   --secs N         总时长（秒，默认 20）；期间每 --every 秒截一屏
##   --every N        截图间隔（秒，默认 5）
##   --tag NAME       产物文件名前缀（默认 workbench）
## 产物：user://shots/<tag>_<preset>_t<秒>.png，逐张 print 路径；跑完 exit 0。
## 注意：headless 下 viewport 截图走渲染服务器回读（项目既有 ROOT-1 探针同模式），
## 采到的是真实构图帧；若产物全黑先查 GPU 可用性再怀疑本脚本。

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const SHOT_DIR := "user://shots"


func _init() -> void:
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
	_run(tag, preset, secs, every)


func _run(tag: String, preset: int, secs: int, every: int) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	# 预设写入 arena 脚本 static（场景 _start 读 PRESETS[_preset_idx]）
	var arena_script: GDScript = load("res://tests/dev/battle_arena.gd")
	arena_script._preset_idx = preset
	change_scene_to_file(ARENA_SCENE)
	var shot_at := 0
	for t in range(0, secs + 1, maxi(every, 1)):
		await _sim_seconds(maxf(t - _elapsed(), 0.0))
		shot_at = t
		await process_frame   # 让当帧渲染完成再采
		_shot("%s_p%d_t%d" % [tag, preset, shot_at])
	await _sim_seconds(maxf(secs - _elapsed(), 0.0))
	print("[ArenaWorkbench] done preset=%d secs=%d" % [preset, secs])
	quit(0)


var _t0 := 0.0


func _elapsed() -> float:
	if _t0 == 0.0:
		_t0 = Time.get_ticks_msec() / 1000.0
	return Time.get_ticks_msec() / 1000.0 - _t0


func _sim_seconds(s: float) -> void:
	if s <= 0.0:
		return
	# 观察场实拍走真实时间（_process 驱动，battle_arena 的规划器拍用 delta 累积）
	var target := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < target:
		await process_frame


func _shot(name: String) -> void:
	var img := get_root().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("[ArenaWorkbench] shot %s/%s.png" % [SHOT_DIR, name])
