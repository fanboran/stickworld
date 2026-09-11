extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TerritoryRegistry 领地配置加载/查询/状态字段规范（批次 C1）。
##
## 纯逻辑无 autoload 依赖（batch 准入）：配置经 load() 读真实 territories.tres
## （配置契约锚点），注册表 new() 构造；WorldState 域与存档往返在
## tests/integration/test_expansion_territories.tscn（需真实 autoload 环境）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

const EXPECTED_IDS := ["ter_bandit_camp_01", "ter_bandit_camp_02", "ter_warlord_keep_01"]
## 守军 3/5/8 递增（架构 §2.1 数值锚点，AI 提案调参后此处同步）
const EXPECTED_GARRISON := [3, 5, 8]

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("配置加载：3 座据点全量入册", _test_load)
	_runner.add_test("查询：id 索引/守军计数/未知 id 安全", _test_queries)
	_runner.add_test("状态字段：初始态与 JSON 回传归一", _test_state_normalize)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_load() -> void:
	var reg := TerritoryRegistry.new()
	_runner.assert_true(reg.load_config(), "territories.tres 装载成功")
	_runner.assert_equal(reg.get_count(), 3, "3 座据点入册")
	for i in EXPECTED_IDS.size():
		var id: String = EXPECTED_IDS[i]
		_runner.assert_true(reg.has_territory(id), "含 %s" % id)
		var row: Dictionary = reg.get_territory(id)
		_runner.assert_false(String(row.get("name_zh", "")).is_empty(), "%s 有中文名" % id)
		# 地图/聚落/地块三级锚点：map_id 已在 game_root 注册；settlement_key/tile_key
		# 取自出生 L1 l1_world.json（占领染色目标，架构 §2.1+§9.1）
		_runner.assert_false(String(row.get("map_id", "")).is_empty(), "%s 有 map_id" % id)
		_runner.assert_false(String(row.get("settlement_key", "")).is_empty(), "%s 有 settlement_key" % id)
		_runner.assert_false(String(row.get("tile_key", "")).is_empty(), "%s 有 tile_key（§9.1 预留）" % id)
		# 守军计数递增锚点
		_runner.assert_equal(reg.get_garrison_count(id), EXPECTED_GARRISON[i], "%s 守军 %d 人" % [id, EXPECTED_GARRISON[i]])


func _test_queries() -> void:
	var reg := TerritoryRegistry.new()
	reg.load_config()
	var row: Dictionary = reg.get_territory("ter_bandit_camp_01")
	# garrison 条目字段规范：profile = stickmen.tres 单位 id（批次 C4 按 id 刷军）、
	# tier = tactics.tres 战术 id、count > 0
	var garrison: Array = row.get("garrison", [])
	_runner.assert_gt(garrison.size(), 0, "garrison 条目非空")
	for entry in garrison:
		_runner.assert_true(String(entry.get("profile", "")).begins_with("stm_"), "守军 profile 是单位档案 id")
		_runner.assert_true(String(entry.get("tier", "")).begins_with("tac_"), "守军 tier 是战术档案 id")
		_runner.assert_gt(int(entry.get("count", 0)), 0, "守军 count 为正")
	# commander：敌将档案 + 三项撤仗阈值（架构 §4.2 评估输入）
	var commander: Dictionary = row.get("commander", {})
	_runner.assert_false(String(commander.get("profile", "")).is_empty(), "敌将有档案")
	var thresholds: Dictionary = commander.get("retreat_thresholds", {})
	for key in ["casualty_rate", "loss_ratio", "timeout"]:
		_runner.assert_true(thresholds.has(key), "撤仗阈值含 %s" % key)
	# rewards：资源键用真实资源 id（config/resources/resources.tres 的 res_* 前缀）
	var resources: Dictionary = row.get("rewards", {}).get("resources", {})
	_runner.assert_gt(resources.size(), 0, "奖励资源非空")
	for res_id in resources:
		_runner.assert_true(String(res_id).begins_with("res_"), "资源 id 是 res_* 真实 id（%s）" % res_id)
	# 未知 id 安全回落
	_runner.assert_false(reg.has_territory("ter_nope"), "未知 id 不在册")
	_runner.assert_true(reg.get_territory("ter_nope").is_empty(), "未知 id 返回空字典")
	_runner.assert_equal(reg.get_garrison_count("ter_nope"), 0, "未知 id 守军计数 0")
	# 重复装载覆盖不叠加
	_runner.assert_true(reg.load_config(), "重复装载成功")
	_runner.assert_equal(reg.get_count(), 3, "重复装载不叠加")


func _test_state_normalize() -> void:
	# 初始态字段规范（WorldState 缺失条目的查询缺省）
	var init: Dictionary = TerritoryRegistry.initial_state()
	_runner.assert_equal(int(init["state"]), TerritoryRegistry.State.HOSTILE, "初始态 HOSTILE")
	_runner.assert_equal(int(init["garrison_losses"]), 0, "初始战损 0")
	_runner.assert_approx(float(init["control_progress"]), 100.0, 0.001, "控制度满值（§9.1 P0 恒 100）")
	# JSON 往返：int 序列化后 parse 回 float，normalize 整型还原
	var captured := {"state": TerritoryRegistry.State.CAPTURED, "garrison_losses": 2, "control_progress": 100.0}
	var roundtrip: Variant = JSON.parse_string(JSON.stringify(captured))
	var norm: Dictionary = TerritoryRegistry.normalize_state(roundtrip)
	_runner.assert_true(norm["state"] is int, "state 整型还原")
	_runner.assert_equal(int(norm["state"]), TerritoryRegistry.State.CAPTURED, "state 值保持 CAPTURED")
	_runner.assert_true(norm["garrison_losses"] is int, "garrison_losses 整型还原")
	_runner.assert_equal(int(norm["garrison_losses"]), 2, "garrison_losses 值保持")
	# 部分缺失/非法输入回落规范形，不炸
	var partial: Dictionary = TerritoryRegistry.normalize_state({"state": 1})
	_runner.assert_equal(int(partial["garrison_losses"]), 0, "缺失字段补缺省")
	_runner.assert_true(TerritoryRegistry.normalize_state("junk") == TerritoryRegistry.initial_state(), "非字典输入回落初始态")
	_runner.assert_true(TerritoryRegistry.normalize_state(null) == TerritoryRegistry.initial_state(), "null 输入回落初始态")
