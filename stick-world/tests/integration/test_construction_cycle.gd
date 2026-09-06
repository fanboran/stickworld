extends Node
## 集成测试：建造循环（选址→派工→建造→完工→注册）。
## fixture：真 village_a.tscn + ConstructionManager，不用 GameRoot。
## 用例间共享 fixture（_map/_cm 惰性初始化一次），但各用例断言独立主题；
## 用例自清理：开工不收尾的项目须 cancel（try_assign 按列表序先到先得，
## PLANNED 残留项目会劫持后续用例派工），工人用毕注销，测试实体用毕移除。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
# audit-exempt: headless 防御性路径 preload；Building 为 building_gen 对外公共类型
# （building_gen/api.gd 已声明契约），此处经全局类名判型会依赖 class_name 注册时序
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")
const MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/village_a.tscn")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

var _runner: TestRunner
var _map: Node2D = null
var _cm: Node = null


class FakeResourcesApi:
	extends Node
	var fail_consume: bool = false
	var stock: float = 1000.0
	var consumed_total: float = 0.0

	func get_stock(_res_id: String, _region_id: String = "") -> float:
		return stock

	func consume(_res_id: String, _amount: float, _region_id: String = "", _reason: String = "") -> Dictionary:
		if fail_consume:
			return {"ok": false, "error": "库存不足", "available": 0.0}
		consumed_total += _amount
		return {"ok": true, "amount": _amount}

	func produce(_res_id: String, _amount: float, _region_id: String = "", _source: String = "") -> Dictionary:
		return {"ok": true}


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("建造: 未设地图时开工返回失败", _test_no_map, true)
	_runner.add_test("建造: 未注册建筑类型返回失败", _test_unregistered_def, true)
	_runner.add_test("建造: 完整循环（开工→派工→材料→敲击→完工注册）", _test_full_cycle, true)
	_runner.add_test("建造: 资源不足时开工失败", _test_insufficient_resources, true)
	_runner.add_test("建造: 成功建造时按成本扣减资源（2026-08 回归：注入点曾缺失）", _test_resources_consumed, true)
	_runner.add_test("建造: 选址范围内有实体时拒绝放置（防人进建筑被卡）", _test_entity_blocking, true)
	_runner.add_test("建造: 脱离卡死随机传送到空旷地带", _test_escape_stuck, true)
	_runner.add_test("建造: 完工建筑登记与查询", _test_building_registry, true)
	_runner.add_test("建造: apply_building_def 对 Excel 空单元格 null 字段容忍（2026-09 回归：String(null) 构造崩）", _test_apply_def_null_fields, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


## 惰性初始化：加载地图 + 装配 ConstructionManager
func _ensure_setup() -> void:
	if _map != null:
		return
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	var ok: bool = await TestHelpers.await_condition(
		func(): return _map.get("placement_grid") != null and _map.get("building_host") != null,
		5.0, "村落地图就绪"
	)
	if not ok:
		_runner.assert_true(false, "村落地图未就绪")
		return
	_cm = ScriptConstructionManager.new()
	_cm.name = "TestConstructionManager"
	add_child(_cm)
	_cm.set_map(_map)
	# 等待 _ready 完成默认场景注册
	await TestHelpers.await_condition(
		func(): return _cm.is_building_registered("placeholder"),
		3.0, "默认建筑场景注册"
	)


func _worker() -> Node:
	var w := Node.new()
	w.name = "TestWorker"
	return w


## 清理用例残留的未完工项目（用例间共享 _cm 夹具的顺序依赖防护）。
## WorkCrewAssigner.try_assign 按 _projects 列表序先到先得派工
## （work_crew_assigner.gd try_assign），前一用例开工后不收尾的 PLANNED 项目
## 会劫持后一用例的 try_assign（工人被派去建残留项目而非本用例项目）。
## 经 assigner 黑盒取项目对象：注册一次性工人派工即得；
## 调用方须保证此刻该残留项目是唯一接受派工的项目（前序用例均已清理）。
func _cancel_leftover_project(project_id: String) -> void:
	if project_id.is_empty():
		_runner.assert_true(false, "清理失败：project_id 为空")
		return
	var worker := _worker()
	_cm.register_worker(worker)
	if not _cm.try_assign_worker(worker):
		_runner.assert_true(false, "清理失败：无项目可派工（应派到 %s）" % project_id)
		_cm.unregister_worker(worker)
		return
	var project: ScriptConstructionProject = _cm.get_assigner().get_worker_project(worker) as ScriptConstructionProject
	if project == null or project.project_id != project_id:
		var got: String = project.project_id if project != null else "null"
		_runner.assert_true(false, "清理失败：try_assign 派到 %s 而非 %s（前序用例残留未清？）" % [got, project_id])
		_cm.unregister_worker(worker)
		return
	project.cancel()
	_cm.unregister_worker(worker)


func _test_no_map() -> void:
	var cm := ScriptConstructionManager.new()
	var r: Dictionary = cm.start_construction_at("r1", "placeholder", 12)
	_runner.assert_false(r.get("ok", true), "无地图应失败")
	_runner.assert_not_equal(r.get("error", ""), "", "应带错误信息")


func _test_unregistered_def() -> void:
	await _ensure_setup()
	var r: Dictionary = _cm.start_construction_at("r1", "nonexistent", 12)
	_runner.assert_false(r.get("ok", true), "未注册类型应失败")
	_runner.assert_true(str(r.get("error", "")).contains("未注册"), "错误应指明未注册")


func _test_full_cycle() -> void:
	await _ensure_setup()
	var start: Dictionary = _cm.start_construction_at("r1", "placeholder", 14)
	_runner.assert_true(start.get("ok", false), "开工应成功")
	var project_id: String = start.get("project_id", "")
	_runner.assert_not_equal(project_id, "", "应有 project_id")
	# PLANNED -> 派工 -> UNDER_CONSTRUCTION
	var st: Dictionary = _cm.get_project_state(project_id)
	_runner.assert_equal(st.get("state", -1), ScriptConstructionProject.State.PLANNED, "未派工应为 PLANNED")
	var worker := _worker()
	_cm.register_worker(worker)
	_runner.assert_true(_cm.try_assign_worker(worker), "派工应成功")
	st = _cm.get_project_state(project_id)
	_runner.assert_equal(st.get("state", -1), ScriptConstructionProject.State.UNDER_CONSTRUCTION, "派工后应为 UNDER_CONSTRUCTION")
	_runner.assert_equal(st.get("worker_count", 0), 1, "派工 1 人")
	# 双进度：先满材料，再敲击建造
	var project: RefCounted = _cm.get_assigner().get_worker_project(worker)
	_runner.assert_not_null(project, "工人应有项目")
	project.deliver_material(1.0)
	project.add_build_progress(float(project.total_work))
	st = _cm.get_project_state(project_id)
	_runner.assert_equal(st.get("state", -1), ScriptConstructionProject.State.OPERATIONAL, "完工后应 OPERATIONAL")
	_runner.assert_equal(st.get("progress", 0.0), 1.0, "进度应为 1")
	# 清理：完工后工人回空闲池，注销防残留（残留空闲工人会污染后续用例的派工前提）
	_cm.unregister_worker(worker)


func _test_insufficient_resources() -> void:
	await _ensure_setup()
	# 黑盒注入（走 set_resources_api 注入点，2026-08 回归验证）+ 库存为 0 的 fake api
	_cm.set_building_def("placeholder", {"build_cost_wood": 10.0})
	var fake := FakeResourcesApi.new()
	fake.fail_consume = true
	fake.stock = 0.0
	_cm.set_resources_api(fake)
	var r: Dictionary = _cm.start_construction_at("r1", "placeholder", 120)
	_runner.assert_false(r.get("ok", true), "资源不足应失败")
	_runner.assert_true(str(r.get("error", "")).contains("资源不足"), "错误应指明资源不足，实际: %s" % r.get("error", ""))
	_cm.set_resources_api(null)
	_cm.clear_building_def("placeholder")


func _test_resources_consumed() -> void:
	await _ensure_setup()
	# 库存充足时建造成功，且按成本实际扣减（2026-08 修复：注入点缺失导致永久免费建造）
	_cm.set_building_def("placeholder", {"build_cost_wood": 10.0, "build_cost_stone": 5.0})
	var fake := FakeResourcesApi.new()
	fake.stock = 1000.0
	_cm.set_resources_api(fake)
	var r: Dictionary = _cm.start_construction_at("r1", "placeholder", 40)
	_runner.assert_true(r.get("ok", false), "资源充足应开工成功: " + str(r))
	_runner.assert_equal(fake.consumed_total, 15.0, "应按成本扣减 wood10+stone5=15，实际: %s" % fake.consumed_total)
	_cm.set_resources_api(null)
	_cm.clear_building_def("placeholder")
	# 清理：本用例开工的项目不收尾会以 PLANNED 残留（接受派工），
	# 劫持后续用例的 try_assign（按列表序先到先得）
	_cancel_leftover_project(str(r.get("project_id", "")))


func _test_building_registry() -> void:
	await _ensure_setup()
	# 本用例自建项目验证登记（不依赖 _test_full_cycle 的残留建筑满足断言）
	var start: Dictionary = _cm.start_construction_at("r1", "placeholder", 30)
	_runner.assert_true(start.get("ok", false), "开工应成功: %s" % start.get("error", ""))
	var project_id: String = str(start.get("project_id", ""))
	var worker := _worker()
	_cm.register_worker(worker)
	_runner.assert_true(_cm.try_assign_worker(worker), "派工应成功")
	var project: RefCounted = _cm.get_assigner().get_worker_project(worker)
	_runner.assert_not_null(project, "工人应有项目")
	# 顺序依赖防护：try_assign 按项目列表序先到先得，若前序用例残留
	# PLANNED 项目，工人会被派去建残留项目而非本用例项目（曾发生：
	# 资源/实体阻挡用例的残留项目劫持派工，完工的是残留项目）
	if project != null:
		_runner.assert_equal(str(project.get("project_id")), project_id, "工人应派到本用例项目")
	project.deliver_material(1.0)
	project.add_build_progress(float(project.total_work))
	var my_state: Dictionary = _cm.get_project_state(project_id)
	_runner.assert_equal(my_state.get("state", -1), ScriptConstructionProject.State.OPERATIONAL, "本用例项目应完工登记")
	var buildings: Array = _cm.get_buildings_in_region("r1")
	_runner.assert_true(buildings.size() >= 1, "应有已完工建筑登记")
	var found: bool = false
	for bid in buildings:
		var bs: Dictionary = _cm.get_building_state(bid)
		if bs.get("state", -1) == ScriptBuilding.State.OPERATIONAL:
			found = true
			break
	_runner.assert_true(found, "至少一栋建筑为 OPERATIONAL")
	# 清理：工人注销防残留
	_cm.unregister_worker(worker)


func _test_apply_def_null_fields() -> void:
	# 复现 buildings.tres 真实形态（Excel 管线：空单元格导出为 null，key 在、值为 null）。
	# 2026-09 回归：四表重导后 null 字段引爆 String/int/bool(null) 的
	# Nonexistent constructor，读档 spawn 初始草棚即崩
	var def := {
		"interior_mode": 0,
		"mega_interior_map_id": null,
		"wall_tier": null,
		"can_stand_on": null,
		"is_gate": null,
		"max_hp": 100,
	}
	var b := ScriptBuilding.new()
	add_child(b)
	b.apply_building_def(def)
	_runner.assert_true(b.mega_interior_map_id == "", "null mega_interior_map_id 回退空串（实测 %s）" % b.mega_interior_map_id)
	_runner.assert_true(b.wall_tier == 0, "null wall_tier 回退 0（实测 %d）" % b.wall_tier)
	_runner.assert_true(not b.can_stand_on, "null can_stand_on 回退 false")
	_runner.assert_true(not b.is_gate, "null is_gate 回退 false")
	_runner.assert_true(is_equal_approx(b.max_health, 100.0), "max_hp 正常取值 100（实测 %f）" % b.max_health)
	# 正常值路径不受影响
	b.apply_building_def({"interior_mode": 2, "mega_interior_map_id": "mega_01",
			"wall_tier": 2, "can_stand_on": true, "is_gate": true, "max_hp": 800})
	_runner.assert_true(b.mega_interior_map_id == "mega_01", "字符串值正常应用（实测 %s）" % b.mega_interior_map_id)
	_runner.assert_true(b.wall_tier == 2 and b.can_stand_on and b.is_gate, "城墙字段正常应用")
	_runner.assert_true(is_equal_approx(b.max_health, 800.0), "max_hp 覆盖应用（实测 %f）" % b.max_health)
	b.queue_free()


func _test_entity_blocking() -> void:
	await _ensure_setup()
	var cell_x := 50
	# 实体站在选址中心、建筑体 Y 范围内（根 y=800 → 脚部在建筑体区域）→ 应拒绝
	var e: Node2D = _map.spawn_entity(STICKMAN_SCENE, Vector2(float(cell_x) * 32.0 + 16.0 * 16.0, 800.0))
	_runner.assert_not_null(e, "实体应生成")
	if e == null:
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	# 有人挡着 → 预置建筑应拒绝
	var r: Dictionary = _cm.spawn_operational_building("warehouse", cell_x, 16)
	_runner.assert_false(r.get("ok", true), "范围内有实体应拒绝放置: %s" % r.get("error", ""))
	_runner.assert_true(str(r.get("error", "")).contains("单位"), "错误应指明有单位，实际: %s" % r.get("error", ""))
	# 开工建造同样拒绝（用同宽度验证）
	var r2: Dictionary = _cm.start_construction_at("r1", "warehouse", cell_x)
	_runner.assert_false(r2.get("ok", true), "范围内有实体应拒绝开工: %s" % r2.get("error", ""))
	# 实体移到建筑脚下空地（Y 更大，脚部在建筑体区域外）→ 不应再妨碍放置
	e.global_position = Vector2(float(cell_x) * 32.0 + 16.0 * 16.0, 960.0)
	await get_tree().physics_frame
	var r4: Dictionary = _cm.start_construction_at("r1", "warehouse", cell_x)
	_runner.assert_true(r4.get("ok", false), "实体在建筑脚下空地不应妨碍放置: %s" % r4.get("error", ""))
	# 实体彻底移走后 → 预置建筑成功
	e.global_position = Vector2(200.0, 900.0)
	await get_tree().physics_frame
	var r3: Dictionary = _cm.spawn_operational_building("placeholder", cell_x, 2)
	_runner.assert_true(r3.get("ok", false), "实体离开后应可放置: %s" % r3.get("error", ""))
	# 清理：r4 开工验证产生的项目以 PLANNED 残留（接受派工），取消之防劫持
	# 后续用例的 try_assign；测试实体也移出地图，不留共享夹具残留
	_cancel_leftover_project(str(r4.get("project_id", "")))
	e.queue_free()


func _test_escape_stuck() -> void:
	await _ensure_setup()
	# 建一栋仓库（宽 16，带 PassageBarrier）
	var r: Dictionary = _cm.spawn_operational_building("warehouse", 60, 16)
	_runner.assert_true(r.get("ok", false), "预置建筑成功: %s" % r.get("error", ""))
	if not r.get("ok", false):
		return
	var building: Node = _cm.get_building_node(r.get("building_id", ""))
	var pb := building.get_node_or_null("PassageBarrier") as StaticBody2D
	_runner.assert_not_null(pb, "仓库应有 PassageBarrier")
	if pb == null:
		return
	# 物理化后实体与建筑重叠会被物理推出（不会卡在建筑内），
	# 测试改为验证：物理查询语义（建筑内阻塞/建筑外空旷）+ 脱困传送
	var e: Node2D = _map.spawn_entity(STICKMAN_SCENE, Vector2(pb.global_position.x + 600.0, pb.global_position.y - 150.0))
	_runner.assert_not_null(e, "实体应生成")
	if e == null:
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	# 物理查询语义：建筑内位置应判定为阻塞
	var inside_pos: Vector2 = pb.global_position + Vector2(256.0, -150.0)
	_runner.assert_true(e.is_position_blocked(inside_pos), "建筑内位置应判定为阻塞")
	# 建筑外（右侧 600px 处）应空旷
	var outside_pos: Vector2 = pb.global_position + Vector2(600.0, -150.0)
	_runner.assert_false(e.is_position_blocked(outside_pos), "建筑外位置应判定为空旷")
	# 脱困：实体卡在建筑内（直接放置，同一帧内传送，物理还来不及推出）
	e.global_position = inside_pos
	e.escape_stuck()
	await get_tree().physics_frame
	_runner.assert_false(e.is_position_blocked(e.global_position), "脱困后应在空旷位置，x=%.0f" % e.global_position.x)
	# 脱困后位置应在地图范围内（没有飞出地图）
	var map_right: float = float(_map.map_right) if "map_right" in _map else 8192.0
	_runner.assert_true(e.global_position.x >= -50.0 and e.global_position.x <= map_right + 50.0,
		"脱困位置应在地图范围内，x=%.0f" % e.global_position.x)
	# 清理：测试实体移出共享夹具（地图），不留残留实体给后续用例
	e.queue_free()
