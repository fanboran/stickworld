extends Node
## 战斗性能基准（dev 层）——带渲染跑 96v96 大乱斗，采样 FPS/最差帧。
##
## 复用 battle_arena 的完整装配（GameRoot + battlefield + 编队推进互殴），
## 只是把观察场换成采样器：热身 8s（含刷兵级联），采样 20s，输出 JSON 后退出。
## 用法（不要 --headless，需要真渲染）：
##   godot --path . res://tests/dev/battle_perf.tscn --resolution 1920x1080
## headless 模拟速率（无渲染噪声）：
##   godot --headless --path . res://tests/dev/battle_perf.tscn -- --headless-measure
## 对比基线：git worktree 检出改动前提交跑同命令。

const ArenaScene := preload("res://tests/dev/battle_arena.tscn")
const ArenaScript := preload("res://tests/dev/battle_arena.gd")

## 采样窗口（s）；之前的为热身
const MEASURE_SECONDS: float = 20.0
const WARMUP_SECONDS: float = 8.0

var _elapsed: float = 0.0
var _samples: Array[float] = []
var _max_frame_ms: float = 0.0
var _done: bool = false
## 实验开关（诊断瓶颈用；正常跑不带参数）：
##   --anim-off   开战 5s 后冻结全部 AnimationTree（动画处理成本归零，渲染仍在）
##   --rig-hidden 开战 5s 后隐藏全部骨架（渲染+动画归零，仅剩模拟）
##   --bodies-ghost 开战 5s 后单位碰撞 mask 只留地形（单位间物理互撞归零）
##   --no-ai      开战 5s 后禁用全部 AIController 物理处理（单位站桩）
##   --freeze-entities 实体及其全部子孙的物理处理停跑（战斗侧系统照常 tick）
##   --headless-measure 配合 --headless：不采样 FPS，改测物理 tick 速率
##                  （模拟侧独占开销，满速=tps 设置值）
var _anim_off: bool = false
var _rig_hidden: bool = false
var _bodies_ghost: bool = false
var _no_ai: bool = false
var _freeze_entities: bool = false
var _headless_measure: bool = false
var _applied: bool = false
var _measure_start_ticks: int = 0
var _measure_start_msec: int = 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		match str(a):
			"--anim-off":
				_anim_off = true
			"--rig-hidden":
				_rig_hidden = true
			"--bodies-ghost":
				_bodies_ghost = true
			"--no-ai":
				_no_ai = true
			"--freeze-entities":
				_freeze_entities = true
			"--headless-measure":
				_headless_measure = true
	# 大军压境·96 预设（static 跨实例生效，重开保持同档）
	ArenaScript._preset_idx = 2
	var arena: Node = ArenaScene.instantiate()
	add_child(arena)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	# 开战 5s 后注入实验（此前刷兵级联刚结束、战斗进入混战稳态）
	if not _applied and _elapsed > 5.0:
		_applied = true
		if _anim_off or _rig_hidden or _bodies_ghost or _no_ai or _freeze_entities:
			_apply_experiment()
	# headless 模式：测物理 tick 速率（模拟侧独占开销，满速=tps 设置值）
	if _headless_measure:
		_headless_tick()
		return
	_max_frame_ms = maxf(_max_frame_ms, delta * 1000.0)
	if _elapsed > WARMUP_SECONDS:
		_samples.append(float(Engine.get_frames_per_second()))
	if _elapsed < WARMUP_SECONDS + MEASURE_SECONDS:
		return
	_done = true
	# 终态截图（视觉验证：战场天空多层背景/无水带/单位混战）
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://tests/dev/battle_perf_out.png")
	_report()
	get_tree().quit(0)


func _headless_tick() -> void:
	# 热身结束后开测：记录物理 tick 数与墙钟，采样 10s
	if _measure_start_ticks == 0 and _elapsed > WARMUP_SECONDS:
		_measure_start_ticks = Engine.get_physics_frames()
		_measure_start_msec = Time.get_ticks_msec()
		return
	if _measure_start_ticks > 0 and Time.get_ticks_msec() - _measure_start_msec >= 10000:
		_done = true
		var dt: float = (Time.get_ticks_msec() - _measure_start_msec) / 1000.0
		var tps: float = (Engine.get_physics_frames() - _measure_start_ticks) / dt
		var target_tps: float = float(Engine.get_physics_ticks_per_second())
		print("[PERF] %s" % str({
			"mode": "headless-ticks/sec",
			"ticks_per_sec": snappedf(tps, 0.1),
			"target": target_tps,
			"speed_ratio": snappedf(tps / target_tps, 0.01),
		}))
		get_tree().quit(0)


func _apply_experiment() -> void:
	if _bodies_ghost:
		var count: int = 0
		for host in _find_entity_hosts(get_tree().root):
			for e in host.get_children():
				if e is CharacterBody2D and is_instance_valid(e):
					e.collision_mask = 1
					count += 1
		print("[PERF-EXPERIMENT] bodies-ghost units=%d" % count)
		return
	if _freeze_entities:
		# 实体及其全部子孙的物理处理停跑（AI/移动/武器/状态全不跑）；
		# 战斗实例/编队/导演等战斗侧系统照常 tick
		var count: int = 0
		for host in _find_entity_hosts(get_tree().root):
			for e in host.get_children():
				if e != null and is_instance_valid(e):
					e.set_physics_process(false)
					count += 1
					for d in _all_descendants(e, []):
						d.set_physics_process(false)
		print("[PERF-EXPERIMENT] freeze-entities units=%d" % count)
		return
	if _no_ai:
		var count: int = 0
		for host in _find_entity_hosts(get_tree().root):
			for e in host.get_children():
				var ai: Node = e.get_node_or_null("AIController") if e != null else null
				if ai != null:
					ai.set_physics_process(false)
					count += 1
		print("[PERF-EXPERIMENT] no-ai units=%d" % count)
		return
	var rigs: Array = []
	_collect_rigs(get_tree().root, rigs)
	for r in rigs:
		if not is_instance_valid(r):
			continue
		if _rig_hidden:
			r.visible = false
		elif _anim_off:
			var at: Node = r.get_node_or_null("OutlineGroup/StickmanRig/AnimationTree")
			if at != null:
				at.active = false
			var ap: Node = r.get_node_or_null("OutlineGroup/StickmanRig/AnimationPlayer")
			if ap != null:
				ap.paused = true
	print("[PERF-EXPERIMENT] rigs=%d mode=%s" % [rigs.size(), "hidden" if _rig_hidden else "anim-off"])


func _find_entity_hosts(node: Node, out: Array = []) -> Array:
	if node.name == "EntityHost":
		out.append(node)
		return out
	for c in node.get_children():
		_find_entity_hosts(c, out)
	return out


func _all_descendants(node: Node, out: Array) -> Array:
	for c in node.get_children():
		out.append(c)
		_all_descendants(c, out)
	return out


func _collect_rigs(node: Node, out: Array) -> void:
	if node.name == "RigHost":
		out.append(node)
		return
	for c in node.get_children():
		_collect_rigs(c, out)


func _report() -> void:
	# 统计：均值 / 中位 / 低 5% / 最差帧
	var sorted: Array[float] = _samples.duplicate()
	sorted.sort()
	var avg: float = 0.0
	for s in _samples:
		avg += s
	avg /= maxf(1.0, float(_samples.size()))
	var median: float = sorted[sorted.size() / 2]
	var p05: float = sorted[maxi(0, int(sorted.size() * 0.05))]
	print("[PERF] %s" % str({
		"preset": "大军压境·96(96v96)",
		"samples": _samples.size(),
		"fps_avg": snappedf(avg, 0.1),
		"fps_median": median,
		"fps_p05": p05,
		"worst_frame_ms": snappedf(_max_frame_ms, 0.1),
	}))
