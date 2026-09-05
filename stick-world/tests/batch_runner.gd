extends Node
## 单元测试批量运行器 —— 一个进程内跑完全部 unit 层（纯逻辑，无 GameRoot / autoload 依赖）。
##
## 优势：9 个单元套件共享一次引擎启动，省 8 次进程启动开销（约 2-3 分钟 → 15-30 秒）。
## 机制：设置 Engine meta "test_batch"，各单元测试经 TestRunner.finish_process
## 发射 test_done 信号而非 quit；本运行器逐个实例化、等待完成、汇总退出码。
##
## unit 层准入标准（违反则移出本清单，回退独立进程跑）：
##   - 不碰 autoload（EventBus/WorldState/SaveManager 等）
##   - 不进场景树（fixture 用 new() + 局部 add_child，用完即弃）
##   - 确定性（无固定帧等待）
##
## 运行：godot --headless --path <project> res://tests/batch_runner.tscn

const UNIT_SCRIPTS: Array[String] = [
	"res://tests/unit/test_placement_grid.gd",
	"res://tests/unit/test_health_component.gd",
	"res://tests/unit/test_resource_manager.gd",
	"res://tests/unit/test_resources_api.gd",
	"res://tests/unit/test_crystal_sparkles.gd",
	"res://tests/unit/test_organization_manager.gd",
	"res://tests/unit/test_entity_states.gd",
	"res://tests/unit/test_command_chain.gd",
	"res://tests/unit/test_formation_system.gd",
	"res://tests/unit/test_behavior_state_machine.gd",
	"res://tests/unit/test_stickman_anims.gd",
	"res://tests/unit/test_squad_dest.gd",
	"res://tests/unit/test_squad_decision.gd",
	"res://tests/unit/test_squad_follow.gd",
	"res://tests/unit/test_formation_slots.gd",
	"res://tests/unit/test_state_modifiers.gd",
	"res://tests/unit/test_ai_enhance.gd",
	"res://tests/unit/test_ai_morale.gd",
	"res://tests/unit/test_ai_arrive.gd",
	"res://tests/unit/test_combat_fidelity.gd",
	"res://tests/unit/test_strike_frame.gd",
	"res://tests/unit/test_team_ai_stance.gd",
	"res://tests/unit/test_team_ai_orders.gd",
	"res://tests/unit/test_rout_enhance.gd",
	"res://tests/unit/test_meric_heal.gd",
	"res://tests/unit/test_balance_config.gd",
	"res://tests/unit/test_texture_gen_api.gd",
	"res://tests/unit/test_fx.gd",
	"res://tests/unit/test_incoming_threat_ledger.gd",
	"res://tests/unit/test_map_camera_clamp.gd",
	"res://tests/unit/test_map_mode_manager.gd",
	"res://tests/unit/test_population_jitter.gd",
	"res://tests/unit/test_river_parse.gd",
	"res://tests/unit/test_settlement_blob.gd",
	"res://tests/unit/test_road_parse.gd",
]

const PER_TEST_TIMEOUT_SEC: float = 30.0

var _failed: Array[String] = []


func _ready() -> void:
	Engine.set_meta("test_batch", true)
	var t0: int = Time.get_ticks_msec()
	for path in UNIT_SCRIPTS:
		await _run_one(path)
	var secs: float = (Time.get_ticks_msec() - t0) / 1000.0
	print("=== 批量汇总: %d / %d 通过（%.1fs）===" % [
		UNIT_SCRIPTS.size() - _failed.size(), UNIT_SCRIPTS.size(), secs
	])
	if _failed.is_empty():
		await get_tree().process_frame
		get_tree().quit(0)
	else:
		for f in _failed:
			print("[BATCH-FAIL] %s" % f)
		await get_tree().process_frame
		get_tree().quit(1)


func _run_one(path: String) -> void:
	var script: GDScript = load(path) as GDScript
	if script == null:
		_failed.append(path + "（加载失败）")
		return
	# 全局时间状态隔离：前一套件触发的 battle_started 自动暂停会残留到本进程，
	# 污染后续套件（2026-09-01 起 weapon_mount/arrow 挂了 TimeManager 暂停门禁，
	# PAUSED 残留会让命中帧/冷却推进全部空转）
	var tm: Node = get_node_or_null("/root/TimeManager")
	if tm != null and "current_speed" in tm and int(tm.current_speed) != int(tm.Speed.X1):
		tm.set_speed(tm.Speed.X1)
	var inst: Node = script.new()
	inst.name = path.get_file().get_basename()
	add_child(inst)
	var code: int = await _await_done(inst)
	if code != 0:
		_failed.append(path)
	inst.queue_free()


func _await_done(inst: Node) -> int:
	var done: Array[int] = []
	inst.test_done.connect(func(c: int) -> void: done.append(c))
	var deadline_ms: float = Time.get_ticks_msec() + PER_TEST_TIMEOUT_SEC * 1000.0
	while done.is_empty() and Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame
	if done.is_empty():
		push_error("[BatchRunner] 超时(%.0fs): %s" % [PER_TEST_TIMEOUT_SEC, inst.name])
		return 1
	return done[0]
