extends Control
## 观察场快照 boot（工位跑批入口）——复刻 diag_arena_shots 的已验证 boot 模式：
## 参数解析与挂 driver 必须 call_deferred——_ready 期间 root 还在
## "busy setting up children"，直接 add_child 到 root 会失败，driver 没进树
## 则 get_tree() 为 null、协程当场死、无人调 quit → 进程挂死（实测教训）。
## 流程：解析参数 → 预设写入 arena static → 挂 driver 到 SceneTree.root
## （跨场景存活）→ 切观察场场景 → 自身随场景释放退场。
## 由 tools/dev/arena_shot.sh 包装启动（必须带显示，headless 无 viewport 纹理）：
##   godot --path stick-world res://tools/dev/arena_shot_boot.tscn --resolution 1920x1080 -- --preset 1 --secs 20 --every 5 --tag mytag

const DRIVER_SCRIPT := preload("res://tools/dev/arena_shot_driver.gd")
const METRICS_DRIVER := preload("res://tools/dev/arena_metrics.gd")
const PROBE_DRIVER := preload("res://tools/dev/arena_shadowprobe.gd")
const TWITCH_DRIVER := preload("res://tools/dev/arena_twitchprobe.gd")
const ANIMPROBE_DRIVER := preload("res://tools/dev/arena_animprobe.gd")
const P2PROBE_DRIVER := preload("res://tools/dev/arena_p2probe.gd")
const P4PROBE_DRIVER := preload("res://tools/dev/arena_p4probe.gd")
const SLOTPROBE_DRIVER := preload("res://tools/dev/arena_slotprobe.gd")

var _preset := 1
var _secs := 20
var _every := 5
var _tag := "workbench"
var _metrics := false
var _probe := false
var _twitch := false
var _animprobe := false
var _p2probe := false
var _p4probe := false
var _slotprobe := false
var _lineup := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--preset":
				_preset = int(args[i + 1]); i += 2
			"--secs":
				_secs = int(args[i + 1]); i += 2
			"--every":
				_every = int(args[i + 1]); i += 2
			"--tag":
				_tag = args[i + 1]; i += 2
			"--metrics":
				_metrics = true; i += 1
			"--probe":
				_probe = true; i += 1
			"--twitch":
				_twitch = true; i += 1
			"--animprobe":
				_animprobe = true; i += 1
			"--watch":
				# animprobe 盯单覆盖（逗号分隔动画名）：--watch attack_bow_reload,attack_bow_hold
				ANIMPROBE_DRIVER.WATCH_OVERRIDE = args[i + 1].split(",")
				_animprobe = true; i += 2
			"--p2probe":
				_p2probe = true; i += 1
			"--p4probe":
				_p4probe = true; i += 1
			"--slotprobe":
				_slotprobe = true; i += 1
			"--lineup":
				_lineup = true; i += 1
			_:
				i += 1
	call_deferred("_start")


func _start() -> void:
	# 预设写入 arena 脚本 static（battle_arena._start 读 PRESETS[_preset_idx]）
	var arena_script: GDScript = load("res://tests/dev/battle_arena.gd")
	arena_script._preset_idx = _preset
	arena_script.lineup_mode = _lineup
	var driver := Node.new()
	var script: GDScript = SLOTPROBE_DRIVER if _slotprobe else (P4PROBE_DRIVER if _p4probe else (P2PROBE_DRIVER if _p2probe else (TWITCH_DRIVER if _twitch else (PROBE_DRIVER if _probe else (ANIMPROBE_DRIVER if _animprobe else (METRICS_DRIVER if _metrics else DRIVER_SCRIPT))))))
	driver.set_script(script)
	driver.name = "ArenaSlotProbeDriver" if _slotprobe else ("ArenaP4Driver" if _p4probe else ("ArenaP2Driver" if _p2probe else ("ArenaTwitchDriver" if _twitch else ("ArenaProbeDriver" if _probe else ("ArenaAnimProbeDriver" if _animprobe else ("ArenaMetricsDriver" if _metrics else "ArenaShotDriver"))))))
	get_tree().root.add_child(driver)
	driver.call("run", _tag, _preset, _secs, _every)
	get_tree().change_scene_to_file("res://tests/dev/battle_arena.tscn")
