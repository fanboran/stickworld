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

## 观测位常量来源（tests/README 禁区：不依赖 class_name 全局注册，显式 preload）
const TestRunner := preload("res://tests/core/test_runner.gd")

const UNIT_SCRIPTS: Array[String] = [
	"res://tests/unit/test_placement_grid.gd",
	"res://tests/unit/test_health_component.gd",
	"res://tests/unit/test_resource_manager.gd",
	"res://tests/unit/test_resources_api.gd",
	"res://tests/unit/test_crystal_sparkles.gd",
	"res://tests/unit/test_organization_manager.gd",
	"res://tests/unit/test_org_command_dispatcher.gd",
	"res://tests/unit/test_transport_layer.gd",
	"res://tests/unit/test_entity_states.gd",
	"res://tests/unit/test_world_contract.gd",
	"res://tests/unit/test_world_ledger.gd",
	"res://tests/unit/test_command_chain.gd",
	"res://tests/unit/test_formation_system.gd",
	"res://tests/unit/test_behavior_state_machine.gd",
	"res://tests/unit/test_stickman_anims.gd",
	"res://tests/unit/test_joint_atlas_mip.gd",
	"res://tests/unit/test_squad_dest.gd",
	"res://tests/unit/test_squad_decision.gd",
	"res://tests/unit/test_squad_follow.gd",
	"res://tests/unit/test_formation_slots.gd",
	"res://tests/unit/test_ai_enhance.gd",
	"res://tests/unit/test_target_acquire.gd",
	"res://tests/unit/test_squad_intent_planner.gd",
	"res://tests/unit/test_ai_arrive.gd",
	"res://tests/unit/test_behavior_breach.gd",
	"res://tests/unit/test_wall_avoid.gd",
	"res://tests/unit/test_combat_fidelity.gd",
	"res://tests/unit/test_strike_frame.gd",
	"res://tests/unit/test_user_control_charge.gd",
	"res://tests/unit/test_team_ai_stance.gd",
	"res://tests/unit/test_team_ai_orders.gd",
	"res://tests/unit/test_team_ai_personality.gd",
	"res://tests/unit/test_ai_param_panel.gd",
	"res://tests/unit/test_ai_spawn_jitter.gd",
	"res://tests/unit/test_ai_timing_save.gd",
	"res://tests/unit/test_save_completeness.gd",
	"res://tests/unit/test_task_board.gd",
	"res://tests/unit/test_ranged_slot_anchor.gd",
	"res://tests/unit/test_battle_line.gd",
	"res://tests/unit/test_squad_phase_plan.gd",
	"res://tests/unit/test_authority_switch.gd",
	"res://tests/unit/test_utility_scorer.gd",
	"res://tests/unit/test_org_default_behavior.gd",
	"res://tests/unit/test_meric_heal.gd",
	"res://tests/unit/test_balance_config.gd",
	"res://tests/unit/test_texture_gen_api.gd",
	"res://tests/unit/test_texture_gen_render.gd",
	"res://tests/unit/test_fx.gd",
	"res://tests/unit/test_incoming_threat_ledger.gd",
	"res://tests/unit/test_items.gd",
	"res://tests/unit/test_build_unlock_gate.gd",
	"res://tests/unit/test_work_job_board.gd",
	"res://tests/unit/test_battle_settlement.gd",
	"res://tests/unit/test_inventory.gd",
	"res://tests/unit/test_map_camera_clamp.gd",
	"res://tests/unit/test_hd2d_projection.gd",
	"res://tests/unit/test_hd2d_fx_anchor.gd",
	"res://tests/unit/test_map_mode_manager.gd",
	"res://tests/unit/test_population_jitter.gd",
	"res://tests/unit/test_river_parse.gd",
	"res://tests/unit/test_settlement_blob.gd",
	"res://tests/unit/test_road_parse.gd",
	"res://tests/unit/test_travel_planner.gd",
	"res://tests/unit/test_world_map_region_distance.gd",
	"res://tests/unit/test_world_map_l1_gate.gd",
	"res://tests/unit/test_city_gen.gd",
	"res://tests/unit/test_political_data.gd",
	"res://tests/unit/test_political_mesh.gd",
	"res://tests/unit/test_province_politics.gd",
	"res://tests/unit/test_project_render_settings.gd",
	"res://tests/unit/test_profession_registry.gd",
	"res://tests/unit/test_stickman_no_body_tint.gd",
	"res://tests/unit/test_behavior_harvest.gd",
	"res://tests/unit/test_work_slots_rhythm.gd",
	"res://tests/unit/test_requisition_exclusion.gd",
	"res://tests/unit/test_townlife_save_persistence.gd",
	"res://tests/unit/test_keymap_registry.gd",
	"res://tests/unit/test_formation_platoon.gd",
	"res://tests/unit/test_formation_fireteam.gd",
	"res://tests/unit/test_squad_cohesion.gd",
	"res://tests/unit/test_sustained_fire_heat.gd",
	"res://tests/unit/test_minimap_layout.gd",
	"res://tests/unit/test_mirror_channel.gd",
	"res://tests/unit/test_ai_viz_signal.gd",
	"res://tests/unit/test_resource_bar_hint.gd",
	"res://tests/unit/test_death_drops.gd",
	"res://tests/unit/test_building_state.gd",
	"res://tests/unit/test_building_gen_registry.gd",
	"res://tests/unit/test_environment_daycycle.gd",
	"res://tests/unit/test_environment_system.gd",
	"res://tests/unit/test_hd2d_street_placer.gd",
	"res://tests/unit/test_logistics_skeleton.gd",
	"res://tests/unit/test_skill_ledger.gd",
	"res://tests/unit/test_achievement_skeleton.gd",
	"res://tests/unit/test_blueprint_skeleton.gd",
	"res://tests/unit/test_org_slots.gd",
	"res://tests/unit/test_org_prereqs.gd",
	"res://tests/unit/test_training_post.gd",
]

## unit 层 .tscn 反向自检豁免名单（默认空）。
## 格式："res://tests/unit/xxx.tscn": "保留理由（为什么必须留在 unit 层且不参与批跑）"。
## unit 层只跑 .gd 套件（batch_runner 直接 load），.tscn 壳不会被任何入口执行；
## 盘上出现即视为回潮——确需保留必须在此写明理由，否则判失败。
const TSCN_ALLOWLIST: Dictionary = {}

const PER_TEST_TIMEOUT_SEC: float = 30.0

var _failed: Array[String] = []

## 排查观测位（默认关闭）：环境变量 SW_BATCH_TRACE=<绝对路径> 时，每套件
## 起止/耗时/退出码逐行落盘（每次写即关，保证并行观测实时可见）。
## stdout 在重定向下全缓冲，长跑期间黑盒——排查并行轮转问题时靠它看实时进度。
var _trace_path: String = ""
var _t0_ms: int = 0


func _ready() -> void:
	Engine.set_meta("test_batch", true)
	var t0: int = Time.get_ticks_msec()
	_t0_ms = t0
	_trace_path = OS.get_environment("SW_BATCH_TRACE")
	_trace("batch start pid=%d" % OS.get_process_id())
	_check_manifest()
	for path in UNIT_SCRIPTS:
		await _run_one(path)
	var secs: float = (Time.get_ticks_msec() - t0) / 1000.0
	_trace("batch end failed=%d" % _failed.size())
	print("=== 批量汇总: %d / %d 通过（%.1fs）===" % [
		UNIT_SCRIPTS.size() - _failed.size(), UNIT_SCRIPTS.size(), secs
	])
	if _failed.is_empty():
		await get_tree().process_frame
		get_tree().quit(0)
	else:
		for f in _failed:
			print("[BATCH-FAIL] %s" % f)
		_trace("batch-fail list: %s" % ", ".join(_failed))
		await get_tree().process_frame
		get_tree().quit(1)


## 追踪一行到 SW_BATCH_TRACE 指定文件（相对批启动的毫秒时间戳）；未设环境变量时零开销。
func _trace(line: String) -> void:
	if _trace_path.is_empty():
		return
	var f := FileAccess.open(_trace_path, FileAccess.READ_WRITE if FileAccess.file_exists(_trace_path) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("[%8dms] %s" % [Time.get_ticks_msec() - _t0_ms, line])
	f.close()


## 清单自检（双向）：
##   - 正向：tests/unit/ 下每个 .gd 都必须在 UNIT_SCRIPTS 里——套件文件躺在盘上
##     却没登记进清单 = 它永远不会跑，且不会有任何红灯（静默漏测盲区）。
##   - 反向：tests/unit/ 下出现 .tscn 壳且不在 TSCN_ALLOWLIST 里 = 判失败。unit 层
##     由本运行器直接 load(.gd)，.tscn 不会被任何入口执行，留着只会让"有场景就能
##     单独跑"的误解复燃。
## 目录枚举不可用（打包/异常）时只提示不判失败，避免误报。
func _check_manifest() -> void:
	var dir := DirAccess.open("res://tests/unit")
	if dir == null:
		print("[BATCH-NOTE] 无法枚举 res://tests/unit，跳过清单自检")
		return
	var registered: Dictionary = {}
	for p in UNIT_SCRIPTS:
		registered[p] = true
	var found: int = 0
	var found_tscn: int = 0
	var unregistered: Array[String] = []
	var stray_tscn: Array[String] = []
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir():
			if fn.ends_with(".gd"):
				found += 1
				var full_gd := "res://tests/unit/" + fn
				if not registered.has(full_gd):
					unregistered.append(full_gd)
			elif fn.ends_with(".tscn"):
				found_tscn += 1
				var full_tscn := "res://tests/unit/" + fn
				if not TSCN_ALLOWLIST.has(full_tscn):
					stray_tscn.append(full_tscn)
		fn = dir.get_next()
	dir.list_dir_end()
	if found == 0:
		print("[BATCH-NOTE] 目录枚举结果为空，跳过清单自检")
		return
	for p in unregistered:
		_failed.append(p + "（未登记进 UNIT_SCRIPTS——本套件不会被运行）")
	for p in stray_tscn:
		_failed.append(p + "（unit 层 .tscn 壳不参与批跑——删除它；确需保留请在 TSCN_ALLOWLIST 写明理由）")
	print("[BATCH-CHECK] 清单自检：盘上 %d 个 .gd 套件 / 清单 %d 条，未登记 %d 个；.tscn 壳 %d 个，未豁免 %d 个" % [
		found, UNIT_SCRIPTS.size(), unregistered.size(), found_tscn, stray_tscn.size()
	])


func _run_one(path: String) -> void:
	_trace("suite load start: %s" % path)
	var load_t0: int = Time.get_ticks_msec()
	var script: GDScript = load(path) as GDScript
	if script == null:
		_failed.append(path + "（加载失败）")
		_trace("suite LOAD-FAIL: %s" % path)
		return
	_trace("suite loaded in %dms: %s" % [Time.get_ticks_msec() - load_t0, path])
	# 全局时间状态隔离：前一套件触发的 battle_started 自动暂停会残留到本进程，
	# 污染后续套件（2026-09-01 起 weapon_mount/arrow 挂了 TimeManager 暂停门禁，
	# PAUSED 残留会让命中帧/冷却推进全部空转）
	var tm: Node = get_node_or_null("/root/TimeManager")
	if tm != null and "current_speed" in tm and int(tm.current_speed) != int(tm.Speed.X1):
		tm.set_speed(tm.Speed.X1)
	# 零用例守卫的观测位：套件在自己的 TestRunner 收尾时写回真实计数
	Engine.set_meta(TestRunner.META_LAST_CASES, -1)
	Engine.set_meta(TestRunner.META_LAST_ASSERTS, -1)
	var inst: Node = script.new()
	inst.name = path.get_file().get_basename()
	add_child(inst)
	var run_t0: int = Time.get_ticks_msec()
	var code: int = await _await_done(inst)
	var cases: int = int(Engine.get_meta(TestRunner.META_LAST_CASES, -1))
	var asserts: int = int(Engine.get_meta(TestRunner.META_LAST_ASSERTS, 0))
	_trace("suite done in %dms code=%d cases=%d: %s" % [
		Time.get_ticks_msec() - run_t0, code, cases, path.get_file()
	])
	print("  [%s] %-46s 用例 %d / 断言 %d" % [
		"OK  " if code == 0 else "FAIL", inst.name, cases, asserts
	])
	if code == 0 and cases <= 0:
		_failed.append(path + "（零用例：套件未真正执行任何断言）")
	elif code != 0:
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
		_trace("suite TIMEOUT: %s" % inst.name)
		return 1
	return done[0]
