extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：征伐入口数据面（expansion 契约面 list_targets / describe_target /
## 聚落反查 / 车轮战扣减展示）。
##
## 钉死五条语义：
## ① 出征入口的数据齐备——守军逐条编成（含兵种名）+ 敌将 + 战利品（含资源名）
##    + map_id/settlement_key/owner/faction（战略图双击与城门出门框共用同一份数据）；
## ② 车轮战扣减在**展示层与刷军侧同一规则**（TerritoryRegistry.apply_losses 单一
##    真相源：余量从头部条目填满，后排先缺）；
## ③ 聚落反查只认未臣服据点（双击已占领聚落应回落旅行，不是再征一次）；
## ④ 未装配/缺表环境不炸（装配缺失 → 空列表 / 描述串兜底）；
## ⑤ 奖励可见与解锁对齐——入账明细一句话写出资源名与解锁展示名（不暴露
##    unlock_* 原始 id），且每个奖励解锁项都对得上建筑侧门禁（buildings.tres
##    的 unlocked_by_tech）——两侧 id 漂移即红灯。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const RegistryScript := preload("res://modules/expansion/scripts/territory_registry.gd")
const ApiScript := preload("res://modules/expansion/api.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("配置: 三座据点可载入", _test_config_loads)
	_runner.add_test("扣减: 前满后缺(头填满/尾先缺)", _test_apply_losses_head_first)
	_runner.add_test("扣减: 全损清空且不越界", _test_apply_losses_exhausted)
	_runner.add_test("编成: 逐条带兵种名", _test_remaining_garrison_named)
	_runner.add_test("入口: list_targets 字段齐备", _test_list_targets_fields)
	_runner.add_test("入口: 情报串含守军与战利品", _test_describe_target)
	_runner.add_test("奖励: 入账明细一句话（资源名+解锁展示名）", _test_describe_loot)
	_runner.add_test("奖励: 解锁项配置对齐（展示名↔建筑门禁）", _test_unlock_config_alignment)
	_runner.add_test("入口: 聚落反查只认未臣服", _test_find_by_settlement)
	_runner.add_test("兼容: 旧字段 rewards_preview 保留", _test_legacy_preview)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


## 装配态 api（_ready 自载配置；测试末清理）
func _make_api() -> Node:
	var api := Node.new()
	api.set_script(ApiScript)
	add_child(api)
	return api


func _test_config_loads() -> void:
	var reg = RegistryScript.new()
	_runner.assert_true(reg.load_config(), "territories.tres 装载成功")
	_runner.assert_equal(reg.get_count(), 3, "首版三座据点")


func _test_apply_losses_head_first() -> void:
	var garrison: Array = [
		{"profile": "a", "count": 2},
		{"profile": "b", "count": 1},
	]
	# 语义：剩余配额从**头部条目填满** → 前排主力保持满编，后排先缺（架构 §2.3 车轮战）
	var out: Array = RegistryScript.apply_losses(garrison, 1)
	_runner.assert_equal(int(out[0]["count"]), 2, "头条填满不扣（2→2）")
	_runner.assert_equal(int(out[1]["count"]), 0, "尾条先缺（1→0）")
	_runner.assert_equal(int(garrison[0]["count"]), 2, "不改原配置行（副本语义）")


func _test_apply_losses_exhausted() -> void:
	var garrison: Array = [
		{"profile": "a", "count": 2},
		{"profile": "b", "count": 1},
	]
	var out: Array = RegistryScript.apply_losses(garrison, 99)
	_runner.assert_equal(int(out[0]["count"]), 0, "超量扣减 clamp 0（头）")
	_runner.assert_equal(int(out[1]["count"]), 0, "超量扣减 clamp 0（尾）")
	_runner.assert_equal(out.size(), 2, "条目保留（count 归零不删行，架构 §2.3）")


func _test_remaining_garrison_named() -> void:
	var api := _make_api()
	var targets: Array = api.list_targets()
	_runner.assert_gt(targets.size(), 0, "至少一个目标")
	var garrison: Array = targets[0].get("garrison", [])
	_runner.assert_gt(garrison.size(), 0, "守军逐条编成非空")
	for entry in garrison:
		_runner.assert_false(String(entry.get("name_zh", "")).is_empty(), "兵种名已解析（非空）")
	api.queue_free()


func _test_list_targets_fields() -> void:
	var api := _make_api()
	for t in api.list_targets():
		for field in ["id", "name_zh", "map_id", "settlement_key", "state", "captured",
				"owner", "faction", "garrison_count", "garrison", "commander", "rewards",
				"rewards_preview"]:
			_runner.assert_true(t.has(field), "字段 %s 齐备（%s）" % [field, t.get("id", "")])
		_runner.assert_true(String(t.get("map_id", "")).begins_with("l1_settlement_"),
				"据点图 id 指向聚落图（%s）" % t.get("map_id", ""))
	api.queue_free()


## 解锁项配置对齐（P3）：据点奖励声明的每个 unlocks id 都须①有展示名（UNLOCK_LABELS），
## 且②对得上建筑侧门禁（buildings.tres 的 unlocked_by_tech）——两侧 id 漂移即红灯
func _test_unlock_config_alignment() -> void:
	var api := _make_api()
	var labels: Dictionary = api.UNLOCK_LABELS
	var defs: Dictionary = _building_defs_by_unlock()
	var declared: Array[String] = []
	var reg = RegistryScript.new()
	reg.load_config()
	for row in reg.get_all():
		if not (row is Dictionary):
			continue
		for id in (row.get("rewards", {}) as Dictionary).get("unlocks", []):
			declared.append(String(id))
	_runner.assert_gt(declared.size(), 0, "据点奖励至少声明一个解锁项")
	for id in declared:
		_runner.assert_true(labels.has(id), "解锁项 %s 有展示名（api.UNLOCK_LABELS）" % id)
		_runner.assert_true(defs.has(id), "解锁项 %s 对得上建筑门禁（某 def 的 unlocked_by_tech）" % id)
		_runner.assert_equal(String(labels.get(id, "")), String(defs.get(id, "")),
				"解锁项 %s 展示名与建筑名一致（%s / %s）" % [id, labels.get(id, ""), defs.get(id, "")])
	# 展示名表里不留悬空项（改名/删据点后须同步清理）
	for id in labels:
		_runner.assert_true(declared.has(String(id)), "UNLOCK_LABELS 的 %s 仍被据点声明（无悬空）" % id)
	api.queue_free()


## unlocked_by_tech → 建筑中文名（读 config/buildings/buildings.tres，仅测试侧跨读）
func _building_defs_by_unlock() -> Dictionary:
	var out: Dictionary = {}
	var res: Resource = load("res://config/buildings/buildings.tres")
	if res == null or not (res is BalanceResource):
		return out
	for row in BalanceResource.sanitized_rows(res as BalanceResource):
		if row is Dictionary:
			var req := String(row.get("unlocked_by_tech", ""))
			if not req.is_empty():
				out[req] = String(row.get("name_zh", ""))
	return out


func _test_describe_target() -> void:
	var api := _make_api()
	var text: String = api.describe_target(api.list_targets()[0])
	_runner.assert_true(text.contains("守军"), "情报串含守军编成：%s" % text)
	_runner.assert_true(text.contains("战利品") or text.contains("已无"), "情报串含战利品或空守提示")
	# 有解锁项的据点：情报串写展示名而非 id（奖励可见：玩家看得懂到手什么）
	var named := false
	for t in api.list_targets():
		var unlocks: Array = (t.get("rewards", {}) as Dictionary).get("unlocks", [])
		if unlocks.is_empty():
			continue
		var line: String = api.describe_target(t)
		_runner.assert_false(line.contains("unlock_"), "解锁项不暴露原始 id：%s" % line)
		named = line.contains("解锁 ")
	_runner.assert_true(named, "至少一个据点的情报串含「解锁 <展示名>」")
	api.queue_free()


## 入账明细一句话（占领通告用）：资源名 + 解锁展示名，空入账返回空串
func _test_describe_loot() -> void:
	var api := _make_api()
	var line: String = api.describe_loot({"resources": {"res_wood": 30, "res_stone": 20},
			"unlocks": ["unlock_stone_warehouse"]})
	_runner.assert_true(line.begins_with("战利品 "), "以战利品起头：%s" % line)
	_runner.assert_true(line.contains("木材30") and line.contains("石料20"), "写出资源名与数量：%s" % line)
	_runner.assert_true(line.contains("解锁 石造仓库"), "写出解锁展示名：%s" % line)
	_runner.assert_equal(api.describe_loot({}), "", "空入账返回空串（调用方不接尾句）")
	api.queue_free()


func _test_find_by_settlement() -> void:
	var api := _make_api()
	var first: Dictionary = api.list_targets()[0]
	var key := String(first.get("settlement_key", ""))
	_runner.assert_false(key.is_empty(), "据点带聚落键")
	var hit: Dictionary = api.find_target_by_settlement(key)
	_runner.assert_equal(String(hit.get("id", "")), String(first.get("id", "")), "按聚落键可反查")
	_runner.assert_true(api.find_target_by_settlement("settlement_not_exist").is_empty(),
			"无关聚落反查为空")
	# 已臣服 → 反查为空（双击该聚落应回落旅行）
	var id := String(first.get("id", ""))
	var backup: Variant = WorldState.territories.get(id, null)
	WorldState.territories[id] = {"state": 1, "garrison_losses": 0, "control_progress": 100.0}
	_runner.assert_true(api.find_target_by_settlement(key).is_empty(), "已臣服不再作为出征目标")
	if backup == null:
		WorldState.territories.erase(id)
	else:
		WorldState.territories[id] = backup
	api.queue_free()


func _test_legacy_preview() -> void:
	var api := _make_api()
	var t: Dictionary = api.list_targets()[0]
	_runner.assert_true(t.get("rewards_preview") is Dictionary, "旧展示字段仍是字典（兼容需求侧）")
	api.queue_free()
