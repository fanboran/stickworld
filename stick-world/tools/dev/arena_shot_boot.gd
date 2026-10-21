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
const RENDERPERF_DRIVER := preload("res://tools/dev/arena_renderperf.gd")
const PROBE_DRIVER := preload("res://tools/dev/arena_shadowprobe.gd")
const TWITCH_DRIVER := preload("res://tools/dev/arena_twitchprobe.gd")
const ANIMPROBE_DRIVER := preload("res://tools/dev/arena_animprobe.gd")
const P2PROBE_DRIVER := preload("res://tools/dev/arena_p2probe.gd")
const P4PROBE_DRIVER := preload("res://tools/dev/arena_p4probe.gd")
const SLOTPROBE_DRIVER := preload("res://tools/dev/arena_slotprobe.gd")
const FACINGPROBE_DRIVER := preload("res://tools/dev/arena_facingprobe.gd")
const OVERLAPPROBE_DRIVER := preload("res://tools/dev/arena_overlapprobe.gd")
const FLICKERPROBE_DRIVER := preload("res://tools/dev/arena_flickerprobe.gd")
const BURSTCAPTURE_DRIVER := preload("res://tools/dev/arena_burstcapture.gd")
const AIVIZ_DRIVER := preload("res://tools/dev/arena_aiviz_shot.gd")

var _preset := 1
var _secs := 20
var _every := 5.0   # 截图间隔秒（支持亚秒：0.2 = 5fps 连续帧，GIF 装配用）
var _tag := "workbench"
var _metrics := false
var _renderperf := false
var _probe := false
var _twitch := false
var _animprobe := false
var _p2probe := false
var _p4probe := false
var _slotprobe := false
var _facingprobe := false
var _overlapprobe := false
var _flickerprobe := false
var _burstcapture := false
var _aiviz := false
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
				_every = float(args[i + 1]); i += 2
			"--tag":
				_tag = args[i + 1]; i += 2
			"--metrics":
				_metrics = true; i += 1
			"--renderperf":
				_renderperf = true; i += 1
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
			"--facingprobe":
				_facingprobe = true; i += 1
			"--overlapprobe":
				_overlapprobe = true; i += 1
			"--flickerprobe":
				_flickerprobe = true; i += 1
			"--burstcapture":
				_burstcapture = true; i += 1
			"--aiviz":
				_aiviz = true; i += 1
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
	var script: GDScript = DRIVER_SCRIPT
	var driver_name := "ArenaShotDriver"
	if _burstcapture:
		script = BURSTCAPTURE_DRIVER; driver_name = "ArenaBurstCaptureDriver"
	elif _aiviz:
		script = AIVIZ_DRIVER; driver_name = "ArenaAiVizDriver"
	elif _flickerprobe:
		script = FLICKERPROBE_DRIVER; driver_name = "ArenaFlickerProbeDriver"
	elif _overlapprobe:
		script = OVERLAPPROBE_DRIVER; driver_name = "ArenaOverlapProbeDriver"
	elif _facingprobe:
		script = FACINGPROBE_DRIVER; driver_name = "ArenaFacingProbeDriver"
	elif _slotprobe:
		script = SLOTPROBE_DRIVER; driver_name = "ArenaSlotProbeDriver"
	elif _p4probe:
		script = P4PROBE_DRIVER; driver_name = "ArenaP4Driver"
	elif _p2probe:
		script = P2PROBE_DRIVER; driver_name = "ArenaP2Driver"
	elif _renderperf:
		script = RENDERPERF_DRIVER; driver_name = "ArenaRenderPerfDriver"
	elif _twitch:
		script = TWITCH_DRIVER; driver_name = "ArenaTwitchDriver"
	elif _probe:
		script = PROBE_DRIVER; driver_name = "ArenaProbeDriver"
	elif _animprobe:
		script = ANIMPROBE_DRIVER; driver_name = "ArenaAnimProbeDriver"
	elif _metrics:
		script = METRICS_DRIVER; driver_name = "ArenaMetricsDriver"
	driver.set_script(script)
	driver.name = driver_name
	get_tree().root.add_child(driver)
	driver.call("run", _tag, _preset, _secs, _every)
	get_tree().change_scene_to_file("res://tests/dev/battle_arena.tscn")
