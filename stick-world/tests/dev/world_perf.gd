extends Node
## 世界场景性能基准（dev 层）——绕过主菜单直接加载 game_root（新档语义），
## 量测世界/村庄场景的帧率与 proc/phys/draws 基线（不含主菜单/音频噪声）。
##
## 用法（真渲染；建议 --audio-driver Dummy 关声音降噪）：
##   godot --path . --resolution 1920x1080 res://tests/dev/world_perf.tscn
## 流程：boot_load_slot=-1（新开局，不碰玩家存档）→ 加载 game_root →
## 热身 10s（世界生成/刷单位）→ 采样 20s → 输出 [PERF] JSON 后退出。
## 量测规范（通道隔离/关声音/基线表）见 docs/技术/教程/性能量测规范.md。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const WARMUP_SECONDS: float = 10.0
const MEASURE_SECONDS: float = 20.0

var _world_elapsed: float = 0.0
var _world_loaded: bool = false
var _measuring: bool = false
var _samples: PackedFloat32Array = PackedFloat32Array()
var _proc_ms: PackedFloat32Array = PackedFloat32Array()
var _phys_ms: PackedFloat32Array = PackedFloat32Array()
var _max_frame_ms: float = 0.0


func _ready() -> void:
	# 新开局语义（不读玩家存档；SaveManager 在 game_root._ready 消费此字段）。
	# 注意：不能 change_scene_to_file——那会把本采样节点（当前场景）替换掉；
	# 改为把 world 挂到 root 下作兄弟节点，本节点常驻采样。
	SaveManager.boot_load_slot = -1
	var world: Node = (load(GAME_ROOT_SCENE) as PackedScene).instantiate()
	world.name = "GameRootPerf"
	get_tree().root.add_child.call_deferred(world)


func _process(_delta: float) -> void:
	if not _world_loaded:
		var world := get_tree().root.get_node_or_null("GameRootPerf")
		if world != null and world.get_child_count() > 0:
			_world_loaded = true
			_world_elapsed = 0.0
		return
	_world_elapsed += _delta
	if _world_elapsed < WARMUP_SECONDS:
		return
	if not _measuring:
		_measuring = true
		_world_elapsed = 0.0
		print("[PERF] warmup done, measuring %ds" % int(MEASURE_SECONDS))
	_samples.append(_delta * 1000.0)
	_proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_max_frame_ms = maxf(_max_frame_ms, _delta * 1000.0)
	if _world_elapsed >= MEASURE_SECONDS:
		_report()
		get_tree().quit()


func _report() -> void:
	var n := _samples.size()
	if n == 0:
		print("[PERF] no samples")
		return
	var sorted := _samples.duplicate()
	sorted.sort()
	var avg_ms := 0.0
	for v in _samples:
		avg_ms += v
	avg_ms /= n
	var proc_avg := 0.0
	for v in _proc_ms:
		proc_avg += v
	proc_avg /= _proc_ms.size()
	var phys_avg := 0.0
	for v in _phys_ms:
		phys_avg += v
	phys_avg /= _phys_ms.size()
	print("[PERF] %s" % str({
		"scene": "world/game_root",
		"samples": n,
		"fps_avg": snappedf(1000.0 / avg_ms, 0.1),
		"frame_ms_avg": snappedf(avg_ms, 0.1),
		"frame_ms_median": snappedf(sorted[n / 2], 0.1),
		"frame_ms_p05": snappedf(sorted[maxi(0, int(n * 0.05))], 0.1),
		"worst_frame_ms": snappedf(_max_frame_ms, 0.1),
		"proc_ms_avg": snappedf(proc_avg, 0.1),
		"phys_ms_avg": snappedf(phys_avg, 0.1),
	}))
