extends Node
## 集成测试：领地运行时状态域 + expansion api 查询 + EventBus 三信号（批次 C1）。
##
## 存档往返走真实链路：SaveManager.save_game → EventBus.game_saving → WorldState
## 写 world_state 表 → load_game → game_loaded → WorldState 恢复（同
## test_save_roundtrip 的链路口径；内存快照另有 JSON 往返仿真单跳）。
## unit 层的注册表纯逻辑用例见 tests/unit/test_territory_registry.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptExpansionApi := preload("res://modules/expansion/api.gd")

const TEST_SLOT := 3  # 有效槽 0~4；错开 test_save_roundtrip 的 TEST_SLOT=4（套件分进程跑，互不冲突）
const TID_1 := "ter_bandit_camp_01"
const TID_2 := "ter_bandit_camp_02"
const TID_3 := "ter_warlord_keep_01"

var _runner: TestRunner


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("WorldState 域：JSON 往返类型还原", _test_memory_roundtrip)
	_runner.add_test("存档往返：真实 SaveManager 全链路", _test_save_roundtrip)
	_runner.add_test("api 骨架：list_targets/状态查询/通关判定", _test_api_queries)
	_runner.add_test("EventBus：三新信号已声明可发射", _test_event_bus_signals)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_memory_roundtrip() -> void:
	WorldState.territories = {}
	WorldState.territories[TID_1] = {
		"state": 1, "garrison_losses": 2, "control_progress": 100.0,
	}
	# 存档落库走 JSON.stringify（WorldState._on_game_saving），此处按同一编码仿真一跳
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(WorldState.get_save_data()))
	WorldState.territories = {}
	WorldState.load_save_data(snapshot)
	_runner.assert_true(WorldState.territories.has(TID_1), "territories 条目随快照恢复")
	var record: Dictionary = WorldState.territories[TID_1]
	_runner.assert_true(record["state"] is int, "state 整型还原")
	_runner.assert_equal(int(record["state"]), 1, "state 值 CAPTURED")
	_runner.assert_equal(int(record["garrison_losses"]), 2, "战损值保持")
	_runner.assert_approx(float(record["control_progress"]), 100.0, 0.001, "控制度保持")


func _test_save_roundtrip() -> void:
	WorldState.territories = {}
	WorldState.territories[TID_1] = {"state": 1, "garrison_losses": 3, "control_progress": 100.0}
	SaveManager.delete_game(TEST_SLOT)
	_runner.assert_true(SaveManager.save_game(TEST_SLOT), "存档成功（game_saving → world_state 表）")
	WorldState.territories = {}
	_runner.assert_true(SaveManager.load_game(TEST_SLOT), "读档成功（game_loaded → WorldState 恢复）")
	SaveManager.end_load()  # load 保持 DB 打开等场景恢复，测试无场景须手动关
	_runner.assert_true(WorldState.territories.has(TID_1), "读档后领地状态回传")
	var record: Dictionary = WorldState.territories.get(TID_1, {})
	_runner.assert_equal(int(record.get("state", -1)), 1, "state 经 DB 往返保持")
	_runner.assert_equal(int(record.get("garrison_losses", -1)), 3, "战损经 DB 往返保持")


func _test_api_queries() -> void:
	WorldState.territories = {}
	var api: Node = ScriptExpansionApi.new()
	api.name = "TestExpansionApi"
	add_child(api)
	# list_targets：出城选项动态项数据源（契约 §五）
	var targets: Array[Dictionary] = api.list_targets()
	_runner.assert_equal(targets.size(), 3, "3 座据点可征伐")
	for t in targets:
		_runner.assert_true(t.has_all(["id", "name_zh", "garrison_count", "captured", "rewards_preview"]),
				"target %s 字段齐全" % t.get("id", "?"))
		_runner.assert_false(bool(t["captured"]), "%s 初始未臣服" % t.get("id", "?"))
	# 状态查询：缺失条目 → HOSTILE；写入后翻 CAPTURED
	_runner.assert_equal(api.get_territory_state(TID_1), 0, "缺失条目按 HOSTILE 查询")
	# 车轮战扣减感知：list_targets 守军数 = 配置 − garrison_losses（C6 出城选项口径）
	var base_count: int = int(targets[0]["garrison_count"])  # targets[0] = 配置首条 TID_1
	WorldState.territories[TID_1] = {"state": 0, "garrison_losses": 1, "control_progress": 100.0}
	var got_count := -1
	for t in api.list_targets():
		if String(t["id"]) == TID_1:
			got_count = int(t["garrison_count"])
	_runner.assert_equal(got_count, base_count - 1, "list_targets 守军数随车轮战扣减")
	WorldState.territories[TID_1] = {"state": 1, "garrison_losses": 0, "control_progress": 100.0}
	_runner.assert_equal(api.get_territory_state(TID_1), 1, "写入后 CAPTURED")
	var first: Dictionary = api.list_targets()[0]
	_runner.assert_true(bool(first["captured"]), "list_targets 的 captured 随状态翻转")
	# 通关判定：全占才 true；空集恒 false
	_runner.assert_false(api.is_all_captured(), "未全占不判通关")
	for tid in [TID_2, TID_3]:
		WorldState.territories[tid] = {"state": 1, "garrison_losses": 0, "control_progress": 100.0}
	_runner.assert_true(api.is_all_captured(), "三座全占判通关")
	WorldState.territories = {}
	_runner.assert_false(api.is_all_captured(), "清空状态回未占（且无记录不误判）")
	api.queue_free()


func _test_event_bus_signals() -> void:
	for signal_name in ["territory_state_changed", "region_owner_changed", "unlock_granted"]:
		_runner.assert_true(EventBus.has_signal(signal_name), "EventBus.%s 已声明" % signal_name)
	# 零订户发射不炸（C5 接线前的冒烟）
	EventBus.territory_state_changed.emit(TID_1, 1)
	EventBus.region_owner_changed.emit("city_1035", "player")
	EventBus.unlock_granted.emit("unlock_arrow_tower")


func _cleanup() -> void:
	WorldState.territories = {}
	SaveManager.delete_game(TEST_SLOT)
