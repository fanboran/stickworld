extends Node
## 单位实体日常开销无头基准（dev 层，性能优化专用）。
##
## 测什么：stickman_entity 的每物理帧群体开销 / 实例化尖峰 / rig 无头算术 / 移动管线。
## 怎么跑：
##   timeout 180 godot --headless --path . res://tests/dev/bench_units_main.tscn
## 输出：一行 JSON（[BENCH] 前缀）便于前后对比；末尾打印黄金哈希
## （同 seed 下 600 物理帧后全部单位位置/hp/朝向/z_index 摘要——
##  优化前后必须一致，作为行为零回归的黄金对照）。
##
## 装配套路照抄 tests/helpers/combat_test_setup.gd 的生产路径：
## 用 MapBase 派生桩地图 + map.spawn_entity()（注入地面约束与地图引用）。

const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const ScriptMapBase := preload("res://modules/world/scripts/map/map_base.gd")

## 固定种子：随机属性掷骰 / 走位方向全部确定（黄金哈希前提）
const RNG_SEED: int = 20260908
## 群体规模与推进帧数
const UNIT_COUNT: int = 200
const WARMUP_FRAMES: int = 60
const MEASURE_FRAMES: int = 600
## 实例化尖峰批次
const SPAWN_BURST_COUNT: int = 100
## 微基准迭代数
const MICRO_ITERS: int = 500
const PIPELINE_ITERS: int = 10000

var _units: Array = []
var _bench_map: Node2D = null
var _rng := RandomNumberGenerator.new()
## 走位注入状态：每单位一个方向 + 换向倒计时（帧）
var _dirs: PackedVector2Array = PackedVector2Array()
var _turn_counters: PackedInt32Array = PackedInt32Array()
var _frame_in_measure: int = 0
var _measure_msec: int = 0


## 桩地图：MapBase 派生，补一个 VillageMap 同名地形倍率（恒 1.0，数值与土路
## 默认一致 → has_method 路径真实而行为零差异）。
class BenchMap:
	extends ScriptMapBase
	func get_move_speed_mult_at_x(_world_x: float) -> float:
		return 1.0


func _ready() -> void:
	# 顺序：实例化尖峰（独立单位，测完即弃）→ 群体物理帧（黄金哈希）→ 分项微基准
	seed(RNG_SEED)
	_rng.seed = RNG_SEED
	# --diag-only：跳过全部正式阶段，spawn 后直接跑诊断分解（定位成本构成用）
	if "--diag-only" in OS.get_cmdline_user_args():
		_setup_map()
		await _spawn_group()
		await _diag_breakdown()
		get_tree().quit(0)
		return
	# 空载底噪：无任何单位时物理帧间隔（headless 主循环钳制基准）
	var t_idle := Time.get_ticks_msec()
	for f in 120:
		await get_tree().physics_frame
	_emit({"bench": "diag_idle_loop", "ms_per_frame": float(Time.get_ticks_msec() - t_idle) / 120.0})
	await _bench_spawn_burst()
	await _bench_group_physics()
	await _bench_micro()
	get_tree().quit(0)


# ─────────────────────────── 阶段 1：实例化尖峰 ───────────────────────────

## instantiate ×100（不进树）与 add_child+_ready ×100（进树）分开计时，
## 定位"开局/战斗刷新尖峰"里场景实例化与组件装配各占多少。
func _bench_spawn_burst() -> void:
	# 先热一次 load/preload 缓存（消除首次加载噪声）
	STICKMAN_SCENE.instantiate().free()
	var t0 := Time.get_ticks_usec()
	var instances: Array = []
	instances.resize(SPAWN_BURST_COUNT)
	for i in SPAWN_BURST_COUNT:
		instances[i] = STICKMAN_SCENE.instantiate()
	var t_inst := Time.get_ticks_usec() - t0
	# add_child 进树（触发 _ready 全套组件装配）
	var host := Node2D.new()
	host.name = "BurstHost"
	add_child(host)
	t0 = Time.get_ticks_usec()
	for i in SPAWN_BURST_COUNT:
		host.add_child(instances[i])
	var t_ready := Time.get_ticks_usec() - t0
	host.free()
	_emit({"bench": "spawn_burst", "count": SPAWN_BURST_COUNT,
			"instantiate_us_total": t_inst, "instantiate_us_per": float(t_inst) / SPAWN_BURST_COUNT,
			"add_child_ready_us_total": t_ready, "add_child_ready_us_per": float(t_ready) / SPAWN_BURST_COUNT})
	# 让 free 落地一帧，避免尸体影响下一阶段
	await get_tree().process_frame


# ─────────────────────────── 阶段 2：群体物理帧 ───────────────────────────

## 生成群体 + seeded 走位初始化 + 热身（正式测量与诊断分解共用）。
func _spawn_group() -> int:
	var spawn_y: float = _bench_map.ground_y + (_bench_map.ground_bottom - _bench_map.ground_y) * 0.5
	var t0 := Time.get_ticks_usec()
	for i in UNIT_COUNT:
		# 网格分布：40px 间距密集排布（强制分离查询有邻居可查，贴近混战密度）
		var x := 400.0 + float(i % 40) * 40.0
		var y := spawn_y + float(i / 40) * 12.0 - 24.0
		var e: Node2D = _bench_map.spawn_entity(STICKMAN_SCENE, Vector2(x, y))
		if e != null and e.get("foot_offset") != null:
			e.global_position.y = y - e.foot_offset
		_units.append(e)
	var t_spawn := Time.get_ticks_usec() - t0
	# 走位输入初始化（seeded）
	_dirs.resize(UNIT_COUNT)
	_turn_counters.resize(UNIT_COUNT)
	for i in UNIT_COUNT:
		_dirs[i] = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		_turn_counters[i] = _rng.randi_range(20, 90)
	# 热身（不计时）：让动画/分离进入稳态
	for f in WARMUP_FRAMES:
		_inject_walk_input()
		await get_tree().physics_frame
	return t_spawn


## 创建桩地图（正式测量与诊断共用）。
func _setup_map() -> void:
	_bench_map = BenchMap.new()
	_bench_map.name = "BenchMap"
	# EntityHost 必须在地图进树前挂好（MapBase 的 entity_host 是 @onready 解析）
	var host := Node2D.new()
	host.name = "EntityHost"
	_bench_map.add_child(host)
	add_child(_bench_map)


## 200 个真实单位进树，seed 固定的随机走位输入，推进 600 物理帧测墙钟。
func _bench_group_physics() -> void:
	_setup_map()
	var t_spawn: int = await _spawn_group()
	# 计时 600 物理帧
	_frame_in_measure = 0
	_measure_msec = Time.get_ticks_msec()
	for f in MEASURE_FRAMES:
		_inject_walk_input()
		await get_tree().physics_frame
	var wall_ms := Time.get_ticks_msec() - _measure_msec
	_emit({
		"bench": "group_physics", "units": UNIT_COUNT, "frames": MEASURE_FRAMES,
		"wall_ms_total": wall_ms,
		"ms_per_frame": float(wall_ms) / MEASURE_FRAMES,
		"us_per_unit_per_frame": float(wall_ms) * 1000.0 / (MEASURE_FRAMES * UNIT_COUNT),
		"spawn_ms": float(t_spawn) / 1000.0,
		"golden_hash": _golden_hash(),
	})


## 走位输入注入：换向倒计时归零时从 seeded RNG 取新方向（跑/走混合）。
## 在根节点 _physics_process 时机（先于子单位）注入，单位当帧消费。
func _inject_walk_input() -> void:
	for i in UNIT_COUNT:
		var e: Node = _units[i]
		if e == null or not is_instance_valid(e) or e.is_dead():
			continue
		_turn_counters[i] -= 1
		if _turn_counters[i] <= 0:
			_turn_counters[i] = _rng.randi_range(20, 90)
			_dirs[i] = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
			# 10% 概率要求奔跑（覆盖 run 分支路径）
			e.ai_move(_dirs[i], _rng.randf() < 0.1)
		else:
			e.ai_move(_dirs[i], e._ai_running)


## 黄金哈希：位置/hp/morale/facing/z_index/当前动画 摘要。
## 优化不得改变该值（行为零回归的机器可判据）。
func _golden_hash() -> String:
	var s := ""
	for e in _units:
		if e == null or not is_instance_valid(e):
			s += "gone;"
			continue
		var h: Node = e.get_health()
		s += "%.6f,%.6f:%.3f:%.3f:%d:%d:%s;" % [
			e.global_position.x, e.global_position.y,
			h.hp if h != null else -1.0,
			h.morale if h != null else -1.0,
			e.get_facing(), e.z_index, e.get_current_anim(),
		]
	return s.sha1_text()


# ─────────────────────────── 阶段 3：分项微基准 ───────────────────────────

## 对真实 200 单位逐项计时（单位保持稳态：位置不变 → z_index 守卫短路路径真实）。
func _bench_micro() -> void:
	await _micro_sync_markers()
	await _micro_query_neighbors()
	await _micro_rest_morale()
	await _micro_stun_query()
	await _micro_z_index_write()
	await _micro_y_clamp()
	await _micro_overlay_frame()
	await _micro_move_pipeline()
	await _diag_breakdown()


func _micro_sync_markers() -> void:
	var t0 := Time.get_ticks_usec()
	for it in MICRO_ITERS:
		for e in _units:
			e._sync_markers_transform()
	_emit({"bench": "micro_sync_markers", "calls": MICRO_ITERS * UNIT_COUNT,
			"us_per_call": float(Time.get_ticks_usec() - t0) / (MICRO_ITERS * UNIT_COUNT)})
	await get_tree().process_frame


func _micro_query_neighbors() -> void:
	var t0 := Time.get_ticks_usec()
	for it in MICRO_ITERS:
		for e in _units:
			_bench_map.query_neighbors(e.global_position, e.SEPARATION_RADIUS)
	var n: int = MICRO_ITERS * UNIT_COUNT
	_emit({"bench": "micro_query_neighbors", "calls": n,
			"us_per_call": float(Time.get_ticks_usec() - t0) / n})
	await get_tree().process_frame


func _micro_rest_morale() -> void:
	var t0 := Time.get_ticks_usec()
	for it in MICRO_ITERS:
		for e in _units:
			e._apply_rest_morale_recovery(1.0 / 60.0)
	var n: int = MICRO_ITERS * UNIT_COUNT
	_emit({"bench": "micro_rest_morale", "calls": n,
			"us_per_call": float(Time.get_ticks_usec() - t0) / n})
	await get_tree().process_frame


func _micro_stun_query() -> void:
	var t0 := Time.get_ticks_usec()
	for it in MICRO_ITERS:
		for e in _units:
			e.is_stunned()
	var n: int = MICRO_ITERS * UNIT_COUNT
	_emit({"bench": "micro_is_stunned", "calls": n,
			"us_per_call": float(Time.get_ticks_usec() - t0) / n})
	await get_tree().process_frame


## z_index 重排写：位置不变时走"计算 zi + 比较"守卫路径（写被跳过）。
func _micro_z_index_write() -> void:
	var t0 := Time.get_ticks_usec()
	for it in MICRO_ITERS:
		for e in _units:
			var zi: int = int(e.global_position.y * 0.1)
			if zi != e.z_index:
				e.z_index = zi
	var n: int = MICRO_ITERS * UNIT_COUNT
	_emit({"bench": "micro_z_index_guard", "calls": n,
			"us_per_call": float(Time.get_ticks_usec() - t0) / n})
	await get_tree().process_frame


## y 范围 clamp：等价于物理帧尾的两行 clampf 算术。
func _micro_y_clamp() -> void:
	var t0 := Time.get_ticks_usec()
	var acc: float = 0.0
	for it in MICRO_ITERS:
		for e in _units:
			var p: Vector2 = e.global_position
			var y_min: float = e.ground_y - e.foot_offset
			var y_max: float = e.ground_bottom - e.foot_offset
			acc += clampf(p.y, y_min, y_max)
			acc += clampf(p.x, e.map_left, e.map_right)
	_emit({"bench": "micro_y_clamp", "calls": MICRO_ITERS * UNIT_COUNT,
			"us_per_call": float(Time.get_ticks_usec() - t0) / (MICRO_ITERS * UNIT_COUNT),
			"sink": acc})
	await get_tree().process_frame


## rig 无头算术：procedural_overlay._on_frame 的 GDScript 侧算术
## （呼吸/惯性/spring/噪声），1 万次调用（无头渲染 dummy 但算术照跑）。
func _micro_overlay_frame() -> void:
	var overlay: Node = _units[0].get_node_or_null("RigHost/OutlineGroup/StickmanRig/ProceduralOverlay")
	if overlay == null:
		_emit({"bench": "micro_overlay_frame", "error": "overlay 不存在"})
		return
	var t0 := Time.get_ticks_usec()
	for i in PIPELINE_ITERS:
		overlay._on_frame()
	var us := Time.get_ticks_usec() - t0
	_emit({"bench": "micro_overlay_frame", "calls": PIPELINE_ITERS,
			"us_per_call": float(us) / PIPELINE_ITERS, "us_total": us})
	await get_tree().process_frame


## 移动管线：_handle_ai_input（含 _apply_separation + _apply_movement）1 万次。
## 用单位 0 单独测（位置会被推动，放最后不污染黄金哈希）。
func _micro_move_pipeline() -> void:
	var e: Node = _units[0]
	var dir := Vector2(1.0, 0.3).normalized()
	var delta := 1.0 / 60.0
	var t0 := Time.get_ticks_usec()
	for i in PIPELINE_ITERS:
		e.ai_move(dir, false)
		e._handle_ai_input(delta)
	var us := Time.get_ticks_usec() - t0
	_emit({"bench": "micro_move_pipeline", "calls": PIPELINE_ITERS,
			"us_per_call": float(us) / PIPELINE_ITERS, "us_total": us})


func _emit(d: Dictionary) -> void:
	print("[BENCH] ", JSON.stringify(d))


# ─────────────────────────── 诊断分解（定位用，不进对比结论）───────────────────────────

## A/B 墙钟分解：定位群体帧成本里"动画 GDScript"vs"渲染子树（AnimationTree/IK）"
## vs"实体物理+脚本"vs"主循环底噪"。诊断会改变单位状态，放最后（哈希已算完）。
func _diag_breakdown() -> void:
	const FRAMES := 120
	var overlay_script: GDScript = load("res://modules/units/scripts/rig/procedural_overlay.gd")
	# A：现状（全开）
	var ms_a := await _diag_time_window(FRAMES)
	# C：只停动画 GDScript（rig._process 检测 + overlay 叠加），实体物理照跑
	var rigs: Array = []
	for e in _units:
		var rig: Node = e.get_node_or_null("RigHost/OutlineGroup/StickmanRig")
		if rig != null:
			rig.set_process(false)
			rigs.append(rig)
	overlay_script.ENABLED = false
	var ms_c := await _diag_time_window(FRAMES)
	overlay_script.ENABLED = true
	for rig in rigs:
		rig.set_process(true)
	# D：再冻结整个渲染子树 RigHost（AnimationTree/AnimationPlayer/Skeleton2D IK/overlay）
	for e in _units:
		var rh: Node = e.get_node_or_null("RigHost")
		if rh != null:
			rh.process_mode = Node.PROCESS_MODE_DISABLED
	var ms_d := await _diag_time_window(FRAMES)
	for e in _units:
		var rh: Node = e.get_node_or_null("RigHost")
		if rh != null:
			rh.process_mode = Node.PROCESS_MODE_INHERIT
	# B：全部冻结（单位及子孙全停）——主循环/引擎底噪
	for e in _units:
		e.process_mode = Node.PROCESS_MODE_DISABLED
	var ms_b := await _diag_time_window(FRAMES)
	for e in _units:
		e.process_mode = Node.PROCESS_MODE_INHERIT
	_emit({"bench": "diag_breakdown", "frames": FRAMES,
			"ms_all": ms_a, "ms_no_anim_script": ms_c, "ms_no_rig_subtree": ms_d,
			"ms_frozen": ms_b,
			"anim_script_ms": ms_a - ms_c,
			"rig_subtree_ms": ms_c - ms_d,
			"entity_ms": ms_d - ms_b})


## 推进 FRAMES 物理帧（照常注入走位），返回每帧墙钟 ms。
func _diag_time_window(frames: int) -> float:
	var t0 := Time.get_ticks_msec()
	for f in frames:
		_inject_walk_input()
		await get_tree().physics_frame
	return float(Time.get_ticks_msec() - t0) / frames

