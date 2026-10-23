extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：Building 运行时实体（building_gen 模块）——状态机 / 伤害拆除 /
## 数据驱动 def / 工作位查询 / 碰撞几何 24px 迁移。
##
## 覆盖面：
##   - 状态迁移：state_changed/completed 信号语义（completed 只在进 OPERATIONAL
##     时发一次）、同值 set_state 零信号、各状态外观 modulate 档、视觉壳开关
##   - 伤害：半血线（<50% 才进 DAMAGED，且只从 OPERATIONAL 进）、归零自动拆除
##   - 拆除：demolished 信号携带自身引用、幂等（二次 demolish 不重发）
##   - 城墙：拆除时 PassageBarrier 隐身 + 碰撞延迟禁用（非城墙不受影响）
##   - apply_building_def：真实字段应用 + Excel 空单元格（null）安全回退
##   - 工作位：Interior/WorkSlots 与旧版根级 WorkSlots 双路径收集、
##     世界坐标、越界索引返回 null
##   - get_collision_bottom_local：矩形下边界公式
##   - 24px 碰撞迁移：共享子资源 duplicate 防双缩（双铁匠铺回归）+ meta 幂等
##
## batch 准入：fixture 全部用例自建自毁（_case_root 换用例即 free，建筑随树
## 退出自动出组）；无 autoload 触碰；唯一一次 await process_frame 是为 flush
## CollisionShape2D.set_deferred("disabled") 的延迟写（引擎确定性时序，非等就绪）。
## 注意：Building 的子节点引用在 _ready 时一次性收集——外观/挡板/工位等附加件
## 必须在 _spawn 入树前挂好。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")

var _runner: TestRunner
## 当前用例的夹具容器（换用例即 free——建筑随树退出自动出 "building" 组）
var _case_root: Node = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("状态: 迁移信号/外观档/视觉壳", _test_state_transitions)
	_runner.add_test("伤害: 半血线进 DAMAGED（仅从 OPERATIONAL）", _test_damage_half_threshold)
	_runner.add_test("伤害: 归零自动拆除 + demolish 幂等", _test_damage_demolish)
	_runner.add_test("城墙: 拆除禁用 PassageBarrier 碰撞", _test_wall_barrier_demolish, true)
	_runner.add_test("数据驱动: apply_building_def 字段应用与 null 回退", _test_apply_def)
	_runner.add_test("工作位: 双路径收集/世界坐标/越界索引", _test_work_slots)
	_runner.add_test("碰撞下边界: get_collision_bottom_local 公式", _test_collision_bottom)
	_runner.add_test("24px 迁移: 共享 shape 防双缩 + meta 幂等", _test_collision_migration)
	await _runner.run_async()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	if _case_root != null and is_instance_valid(_case_root):
		remove_child(_case_root)
		_case_root.free()
	_case_root = null


func _new_case() -> void:
	_cleanup()
	_case_root = Node.new()
	_case_root.name = "CaseRoot"
	add_child(_case_root)


func _spawn(fix: Node) -> Node:
	_case_root.add_child(fix)
	return fix


## 信号计数器（字典按引用捕获，lambda 内累加）
func _make_counter(b: Node) -> Dictionary:
	var cnt := {"changed": 0, "old": -1, "new": -1, "completed": 0, "demolished": 0}
	b.state_changed.connect(func(o: int, n: int) -> void:
		cnt["changed"] += 1
		cnt["old"] = o
		cnt["new"] = n)
	b.completed.connect(func(_b: Node) -> void: cnt["completed"] += 1)
	b.demolished.connect(func(_b: Node) -> void: cnt["demolished"] += 1)
	return cnt


# ─────────────────────────────── fixture 工厂（未入树，挂好子件再 _spawn）──

## 带外观容器的建筑（ColorRect 当 CanvasItem 桩，供状态 modulate 断言）
func _new_building(pos: Vector2 = Vector2.ZERO) -> Node:
	var b: Node = ScriptBuilding.new()
	var ext := ColorRect.new()
	ext.name = "Exterior"
	b.add_child(ext)
	b.position = pos
	return b


## 给建筑挂 PassageBarrier（StaticBody2D + 矩形 CollisionShape2D），返回碰撞形
func _attach_barrier(b: Node, body_pos: Vector2, size: Vector2) -> CollisionShape2D:
	var body := StaticBody2D.new()
	body.name = "PassageBarrier"
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	cs.shape = rect
	cs.position = body_pos
	body.add_child(cs)
	b.add_child(body)
	return cs


## 给建筑挂 WorkSlots（新路径 Interior/WorkSlots 或旧路径根级 WorkSlots）
func _attach_work_slots(b: Node, offsets: Array, interior_path: bool) -> Node2D:
	var slots := Node2D.new()
	slots.name = "WorkSlots"
	if interior_path:
		var interior := Node2D.new()
		interior.name = "Interior"
		b.add_child(interior)
		interior.add_child(slots)
	else:
		b.add_child(slots)
	for off: Vector2 in offsets:
		var m := Marker2D.new()
		m.position = off
		slots.add_child(m)
	return slots


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_state_transitions() -> void:
	_new_case()
	var b := _spawn(_new_building())
	var cnt := _make_counter(b)
	var ext: ColorRect = b.get_node("Exterior")
	# 初始 PLANNED：半透明
	_runner.assert_equal(b.state, ScriptBuilding.State.PLANNED, "初始 PLANNED")
	_runner.assert_approx(ext.modulate.a, 0.3, 0.001, "PLANNED 外观 alpha=0.3")
	# PLANNED → UNDER_CONSTRUCTION：state_changed 携带新旧值
	b.set_state(ScriptBuilding.State.UNDER_CONSTRUCTION)
	_runner.assert_equal(cnt["changed"], 1, "迁移发一次 state_changed")
	_runner.assert_equal(cnt["old"], ScriptBuilding.State.PLANNED, "old=PLANNED")
	_runner.assert_equal(cnt["new"], ScriptBuilding.State.UNDER_CONSTRUCTION, "new=UNDER_CONSTRUCTION")
	_runner.assert_approx(ext.modulate.a, 0.6, 0.001, "建造中 alpha=0.6")
	_runner.assert_true(b.is_under_construction(), "is_under_construction 命中")
	# → OPERATIONAL：completed 恰好一次
	b.set_state(ScriptBuilding.State.OPERATIONAL)
	_runner.assert_equal(cnt["completed"], 1, "进 OPERATIONAL 发 completed")
	_runner.assert_true(b.is_operational(), "is_operational 命中")
	_runner.assert_true(ext.modulate.is_equal_approx(Color.WHITE), "完工外观纯白")
	# 同值 set_state：零信号零副作用
	b.set_state(ScriptBuilding.State.OPERATIONAL)
	_runner.assert_equal(cnt["changed"], 2, "同值迁移不发信号（仅 PLANNED→UC→OP 两次）")
	_runner.assert_equal(cnt["completed"], 1, "重复 OPERATIONAL 不重发 completed")
	# 视觉壳：外部视觉隐藏，状态机不受影响（仍 OPERATIONAL）
	b.set_visual_shell_only(true)
	_runner.assert_false(ext.visible, "视觉壳开：Exterior 隐藏")
	_runner.assert_true(b.is_operational(), "视觉壳不影响状态机")
	# DAMAGED 外观档
	b.set_state(ScriptBuilding.State.DAMAGED)
	_runner.assert_true(ext.modulate.is_equal_approx(Color(1.0, 0.5, 0.5, 1.0)), "受损外观偏红")


func _test_damage_half_threshold() -> void:
	_new_case()
	var b := _spawn(_new_building())
	b.set_state(ScriptBuilding.State.OPERATIONAL)
	# 半血线以上：保持运营
	b.take_damage(40.0)
	_runner.assert_approx(b.health, 60.0, 0.001, "扣血 40 → 60")
	_runner.assert_true(b.is_operational(), "60/100 未过半血线保持运营")
	# 过半血线：进 DAMAGED
	b.take_damage(15.0)
	_runner.assert_approx(b.health, 45.0, 0.001, "扣血 15 → 45")
	_runner.assert_true(b.state == ScriptBuilding.State.DAMAGED, "45 < 50% 进 DAMAGED")
	# 非 OPERATIONAL 不进 DAMAGED（建造中掉血只扣血不迁态）
	var b2 := _spawn(_new_building())
	b2.set_state(ScriptBuilding.State.UNDER_CONSTRUCTION)
	b2.take_damage(80.0)
	_runner.assert_approx(b2.health, 20.0, 0.001, "建造中扣血照常")
	_runner.assert_true(b2.is_under_construction(), "建造中不进 DAMAGED（只从 OPERATIONAL 迁）")


func _test_damage_demolish() -> void:
	_new_case()
	var b := _spawn(_new_building())
	var cnt := _make_counter(b)
	b.set_state(ScriptBuilding.State.OPERATIONAL)
	# 归零：自动拆除
	b.take_damage(1000.0)
	_runner.assert_approx(b.health, 0.0, 0.001, "超量伤害钳到 0")
	_runner.assert_true(b.state == ScriptBuilding.State.DESTROYED, "归零进 DESTROYED")
	_runner.assert_equal(cnt["demolished"], 1, "发一次 demolished")
	_runner.assert_false(b.visible, "DESTROYED 外观整栋隐藏")
	_runner.assert_false(b.is_operational(), "拆除后非运营")
	# 幂等：二次 demolish 不重发信号
	b.demolish()
	_runner.assert_equal(cnt["demolished"], 1, "二次 demolish 幂等（不重发）")
	# PLANNED 态直接 demolish 也走同一出口
	var b2 := _spawn(_new_building())
	var cnt2 := _make_counter(b2)
	b2.demolish()
	_runner.assert_equal(cnt2["demolished"], 1, "未完工也可拆除")
	_runner.assert_true(b2.state == ScriptBuilding.State.DESTROYED, "PLANNED → DESTROYED")


func _test_wall_barrier_demolish() -> void:
	_new_case()
	# 城墙（wall_tier>0）：拆除后挡板隐身 + 碰撞延迟禁用（单位可通过）
	var wall := _new_building()
	wall.wall_tier = 1
	var wall_cs := _attach_barrier(wall, Vector2.ZERO, Vector2(100, 50))
	_spawn(wall)
	wall.demolish()
	var wall_body: StaticBody2D = wall.get_passage_barrier()
	_runner.assert_not_null(wall_body, "get_passage_barrier 返回挡板")
	_runner.assert_false(wall_body.visible, "城墙拆除后挡板隐身")
	# set_deferred 写入：等一次引擎帧 flush（确定性时序，非就绪等待）
	await get_tree().process_frame
	_runner.assert_true(wall_cs.disabled, "碰撞体已禁用（可通行）")
	# 非城墙：拆除不动挡板（普通建筑由外部经 demolished 信号释放占地）
	var plain := _new_building()
	var plain_cs := _attach_barrier(plain, Vector2.ZERO, Vector2(100, 50))
	_spawn(plain)
	plain.demolish()
	await get_tree().process_frame
	_runner.assert_true(plain.get_passage_barrier().visible, "非城墙拆除后挡板仍可见")
	_runner.assert_false(plain_cs.disabled, "非城墙拆除后碰撞仍启用")


func _test_apply_def() -> void:
	_new_case()
	var b := _spawn(_new_building())
	# 真实字段应用
	b.apply_building_def({
		"interior_mode": 2, "mega_interior_map_id": "mega_forge",
		"wall_tier": 3, "can_stand_on": true, "is_gate": true, "max_hp": 250.0,
	})
	_runner.assert_equal(b._interior_mode, 2, "interior_mode=TELEPORT")
	_runner.assert_equal(b.mega_interior_map_id, "mega_forge", "大内景地图 ID")
	_runner.assert_equal(b.wall_tier, 3, "城墙 tier 3")
	_runner.assert_true(b.can_stand_on, "墙顶可站人")
	_runner.assert_true(b.is_gate, "城门")
	_runner.assert_true(b.is_wall(), "is_wall 命中（tier>0）")
	_runner.assert_approx(b.max_health, 250.0, 0.001, "max_hp 应用")
	_runner.assert_approx(b.health, 250.0, 0.001, "应用 def 后满血")
	# Excel 管线空单元格（key 在、值为 null）：回退默认值
	b.apply_building_def({
		"interior_mode": null, "mega_interior_map_id": null,
		"wall_tier": null, "can_stand_on": null, "is_gate": null, "max_hp": null,
	})
	_runner.assert_equal(b._interior_mode, 0, "null interior_mode 回退 NONE")
	_runner.assert_equal(b.mega_interior_map_id, "", "null 地图 ID 回退空串")
	_runner.assert_equal(b.wall_tier, 0, "null tier 回退非城墙")
	_runner.assert_false(b.can_stand_on, "null 可站人回退 false")
	_runner.assert_false(b.is_gate, "null 城门回退 false")
	_runner.assert_false(b.is_wall(), "null tier 后非城墙")
	_runner.assert_approx(b.max_health, 100.0, 0.001, "null max_hp 回退 100")
	_runner.assert_approx(b.health, 100.0, 0.001, "血量随新 max 重置")
	# 空 def 全默认
	var b2 := _spawn(_new_building())
	b2.apply_building_def({})
	_runner.assert_equal(b2._interior_mode, 0, "空 def 无室内交互")
	_runner.assert_false(b2.is_wall(), "空 def 非城墙")
	_runner.assert_approx(b2.max_health, 100.0, 0.001, "空 def 默认血量")


func _test_work_slots() -> void:
	_new_case()
	# 新路径：Interior/WorkSlots（§5.3）
	var b := _new_building(Vector2(500, 200))
	_attach_work_slots(b, [Vector2(-40, 10), Vector2(40, 10)], true)
	_spawn(b)
	_runner.assert_true(b.is_in_group("building"), "_ready 进 building 组（跨模块查询面）")
	_runner.assert_equal(b.get_work_slot_count(), 2, "Interior/WorkSlots 收集 2 槽")
	var positions: Array = b.get_work_slot_positions()
	_runner.assert_true((positions[0] as Vector2).is_equal_approx(Vector2(460, 210)),
			"槽位 0 世界坐标 = 建筑原点 + marker 偏移")
	_runner.assert_true((positions[1] as Vector2).is_equal_approx(Vector2(540, 210)),
			"槽位 1 世界坐标")
	_runner.assert_not_null(b.get_work_slot(0), "索引命中返回 Marker2D")
	_runner.assert_true(b.get_work_slot(0) is Marker2D, "返回类型 Marker2D")
	_runner.assert_null(b.get_work_slot(9), "越界索引返回 null")
	_runner.assert_null(b.get_work_slot(-1), "负索引返回 null")
	# 旧路径：根级 WorkSlots（兼容旧场景）
	var legacy := _new_building()
	_attach_work_slots(legacy, [Vector2(0, 5)], false)
	_spawn(legacy)
	_runner.assert_equal(legacy.get_work_slot_count(), 1, "旧版根级 WorkSlots 同样收集")


func _test_collision_bottom() -> void:
	_new_case()
	var b := _spawn(_new_building())
	# 无挡板：0.0 兜底
	_runner.assert_approx(b.get_collision_bottom_local(), 0.0, 0.001, "无 PassageBarrier 返回 0")
	# 挂挡板：bottom = cs.position.y + size.y/2（建造对齐草坪中线的口径；
	# 运行时挂载不经 _ready 迁移，保持原值）
	_attach_barrier(b, Vector2(30, -40), Vector2(200, 100))
	_runner.assert_approx(b.get_collision_bottom_local(), 10.0, 0.001,
			"下边界 = position.y + size.y*0.5 = -40 + 50")


func _test_collision_migration() -> void:
	_new_case()
	# 两栋建筑共享同一份 RectangleShape2D 子资源（模拟 tscn 未标 local_to_scene）：
	# 各实例必须 duplicate 私有后缩放，共享原件不动（双铁匠铺双缩回归）
	var shared := RectangleShape2D.new()
	shared.size = Vector2(128, 64)
	var buildings: Array = []
	var csses: Array = []
	for i in 2:
		var b := _new_building(Vector2(1000.0 * float(i), 0))
		var body := StaticBody2D.new()
		body.name = "PassageBarrier"
		var cs := CollisionShape2D.new()
		cs.shape = shared
		cs.position = Vector2(10, 20)
		body.add_child(cs)
		b.add_child(body)
		buildings.append(_spawn(b))
		csses.append(cs)
	# ×0.75：尺寸与位置同步缩，且各实例持有私有副本
	var first_cs: CollisionShape2D = csses[0]
	var second_cs: CollisionShape2D = csses[1]
	var first_rect: RectangleShape2D = first_cs.shape
	var second_rect: RectangleShape2D = second_cs.shape
	_runner.assert_true(first_rect != shared, "实例 1 持有 duplicate 后的私有 shape")
	_runner.assert_true(second_rect != shared, "实例 2 持有私有 shape（原件不被二次缩放）")
	_runner.assert_true(first_rect != second_rect, "两实例互不共享（防链式双缩）")
	_runner.assert_true(first_rect.size.is_equal_approx(Vector2(96, 48)), "尺寸 ×0.75")
	_runner.assert_true(first_cs.position.is_equal_approx(Vector2(7.5, 15)), "位置 ×0.75")
	_runner.assert_true(shared.size.is_equal_approx(Vector2(128, 64)), "共享原件尺寸不动")
	# meta 防重复迁移：手动再跑一遍不再缩
	buildings[0]._migrate_collision_geometry_to_canvas_px()
	_runner.assert_true(first_rect.size.is_equal_approx(Vector2(96, 48)), "meta 幂等：二次迁移不再缩")
