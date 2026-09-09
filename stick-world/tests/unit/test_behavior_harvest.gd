extends Node
## 单元测试：采集行为族（BehaviorHarvest）——寻位/劳作节拍/产出入账/矿锭转化/重生。
##
## 覆盖批次 2（小镇生活与NPC职业）验收面：
##   - 无职业/待业实体 enter 即 finish（决策层回 idle）
##   - 资源点模式：寻最近匹配资源点 → 到位 → cycle 拍结算 harvest+produce
##   - 工位模式（铁匠）：占位定点 → consume 矿 → produce 锭；原料不足空拍
##   - 无工位配置 finish；资源点采空转寻位失败 finish
##   - ResourceNode 枯竭+重生（_enter_depleted/_regrow 状态翻转）
##
## batch 准入：资源点/实体全用鸭子协议桩；唯一真 ResourceNode 只验状态机
## （进局部树触发 _ready，程序化视觉一次性开销可接受）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")
const ScriptBehaviorHarvest := preload("res://modules/units/scripts/ai/behavior_harvest.gd")

signal test_done(code: int)

var _runner: TestRunner
## 当前用例的夹具容器（换用例即 free——组员随树退出自动出组，无跨用例泄漏）
var _case_root: Node = null


# ─────────────────────────────── 测试桩 ────────────────────────────────

## 实体桩：duck 协议全量（职业/移动/动画钩子），可在局部树内取 get_tree()
## （extends CharacterBody2D 对齐 BehaviorBase.entity 注解，赋值才能过类型检查）
class FakeEntity extends CharacterBody2D:
	var _profession_id: String = ""
	var move_dirs: Array = []
	var attack_count: int = 0

	func get_profession() -> String:
		return _profession_id

	func ai_move(dir: Vector2, _run: bool = false) -> void:
		move_dirs.append(dir)

	func ai_stop() -> void:
		pass

	func play_attack() -> void:
		attack_count += 1

	func set_action_progress(_r: float) -> void:
		pass

	func hide_action_progress() -> void:
		pass


## 资源点桩：鸭子协议（get_resource_id/harvest/is_depleted），零视觉开销
class FakeResourceNode extends Node2D:
	var res_id: String = "res_wood"
	var stock: int = 100
	var harvest_calls: Array = []
	var depleted: bool = false

	func get_resource_id() -> String:
		return res_id

	func harvest(qty: int) -> int:
		harvest_calls.append(qty)
		if depleted:
			return 0
		var gained: int = mini(qty, stock)
		stock -= gained
		if stock <= 0:
			depleted = true
		return gained

	func is_depleted() -> bool:
		return depleted


## ResourcesApi 桩：记录 produce/consume 流水，库存可配
class FakeResourcesApi extends Node2D:
	var stocks: Dictionary = {}
	var produce_calls: Array = []
	var consume_calls: Array = []

	func get_stock(rid: String, _region: String = "") -> float:
		return float(stocks.get(rid, 0.0))

	func produce(rid: String, amount: float, _region: String, _source: String) -> Dictionary:
		produce_calls.append([rid, amount])
		stocks[rid] = float(stocks.get(rid, 0.0)) + amount
		return {"ok": true}

	func consume(rid: String, amount: float, _region: String, _source: String) -> Dictionary:
		consume_calls.append([rid, amount])
		if float(stocks.get(rid, 0.0)) < amount:
			return {"ok": false}
		stocks[rid] = float(stocks.get(rid, 0.0)) - amount
		return {"ok": true}


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("无职业/待业: enter 即 finish", _test_no_profession_finish)
	_runner.add_test("资源点模式: 寻位→移动→劳作→harvest+produce", _test_resource_cycle)
	_runner.add_test("资源点采空: 转寻失败 finish", _test_resource_depleted_finish)
	_runner.add_test("工位模式: consume 矿→produce 锭", _test_worksite_conversion)
	_runner.add_test("工位模式: 原料不足空拍不产出", _test_worksite_no_material)
	_runner.add_test("无工位配置: enter 即 finish", _test_unknown_worksite_finish)
	_runner.add_test("ResourceNode: 枯竭+重生状态翻转", _test_resource_node_regen)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	if _case_root != null and is_instance_valid(_case_root):
		remove_child(_case_root)
		_case_root.free()
	_case_root = null


## 用例边界：释放上一用例全部夹具（resource_node 组是全局查询面，
## 容器 free 时组员自动出组），开新容器
func _new_case() -> void:
	_cleanup()
	_case_root = Node.new()
	_case_root.name = "CaseRoot"
	add_child(_case_root)


## 摆一个进了 resource_node 组的资源点桩（真类在 _ready 加组，桩需手动）
func _spawn_resource_node(fix: FakeResourceNode) -> FakeResourceNode:
	_spawn(fix)
	fix.add_to_group("resource_node")
	return fix


# ─────────────────────────────── 夹具 ────────────────────────────────

## 挂进局部树（get_tree()/组查询可用），测试尾统一清理
func _spawn(fix: Node) -> Node:
	_case_root.add_child(fix)
	return fix


## 建一个采集行为夹具：实体在原点，返回 {behavior, entity}
func _make_harvest(profession_id: String) -> Dictionary:
	var e := FakeEntity.new()
	e._profession_id = profession_id
	_spawn(e)
	var b: Node = ScriptBehaviorHarvest.new()
	b.entity = e
	_spawn(b)
	return {"behavior": b, "entity": e}


## 构造职业档案覆盖（不入全局配置）
func _prof(over: Dictionary) -> Dictionary:
	var base := {
		"id": "test", "product": "res_wood", "produce_amount": 20.0,
		"consume_res": "", "consume_amount": 0.0, "cycle": 5.0,
	}
	base.merge(over, true)
	return base


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_no_profession_finish() -> void:
	_new_case()
	# 裸实体（无 get_profession 方法）：行为 enter 安全 finish
	var bare := CharacterBody2D.new()
	_spawn(bare)
	var b: Node = ScriptBehaviorHarvest.new()
	b.entity = bare
	b.enter("", {})
	_runner.assert_true(b.is_finished(), "无职业协议实体 enter 即 finish")
	# 待业实体（职业空串）：同样 finish
	var e := FakeEntity.new()
	e._profession_id = ""
	_spawn(e)
	var b2: Node = ScriptBehaviorHarvest.new()
	b2.entity = e
	b2.enter("", {})
	_runner.assert_true(b2.is_finished(), "待业实体 enter 即 finish")


func _test_resource_cycle() -> void:
	_new_case()
	var fx := _make_harvest("lumberjack")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	# 摆一棵 200px 外的树（寻位应命中）
	var tree := _spawn_resource_node(FakeResourceNode.new())
	tree.res_id = "res_wood"
	tree.stock = 100
	tree.position = Vector2(200, 0)
	_spawn(tree)
	var api := FakeResourcesApi.new()
	_spawn(api)
	b.resources_api = api
	# enter（params 档案覆盖：绕 TownLifeAPI，桩环境独立）
	b.enter("", {"profession": _prof({"product": "res_wood"})})
	_runner.assert_false(b.is_finished(), "寻位成功不 finish")
	_runner.assert_equal(b.get_mode_name(), "resource", "应进资源点模式")
	_runner.assert_true(b.get_target_node() == tree, "应寻到摆下的树")
	# 移动阶段：朝树走
	b.update(0.1)
	_runner.assert_gt(e.move_dirs.size(), 0, "移动阶段应发 ai_move")
	# 到位：进入劳作，一拍（cycle 5s）结算
	e.global_position = tree.global_position
	b.update(0.1)
	_runner.assert_true(b.is_working(), "到位后应进劳作阶段")
	# 进场帧只设拍计时（动画在拍首帧触发），补一帧越过拍点后一并断言
	_runner.assert_equal(e.attack_count, 0, "进场帧不立即挥击（拍首才触发）")
	b.update(5.0)  # 拍首 play_attack + 5s 拍点结算
	_runner.assert_gt(e.attack_count, 0, "劳作应触发 play_attack 动画钩子")
	_runner.assert_equal(tree.harvest_calls.size(), 1, "一拍应 harvest 一次")
	_runner.assert_equal(tree.harvest_calls[0], 20, "harvest 请求量 = produce_amount")
	_runner.assert_equal(api.produce_calls.size(), 1, "一拍应 produce 一次")
	if not api.produce_calls.is_empty():
		_runner.assert_equal(String(api.produce_calls[0][0]), "res_wood", "产物 id = 资源点 resource_id")
		_runner.assert_equal(float(api.produce_calls[0][1]), 20.0, "入账量 = 实际采得量")


func _test_resource_depleted_finish() -> void:
	_new_case()
	var fx := _make_harvest("lumberjack")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var tree := _spawn_resource_node(FakeResourceNode.new())
	tree.res_id = "res_wood"
	tree.stock = 20
	tree.position = Vector2(100, 0)
	_spawn(tree)
	b.resources_api = FakeResourcesApi.new()
	b.enter("", {"profession": _prof({})})
	e.global_position = tree.global_position
	b.update(0.1)      # 到位进劳作
	b.update(5.0)      # 第一拍：harvest 20 → stock 0 → 枯竭
	_runner.assert_true(tree.is_depleted(), "20 储量一拍采空")
	# 采空后下一帧：重新寻位（无其他树）→ finish
	b.update(0.1)
	_runner.assert_true(b.is_finished(), "无可用资源点应 finish（决策层回 idle）")


func _test_worksite_conversion() -> void:
	_new_case()
	var fx := _make_harvest("blacksmith")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var api := FakeResourcesApi.new()
	api.stocks["res_metal_ore"] = 100.0
	_spawn(api)
	b.resources_api = api
	var smith: Dictionary = TownLifeAPI.get_profession("blacksmith")
	_runner.assert_false(smith.is_empty(), "blacksmith 档案应命中")
	b.enter("", {"profession": smith})
	_runner.assert_equal(b.get_mode_name(), "worksite", "铁匠应进工位模式")
	_runner.assert_false(b.is_finished(), "占位工位已配置，寻位成功")
	# 传送到工位（smithy_lv1 占位 X=1120，实体无 ground_y 属性 → 810+40）
	var site := Vector2(1120.0, 850.0)
	e.global_position = site
	b.update(0.1)
	_runner.assert_true(b.is_working(), "到位进劳作")
	b.update(4.0)  # cycle 4s 一拍
	_runner.assert_equal(api.consume_calls.size(), 1, "一拍应 consume 一次")
	if not api.consume_calls.is_empty():
		_runner.assert_equal(String(api.consume_calls[0][0]), "res_metal_ore", "消耗原料 = 矿")
		_runner.assert_equal(float(api.consume_calls[0][1]), 10.0, "消耗量 = consume_amount")
	_runner.assert_equal(api.produce_calls.size(), 1, "一拍应 produce 一次")
	if not api.produce_calls.is_empty():
		_runner.assert_equal(String(api.produce_calls[0][0]), "res_iron_ingot", "产出 = 铁锭")
		_runner.assert_equal(float(api.produce_calls[0][1]), 6.0, "产出量 = produce_amount")


func _test_worksite_no_material() -> void:
	_new_case()
	var fx := _make_harvest("blacksmith")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var api := FakeResourcesApi.new()
	api.stocks["res_metal_ore"] = 0.0
	_spawn(api)
	b.resources_api = api
	b.enter("", {"profession": TownLifeAPI.get_profession("blacksmith")})
	e.global_position = Vector2(1120.0, 850.0)
	b.update(0.1)
	b.update(4.0)
	_runner.assert_equal(api.consume_calls.size(), 1, "空库存仍会尝试 consume")
	_runner.assert_equal(api.produce_calls.size(), 0, "原料不足不产出")
	_runner.assert_false(b.is_finished(), "空拍等待不结束行为（矿工供给后自动恢复）")


func _test_unknown_worksite_finish() -> void:
	_new_case()
	var fx := _make_harvest("test")
	var b: Node = fx["behavior"]
	b.enter("", {"profession": _prof({"work_site_def": "no_such_shop"})})
	_runner.assert_true(b.is_finished(), "占位表未覆盖的工位 finish（批次 3 WorkSlots 接管）")


func _test_resource_node_regen() -> void:
	_new_case()
	var rn: ResourceNode = ScriptResourceNode.new()
	rn.resource_type = ScriptResourceNode.ResourceType.METAL
	rn.amount = 3
	rn.position = Vector2(9999, 9999)  # 远离原点，避免与真实场景资源点混淆
	_spawn(rn)
	_runner.assert_false(rn.is_depleted(), "初始非枯竭")
	var gained: int = rn.harvest(5)
	_runner.assert_equal(gained, 3, "超量采集得余量 3")
	_runner.assert_true(rn.is_depleted(), "采空转枯竭")
	_runner.assert_false(rn.visible, "枯竭隐藏")
	_runner.assert_true(rn._regen_timer != null, "枯竭应挂重生倒计时")
	_runner.assert_approx(rn._regen_timer.wait_time, ScriptResourceNode.REGEN_TIME, 0.001,
			"重生节拍 = REGEN_TIME 常量")
	_runner.assert_equal(rn.harvest(1), 0, "枯竭态不可采")
	# 手动触发重生（不真等 90s）：状态翻转回满
	rn._regrow()
	_runner.assert_false(rn.is_depleted(), "重生解除枯竭")
	_runner.assert_true(rn.visible, "重生恢复可见")
	_runner.assert_equal(rn.amount, 3, "重生存量回满")
	# harvest 带 12% 暴击（随机 ×2），断言放宽到 [1,2]
	var regained: int = rn.harvest(1)
	_runner.assert_true(regained >= 1 and regained <= 2, "重生后可再采（暴击 ×2 波动），实得 %d" % regained)
