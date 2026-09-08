extends Node
## 单元测试：工作场所运转（小镇生活批次 3）——WorkSlots 消费 / 占位降级 /
## 工作-休息节律 / 村民 wander 作用域。
##
## 覆盖面：
##   - 节律边界（is_work_time 显式注入 7/19 端点 + 全局 game_time 注入/恢复）
##   - get_work_site：真建筑 WorkSlots 最近槽位命中；无建筑/被毁/def 不匹配
##     降级占位工位；空 def 返回 {}
##   - count_work_capacity（批次 4）：真建筑槽位累计 / 被毁不计数 / 占位兜底
##   - Building 集成面：程序化建筑进 "building" 组 + WorkSlot marker 收集
##   - BehaviorHarvest 工位分支：真槽位寻位 / 劳作中建筑被毁重寻位（降级占位）
##   - BehaviorHarvest 征用收工（批次 4）：劳作中职业清空即时收工
##   - AIController：_is_villager 过滤（批次 4 改身份标志+不在编队判定）+
##     idle 完成 wander 概率（待业村民也闲逛；无标志战斗单位语义不变）+
##     节律挡采集
##
## batch 准入：建筑用真 Building（程序化 Interior/WorkSlots，进局部树触发
## _ready；无 Exterior 仅 warning）；实体/资源点走鸭子协议桩。
## ⚠️ 准入豁免说明：节律数据源是 WorldState.game_time（autoload 只读 + 测试
## 写入注入）。写入前后逐用例快照恢复（_saved_game_time / _end_case），照
## batch_runner._run_one 恢复 TimeManager 的先例；批次 2 起 BehaviorHarvest
## 行为层本就只读 WorldState，纯读不违反隔离语义。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")
const ScriptBehaviorHarvest := preload("res://modules/units/scripts/ai/behavior_harvest.gd")
const ScriptBehaviorWander := preload("res://modules/units/scripts/ai/behavior_wander.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")

signal test_done(code: int)

var _runner: TestRunner
## 当前用例的夹具容器（换用例即 free——组员随树退出自动出组，无跨用例泄漏）
var _case_root: Node = null
## 进入用例前的全局时间快照（节律用例改 WorldState.game_time，退出恢复，
## 防 batch_runner 单进程内污染后续套件）
var _saved_game_time: float = 0.0


# ─────────────────────────────── 测试桩 ────────────────────────────────

## 实体桩：鸭子协议（职业/移动/地面线），可在局部树内取 get_tree()
class FakeEntity extends CharacterBody2D:
	var _profession_id: String = ""
	var move_dirs: Array = []
	var attack_count: int = 0
	# wander 边界规避/锚点用地图约束（鸭子属性）
	var map_left: float = -2160.0
	var map_right: float = 2160.0
	var ground_y: float = 810.0
	var ground_bottom: float = 1080.0
	var foot_offset: float = 0.0

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


## 资源点桩：鸭子协议（寻位扫描面用）
class FakeResourceNode extends Node2D:
	var res_id: String = "res_wood"
	var stock: int = 100
	var depleted: bool = false

	func get_resource_id() -> String:
		return res_id

	func harvest(qty: int) -> int:
		if depleted:
			return 0
		var gained: int = mini(qty, stock)
		stock -= gained
		if stock <= 0:
			depleted = true
		return gained

	func is_depleted() -> bool:
		return depleted


## ResourcesApi 桩：记录流水
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


## 完整决策桩：AIController（真状态机）+ 村民标志实体，进局部树跑全链路决策
class DecisionFixture extends CharacterBody2D:
	var profession_id: String = ""
	var is_villager: bool = false
	var _fs: Node = null

	func get_profession() -> String:
		return profession_id

	func ai_move(_dir: Vector2, _run: bool = false) -> void:
		pass

	func ai_stop() -> void:
		pass

	func play_attack() -> void:
		pass

	func set_action_progress(_r: float) -> void:
		pass

	func hide_action_progress() -> void:
		pass

	func get_formation_system() -> Node:
		return _fs


## 编队系统桩：只答 is_in_squad（_is_villager 的"不在编队"过滤面）
class FakeSquadFS extends Node:
	var member: Node = null

	func is_in_squad(u: Node) -> bool:
		return u == member


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("节律: is_work_time 端点边界（显式注入）", _test_work_time_endpoints)
	_runner.add_test("节律: 全局 game_time 注入与恢复", _test_work_time_global)
	_runner.add_test("WorkSlots: 程序化建筑进组 + marker 收集", _test_building_group)
	_runner.add_test("WorkSlots: 双建筑最近槽位命中", _test_nearest_slot)
	_runner.add_test("WorkSlots: 无建筑/被毁/def 不匹配降级占位", _test_fallback_placeholder)
	_runner.add_test("Harvest 工位: 真槽位寻位与劳作结算", _test_harvest_real_slot)
	_runner.add_test("Harvest 工位: 劳作中建筑被毁降级占位", _test_harvest_building_demolished)
	_runner.add_test("Harvest 征用: 劳作中职业清空即时收工", _test_requisition_finishes_harvest)
	_runner.add_test("配比容量: 真建筑槽位累计/被毁不计数/全毁降级", _test_count_capacity_real_buildings)
	_runner.add_test("wander 锚点: 超锚回归（批次 4 待业闲逛不出村）", _test_wander_anchor_pullback)
	_runner.add_test("决策: _is_villager 身份标志过滤（批次 4）", _test_is_villager)
	_runner.add_test("决策: 节律挡采集（夜间 _try_harvest false）", _test_rhythm_blocks_harvest)
	_runner.add_test("决策: 村民 idle 完成 wander 概率（待业也闲逛）", _test_villager_wander)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	# 全局时间恢复（节律用例可能改过；0 = 未初始化哨兵，行为等同无节律环境）
	WorldState.game_time = _saved_game_time
	if _case_root != null and is_instance_valid(_case_root):
		remove_child(_case_root)
		_case_root.free()
	_case_root = null


func _new_case() -> void:
	_cleanup()
	_saved_game_time = WorldState.game_time
	_case_root = Node.new()
	_case_root.name = "CaseRoot"
	add_child(_case_root)


## 用例退出（时间敏感用例后立刻恢复全局时间）
func _end_case() -> void:
	WorldState.game_time = _saved_game_time


func _spawn(fix: Node) -> Node:
	_case_root.add_child(fix)
	return fix


## 程序化一栋运营中建筑：真 Building + Interior/WorkSlots/Marker2D（真类进
## "building" 组，marker 收集走 _ready）
func _make_building(def_id: String, origin: Vector2, slot_offsets: Array) -> Building:
	var b: Building = ScriptBuilding.new()
	b.def_id = def_id
	b.position = origin
	var interior := Node2D.new()
	interior.name = "Interior"
	b.add_child(interior)
	var slots := Node2D.new()
	slots.name = "WorkSlots"
	interior.add_child(slots)
	for i in slot_offsets.size():
		var m := Marker2D.new()
		m.position = slot_offsets[i]
		slots.add_child(m)
	_spawn(b)
	b.set_state(Building.State.OPERATIONAL)
	return b


## 建一个采集行为夹具：实体在原点，返回 {behavior, entity}
func _make_harvest(profession_id: String) -> Dictionary:
	var e := FakeEntity.new()
	e._profession_id = profession_id
	_spawn(e)
	var b: Node = ScriptBehaviorHarvest.new()
	b.entity = e
	_spawn(b)
	return {"behavior": b, "entity": e}


func _prof(over: Dictionary) -> Dictionary:
	var base := {
		"id": "test", "product": "res_iron_ingot", "produce_amount": 6.0,
		"consume_res": "res_metal_ore", "consume_amount": 10.0, "cycle": 4.0,
		"work_site_def": "smithy_lv1",
	}
	base.merge(over, true)
	return base


## 完整决策夹具：实体 + AIController（真状态机挂全行为）进局部树。
## villager: 是否打村民身份标志（批次 4 _is_villager 判定面）；
## in_squad: true 时挂编队桩（模拟被征用编队中的状态）。
func _make_decision_world(profession_id: String, probability: float,
		villager: bool = true, in_squad: bool = false) -> Dictionary:
	var e := DecisionFixture.new()
	e.profession_id = profession_id
	e.is_villager = villager
	if in_squad:
		var fs := FakeSquadFS.new()
		fs.member = e
		_spawn(fs)
		e._fs = fs
	e.position = Vector2(0, 0)
	_spawn(e)
	var ai: Node = ScriptAIController.new()
	_spawn(ai)
	ai._entity = e
	ai._setup_state_machine()
	ai.villager_wander_probability = probability
	return {"entity": e, "ai": ai}


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_work_time_endpoints() -> void:
	_new_case()
	_runner.assert_true(ProfessionRegistry.is_work_time(7.0), "7:00 整应开工（含头）")
	_runner.assert_true(ProfessionRegistry.is_work_time(12.0), "正午在岗")
	_runner.assert_true(ProfessionRegistry.is_work_time(18.99), "18:59 仍在岗")
	_runner.assert_false(ProfessionRegistry.is_work_time(19.0), "19:00 整应收工（不含尾）")
	_runner.assert_false(ProfessionRegistry.is_work_time(23.0), "深夜休息")
	_runner.assert_false(ProfessionRegistry.is_work_time(3.0), "凌晨休息")
	_runner.assert_true(ProfessionRegistry.is_work_time(7.5 + 24.0), "跨天小时数取模（31.5=7:30 在岗）")
	_end_case()


func _test_work_time_global() -> void:
	_new_case()
	# 未初始化（game_time<=0）= 无节律环境，视为全天工作（既有路径零扰动）
	WorldState.game_time = 0.0
	_runner.assert_true(ProfessionRegistry.is_work_time(), "game_time 未初始化视为全天工作")
	WorldState.game_time = 12.0
	_runner.assert_true(ProfessionRegistry.is_work_time(), "全局 12:00 在岗")
	WorldState.game_time = 23.0
	_runner.assert_false(ProfessionRegistry.is_work_time(), "全局 23:00 休息")
	WorldState.game_time = 8.5
	_runner.assert_true(TownLifeAPI.is_work_time(), "API 转发同语义")
	_end_case()


func _test_building_group() -> void:
	_new_case()
	var b := _make_building("smithy_lv1", Vector2(500, 0), [Vector2(-40, 20)])
	_runner.assert_true(b.is_in_group("building"), "Building._ready 应进 building 组")
	_runner.assert_true(b.is_operational(), "set_state 后运营中")
	_runner.assert_equal(b.get_work_slot_positions().size(), 1, "marker 收集 1 槽位")
	_runner.assert_approx(b.get_work_slot_positions()[0].x, 460.0, 0.01,
			"槽位世界坐标 = 建筑原点 + marker 偏移")
	_end_case()


func _test_nearest_slot() -> void:
	_new_case()
	var e := FakeEntity.new()
	e.position = Vector2(0, 0)
	_spawn(e)
	# 近建筑槽位 180 / 远建筑槽位 600：应命中近者
	_make_building("smithy_lv1", Vector2(600, 0), [Vector2(-420, 0)])
	_make_building("smithy_lv1", Vector2(1000, 0), [Vector2(-400, 0)])
	var site: Dictionary = ProfessionRegistry.get_work_site(e, "smithy_lv1")
	_runner.assert_false(site.is_empty(), "有匹配建筑应命中")
	if site.is_empty():
		return
	var pos: Vector2 = site["pos"]
	_runner.assert_approx(pos.x, 180.0, 0.01, "应取最近建筑的槽位 X=180")
	_runner.assert_true(site["building"] != null, "真槽位应携带建筑引用")
	_runner.assert_true(is_nan(pos.y), "pos.y 恒 NAN（由行为按实体地面线补齐的约定）")
	_end_case()


func _test_fallback_placeholder() -> void:
	_new_case()
	var e := FakeEntity.new()
	e.position = Vector2(0, 0)
	_spawn(e)
	# 1) 无建筑：降级占位工位（smithy_lv1 = 1120，building=null）
	var s1: Dictionary = TownLifeAPI.get_work_site(e, "smithy_lv1")
	_runner.assert_false(s1.is_empty(), "无建筑降级占位不应为空")
	_runner.assert_approx(float((s1.get("pos", Vector2()) as Vector2).x), 1120.0, 0.01,
			"占位工位 X=1120")
	_runner.assert_true(s1.get("building", null) == null, "占位工位 building=null")
	# 2) 建筑被毁（DESTROYED）：跳过，降级占位
	var dead := _make_building("smithy_lv1", Vector2(100, 0), [Vector2.ZERO])
	dead.set_state(Building.State.DESTROYED)
	var s2: Dictionary = ProfessionRegistry.get_work_site(e, "smithy_lv1")
	_runner.assert_approx(float((s2.get("pos", Vector2()) as Vector2).x), 1120.0, 0.01,
			"被毁建筑不供位，降级占位")
	# 3) def 不匹配：降级占位
	_make_building("warehouse", Vector2(50, 0), [Vector2.ZERO])
	var s3: Dictionary = ProfessionRegistry.get_work_site(e, "smithy_lv1")
	_runner.assert_approx(float((s3.get("pos", Vector2()) as Vector2).x), 1120.0, 0.01,
			"def 不匹配不供位")
	# 4) 空 def：返回 {}（资源点模式不走本入口，防御）
	_runner.assert_true(ProfessionRegistry.get_work_site(e, "").is_empty(), "空 def 返回空")
	# 5) 占位表未覆盖的 def 且无建筑：空
	_runner.assert_true(ProfessionRegistry.get_work_site(e, "no_such_shop").is_empty(),
			"无建筑且占位未覆盖返回空")
	_end_case()


func _test_harvest_real_slot() -> void:
	_new_case()
	var fx := _make_harvest("blacksmith")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var api := FakeResourcesApi.new()
	api.stocks["res_metal_ore"] = 100.0
	_spawn(api)
	b.resources_api = api
	# 槽位 X=460（区别于占位 1120），验证真槽位消费
	var shop := _make_building("smithy_lv1", Vector2(500, 0), [Vector2(-40, 0)])
	b.enter("", {"profession": _prof({})})
	_runner.assert_false(b.is_finished(), "有真建筑槽位寻位成功")
	_runner.assert_equal(b.get_mode_name(), "worksite", "应进工位模式")
	var hv: Node = b
	_runner.assert_true(hv.get_worksite_building() == shop, "应携带工位建筑引用")
	# 移动阶段：朝槽位走
	b.update(0.1)
	_runner.assert_gt(e.move_dirs.size(), 0, "应朝槽位移动")
	# 传送到槽位（Y = 默认地面线 810 + 40）
	e.global_position = Vector2(460.0, 850.0)
	b.update(0.1)
	_runner.assert_true(b.is_working(), "到位进劳作")
	b.update(4.0)
	_runner.assert_equal(api.consume_calls.size(), 1, "一拍 consume 矿")
	_runner.assert_equal(api.produce_calls.size(), 1, "一拍 produce 锭")
	_end_case()


func _test_harvest_building_demolished() -> void:
	_new_case()
	var fx := _make_harvest("blacksmith")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var api := FakeResourcesApi.new()
	api.stocks["res_metal_ore"] = 100.0
	_spawn(api)
	b.resources_api = api
	var shop := _make_building("smithy_lv1", Vector2(500, 0), [Vector2(-40, 0)])
	b.enter("", {"profession": _prof({})})
	e.global_position = Vector2(460.0, 850.0)
	b.update(0.1)
	_runner.assert_true(b.is_working(), "到位进劳作")
	# 劳作中建筑被毁：下一帧重寻位（无其他建筑）→ 降级占位 X=1120
	shop.demolish()
	_runner.assert_false(shop.is_operational(), "拆毁后非运营态")
	b.update(0.1)
	_runner.assert_false(b.is_finished(), "降级占位后行为应继续（换工位不打断营业）")
	var hv: Node = b
	_runner.assert_true(hv.get_worksite_building() == null, "降级后无建筑引用（占位）")
	e.global_position = Vector2(1120.0, 850.0)
	b.update(0.1)
	_runner.assert_true(b.is_working(), "占位工位继续劳作")
	_end_case()


func _test_is_villager() -> void:
	_new_case()
	# 批次 4 语义：村民身份标志（is_villager）+ 不在编队，与职业解耦
	var w := _make_decision_world("blacksmith", 0.0)
	var ai: Node = w["ai"]
	_runner.assert_true(ai._is_villager(), "村民标志+有职业应判村民")
	var w2 := _make_decision_world("", 0.0)
	_runner.assert_true((w2["ai"] as Node)._is_villager(),
			"村民标志+待业仍是村民（批次 4：待业村民可闲逛）")
	# 无标志 + 待业 = 战斗/敌方单位（批次 3 语义保持：不 wander）
	var w3 := _make_decision_world("", 0.0, false)
	_runner.assert_false((w3["ai"] as Node)._is_villager(), "无标志实体不判村民（战斗/敌方）")
	# 村民被征用编队中：不判村民（战斗待命语义）
	var w4 := _make_decision_world("", 0.0, true, true)
	_runner.assert_false((w4["ai"] as Node)._is_villager(), "编队中的前村民不判村民（征用互斥）")
	# 无 get_profession 方法的裸实体不判村民
	var bare := CharacterBody2D.new()
	_spawn(bare)
	var ai5: Node = ScriptAIController.new()
	_spawn(ai5)
	ai5._entity = bare
	_runner.assert_false(ai5._is_villager(), "无职业协议实体不判村民")
	_end_case()


func _test_rhythm_blocks_harvest() -> void:
	_new_case()
	WorldState.game_time = 23.0  # 夜间
	var w := _make_decision_world("blacksmith", 1.0)
	var ai: Node = w["ai"]
	_runner.assert_false(ai._try_harvest(), "夜间不应进采集（节律挡）")
	WorldState.game_time = 12.0  # 白天：会尝试 travel harvest（有职业+无编队）
	_runner.assert_true(ai._try_harvest(), "白天有职业应可进采集")
	_end_case()


func _test_villager_wander() -> void:
	_new_case()
	WorldState.game_time = 23.0  # 夜间（排除 harvest 干扰，纯看 idle→wander）
	# 村民（在职）+ 概率 1.0：idle 完成必 wander
	var w := _make_decision_world("blacksmith", 1.0)
	var ai: Node = w["ai"]
	_runner.assert_equal(_finish_idle_and_decide(ai), "wander",
			"在职村民 idle 完成（概率 1.0）应 wander")
	# 村民（待业，批次 4）+ 概率 1.0：同样闲逛（待业池语义 = 村内 wander）
	var w2 := _make_decision_world("", 1.0)
	var ai2: Node = w2["ai"]
	_runner.assert_equal(_finish_idle_and_decide(ai2), "wander",
			"待业村民 idle 完成（概率 1.0）应 wander（批次 4）")
	# 概率 0.0：保持 idle（不走 wander）
	var w3 := _make_decision_world("blacksmith", 0.0)
	var ai3: Node = w3["ai"]
	_runner.assert_equal(_finish_idle_and_decide(ai3), "idle", "概率 0.0 应保持 idle")
	# 无标志实体 + 概率 1.0：不 wander（战斗/敌方语义不变——批次 3 关键回归面）
	var w4 := _make_decision_world("", 1.0, false)
	var ai4: Node = w4["ai"]
	_runner.assert_equal(_finish_idle_and_decide(ai4), "idle",
			"无标志实体概率 1.0 也不 wander（语义不变）")
	# 被征用编队中的前村民 + 概率 1.0：不 wander（战斗待命语义）
	var w5 := _make_decision_world("", 1.0, true, true)
	var ai5: Node = w5["ai"]
	_runner.assert_equal(_finish_idle_and_decide(ai5), "idle",
			"编队中的前村民概率 1.0 也不 wander（征用互斥）")
	_end_case()


func _test_requisition_finishes_harvest() -> void:
	# 批次 4 编队征用互斥：劳作中的村民职业被清空 → 下一帧 update 即时收工
	_new_case()
	var fx := _make_harvest("blacksmith")
	var e: FakeEntity = fx["entity"]
	var b: Node = fx["behavior"]
	var api := FakeResourcesApi.new()
	api.stocks["res_metal_ore"] = 100.0
	_spawn(api)
	b.resources_api = api
	# 占位工位（无建筑环境）劳作中
	b.enter("", {"profession": _prof({})})
	e.global_position = Vector2(1120.0, 850.0)
	b.update(0.1)
	_runner.assert_true(b.is_working(), "占位工位进劳作")
	# 征用：FormationSystem 置空职业（duck 协议同款操作）
	e._profession_id = ""
	b.update(0.1)
	_runner.assert_true(b.is_finished(), "职业清空后劳作即时收工（征用互斥）")
	_end_case()


func _test_count_capacity_real_buildings() -> void:
	# 批次 4：真建筑槽位累计容量；被毁建筑不计数（全毁降级占位兜底 1）
	_new_case()
	var e := FakeEntity.new()
	e.position = Vector2(0, 0)
	_spawn(e)
	_make_building("smithy_lv1", Vector2(500, 0), [Vector2(-40, 0), Vector2(40, 0)])
	_make_building("smithy_lv1", Vector2(1000, 0), [Vector2(0, 0)])
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, "smithy_lv1"), 3,
			"双建筑槽位累计容量 3")
	# 一栋被毁：剩 1 槽 > 0，仍按真槽位计数（不叠加占位）
	# （占位兜底只在真容量为 0 时生效）
	var shops: Array = e.get_tree().get_nodes_in_group("building")
	var first: Node = shops[0]
	first.set_state(Building.State.DESTROYED)
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, "smithy_lv1"), 1,
			"被毁建筑不供位，剩 1 槽")
	# 全毁：降级占位兜底容量 1
	for b in shops:
		b.set_state(Building.State.DESTROYED)
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, "smithy_lv1"), 1,
			"全毁降级占位兜底容量 1")
	_end_case()


func _test_wander_anchor_pullback() -> void:
	# 批次 4：待业村民全天 wander 无锚会累积漂出村子（实测漂到 -2900，
	# 超出 village_a 地图边界 -2160）——锚点参数应把超锚闲逛拉回
	_new_case()
	var e := FakeEntity.new()
	e.position = Vector2(2000.0, 900.0)  # 锚 0 右侧 2000px，超出默认半径 640
	_spawn(e)
	var w: Node = ScriptBehaviorWander.new()
	w.entity = e
	_spawn(w)
	w.enter("", {"anchor_x": 0.0})
	# 跑若干帧：驱动方向应被拉回（dir.x 朝锚为负）
	var pulled := false
	for i in 30:
		w.update(0.1)
		if e.move_dirs.size() > 0:
			var d: Vector2 = e.move_dirs[e.move_dirs.size() - 1]
			if d.x < 0.0:
				pulled = true
				break
	_runner.assert_true(pulled, "超出锚点半径时 wander 应朝锚方向拉回")
	# 无锚（原语义）：不带 anchor_x 参数时不炸（行为兼容）
	var e2 := FakeEntity.new()
	e2.position = Vector2(2000.0, 900.0)
	_spawn(e2)
	var w2: Node = ScriptBehaviorWander.new()
	w2.entity = e2
	_spawn(w2)
	w2.enter("", {})
	w2.update(0.1)
	_runner.assert_true(is_nan(w2._anchor_x), "无锚参数保持原语义（_anchor_x = NAN）")
	_end_case()


## 把夹具的 idle 行为置为即刻完成并跑一轮决策，返回当前行为名
func _finish_idle_and_decide(ai: Node) -> String:
	var sm: Node = ai.get_state_machine()
	sm.travel("idle")
	var idle: Node = sm.get_node_or_null("BehaviorIdle")
	if idle != null:
		idle.set("_duration", 0.0)
		idle.update(0.1)
	ai._make_decision()
	return ai.get_current_behavior()
