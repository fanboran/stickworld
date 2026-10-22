extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：建造派工 Job 板（WorkCrewAssigner 两族统一分发）。
##
## 钉死的语义（Job 板化 + ROOT-8/9 同批）：
## ① 挂板与认领：项目挂板后 BUILD 族常驻可领（认领即项目成员、首人自动开工、
##    worker_assigned 发射），缺料项目按提示词派 HAUL 族（板上独立任务族）；
## ② 提示词定族：has_warehouse=false / can_haul=false 时缺料项目回退 BUILD 族；
## ③ refresh_job 族别换向：缺料 build→haul、材料到货 haul→build，原地换不发射
##    派工信号、不动池；
## ④ ROOT-9 距离认领：多项目时挑工人 x 最近的；平距回退挂板序（插入序语义）；
##    无位置工人（裸 Node 桩）退化为挂板序；
## ⑤ 释放路径：完工/取消把工人放回空闲池 + worker_unassigned 发射 + 项目下板；
## ⑥ ROOT-8 工位重排：成员增删后 slot 索引全量重算，任意时刻无冲突；
## ⑦ 旧消费面兼容：get_worker_project 两族同源、try_assign 幂等、
##    assign_to 手动派工族别随项目状态派生。
##
## fixture：纯 RefCounted（WorkCrewAssigner + ConstructionProject，map=null
## 跳过占位视觉/工地障碍；完工用例配 FakeMap + 运行时打包的空场景）+
## Node2D 工人（不进树，global_position 直接可读写），零场景树依赖。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptWorkCrewAssigner := preload("res://modules/construction/scripts/work_crew_assigner.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

## 占地条带宽（与派工距离度量同源；锚定 PlacementGrid.CELL_SIZE）
const CELL_PX: float = PlacementMetrics.CELL_PX


## 完工用例哑地图：只供 building_host 挂点（墙脚线/网格 duck 全走回退）
class FakeMap:
	extends Node2D
	var building_host: Node2D = null


var _runner: TestRunner
## 用例残留工人（统一释放，防跨用例对象泄漏计数）
var _workers: Array[Node] = []
## 用例残留地图节点
var _maps: Array[Node] = []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("池: 注册/注销与派工中注销解除任务", _test_pool_lifecycle)
	_runner.add_test("认领: BUILD 族常驻可领（首人开工 + 信号 + 出池）", _test_claim_build)
	_runner.add_test("认领: 缺料项目按提示词派 HAUL 族（板上独立任务族）", _test_claim_haul)
	_runner.add_test("提示词: 无仓库/禁搬运时缺料项目回退 BUILD 族", _test_hint_fallback)
	_runner.add_test("刷新: 缺料 build→haul、材料到货 haul→build（原地换无信号）", _test_refresh_swap)
	_runner.add_test("距离: 挑最近项目（ROOT-9），平距回退挂板序", _test_distance)
	_runner.add_test("距离: 无位置工人退化为挂板序（旧插入序语义）", _test_distance_no_pos)
	_runner.add_test("释放: 完工放回空闲池 + 信号 + 下板", _test_release_complete)
	_runner.add_test("释放: 取消同样释放（不回调 unassign_worker）", _test_release_cancel)
	_runner.add_test("工位: 成员增删后 slot 全量重算无冲突（ROOT-8）", _test_slot_recompute)
	_runner.add_test("兼容: get_worker_project 两族同源 + assign_to 族别派生 + 幂等", _test_compat)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── fixture ────────────────────────────────

## 建项目（map=null：占位视觉/工地障碍跳过，纯状态机可测；完工用例传 FakeMap）
func _make_project(cell_x: int, width: int = 2, map: Node2D = null,
		scene: PackedScene = null) -> ScriptConstructionProject:
	return ScriptConstructionProject.new("proj_%04d" % cell_x, "placeholder",
			cell_x, width, map, scene, 8.0, "r1")


## 完工就绪项目：FakeMap（含 building_host）+ 运行时打包的 Node2D 空场景
func _make_completable_project(cell_x: int) -> ScriptConstructionProject:
	var map := FakeMap.new()
	map.building_host = Node2D.new()
	map.building_host.name = "BuildingHost"
	map.add_child(map.building_host)
	_maps.append(map)
	_maps.append(map.building_host)
	var root := Node2D.new()
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return _make_project(cell_x, 2, map, scene)


## 建 Node2D 工人（带 x 坐标；不进树，global_position 直接可读写）
func _make_worker(x: float) -> Node2D:
	var w := Node2D.new()
	w.global_position = Vector2(x, 0.0)
	_workers.append(w)
	return w


## 建裸 Node 工人（无位置属性 → 距离退化用例 + 旧行为兼容面）
func _make_bare_worker() -> Node:
	var w := Node.new()
	_workers.append(w)
	return w


func _cleanup() -> void:
	for w in _workers:
		if is_instance_valid(w):
			w.free()
	_workers.clear()
	for m in _maps:
		if is_instance_valid(m):
			m.free()
	_maps.clear()


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_pool_lifecycle() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var w := _make_worker(0.0)
	a.register_worker(w)
	_runner.assert_equal(a.get_available_count(), 1, "注册后池内 1 人")
	a.register_worker(w)
	_runner.assert_equal(a.get_available_count(), 1, "重复注册去重")
	# 派工中注销：解除任务 + 回调项目 unassign + 发射信号
	var p := _make_project(10)
	a.add_project(p)
	var fired: Array = []
	a.worker_unassigned.connect(func(worker, project): fired.append([worker, project]))
	_runner.assert_true(a.try_assign(w), "认领应成功")
	_runner.assert_true(a.is_assigned(w), "认领后为派工态")
	a.unregister_worker(w)
	_runner.assert_false(a.is_assigned(w), "注销后无派工")
	_runner.assert_equal(p.get_worker_count(), 0, "项目成员同步解除")
	_runner.assert_equal(fired.size(), 1, "注销发射 worker_unassigned 一次")
	_runner.assert_equal(a.get_available_count(), 0, "注销后不回池（退出派工体系）")


func _test_claim_build() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	a.add_project(p)
	var w := _make_worker(0.0)
	a.register_worker(w)
	var assigned: Array = []
	a.worker_assigned.connect(func(worker, project): assigned.append([worker, project]))
	_runner.assert_true(a.try_assign(w, {"can_build": true, "can_haul": false, "has_warehouse": false}),
			"认领应成功")
	var job: Dictionary = a.get_worker_job(w)
	_runner.assert_equal(String(job.get("kind", "")), "build", "不缺料路径应派 BUILD 族")
	_runner.assert_equal(job.get("project"), p, "任务绑定挂板项目")
	_runner.assert_equal(p.state, ScriptConstructionProject.State.UNDER_CONSTRUCTION, "首名认领自动开工")
	_runner.assert_equal(p.get_worker_count(), 1, "认领即项目成员（搬运/建造同源）")
	_runner.assert_equal(assigned.size(), 1, "认领发射 worker_assigned")
	_runner.assert_equal(a.get_available_count(), 0, "认领后出池")
	_runner.assert_true(p.has_worker(w), "项目在册")


func _test_claim_haul() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	# 制造缺料态：材料 0 且建造进度已追上（needs_material 初始即真）
	a.add_project(p)
	var w := _make_worker(0.0)
	a.register_worker(w)
	_runner.assert_true(p.needs_material(), "前置：新项目缺料")
	_runner.assert_true(a.try_assign(w, {"can_build": true, "can_haul": true, "has_warehouse": true}),
			"提示词全开认领应成功")
	var job: Dictionary = a.get_worker_job(w)
	_runner.assert_equal(String(job.get("kind", "")), "haul", "缺料 + 可搬运 + 有仓库应派 HAUL 族")
	_runner.assert_equal(job.get("project"), p, "HAUL 任务绑定项目")
	_runner.assert_true(p.has_worker(w), "搬运工也是项目成员")


func _test_hint_fallback() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	a.add_project(p)
	# 无仓库：缺料也回退 BUILD（与旧行为分支一致：无仓库不搬，站桩建到材料上限）
	var w1 := _make_worker(0.0)
	a.register_worker(w1)
	_runner.assert_true(a.try_assign(w1, {"can_build": true, "can_haul": true, "has_warehouse": false}))
	_runner.assert_equal(String(a.get_worker_job(w1).get("kind", "")), "build", "无仓库回退 BUILD 族")
	# 禁搬运：同样回退 BUILD
	var w2 := _make_worker(0.0)
	a.register_worker(w2)
	_runner.assert_true(a.try_assign(w2, {"can_build": true, "can_haul": false, "has_warehouse": true}))
	_runner.assert_equal(String(a.get_worker_job(w2).get("kind", "")), "build", "禁搬运回退 BUILD 族")
	# 两族皆否：无可领族 → 认领失败
	var w3 := _make_worker(0.0)
	a.register_worker(w3)
	_runner.assert_false(a.try_assign(w3, {"can_build": false, "can_haul": false, "has_warehouse": true}),
			"两族皆否应认领失败")


func _test_refresh_swap() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	a.add_project(p)
	var w := _make_worker(0.0)
	a.register_worker(w)
	var full := {"can_build": true, "can_haul": true, "has_warehouse": true}
	_runner.assert_true(a.try_assign(w, full), "提示词全开认领")
	_runner.assert_equal(String(a.get_worker_job(w).get("kind", "")), "haul", "初始缺料为 HAUL 族")
	# 信号计数：换向不应发射任何派工信号
	var signals: Array = []
	a.worker_assigned.connect(func(_worker, _project): signals.append("assigned"))
	a.worker_unassigned.connect(func(_worker, _project): signals.append("unassigned"))
	# 材料到货：haul→build
	p.deliver_material(1.0)
	var job: Dictionary = a.refresh_job(w, full)
	_runner.assert_equal(String(job.get("kind", "")), "build", "材料满后刷新为 BUILD 族")
	_runner.assert_equal(String(a.get_worker_job(w).get("kind", "")), "build", "内部任务同步换向")
	_runner.assert_true(p.has_worker(w), "换向不动项目成员")
	_runner.assert_true(a.is_assigned(w), "换向不解除派工")
	_runner.assert_equal(a.get_available_count(), 0, "换向不动池")
	_runner.assert_equal(signals.size(), 0, "族内换向不发射派工信号")
	# 未持任务者刷新返回空
	var w2 := _make_worker(100.0)
	_runner.assert_true(a.refresh_job(w2).is_empty(), "未持任务刷新返回空")


func _test_distance() -> void:
	var a := ScriptWorkCrewAssigner.new()
	# 项目中心 x = (cell_x + width/2) * CELL_PX：far(49,2)=1200，near(9,2)=240
	var far := _make_project(49)
	var near := _make_project(9)
	a.add_project(far)
	a.add_project(near)
	# 工人在 260：距 near 20、距 far 940 → 挂板序靠后的近项目胜出（ROOT-9）
	var w := _make_worker(260.0)
	a.register_worker(w)
	_runner.assert_true(a.try_assign(w), "认领应成功")
	_runner.assert_equal(a.get_worker_job(w).get("project"), near, "ROOT-9：挑最近项目")
	# 平距：两项目中心中点 (240+1200)/2=720 → 平距 tie-break 先挂板者（far）
	var w2 := _make_worker(720.0)
	a.register_worker(w2)
	_runner.assert_true(a.try_assign(w2), "第二人认领应成功")
	_runner.assert_equal(a.get_worker_job(w2).get("project"), far, "平距回退挂板序（先挂板的 far 项目）")


func _test_distance_no_pos() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p_first := _make_project(10)
	var p_far := _make_project(500)
	a.add_project(p_first)
	a.add_project(p_far)
	# 裸 Node 桩无位置 → 挂板序（旧插入序语义），不吃距离排序
	var w := _make_bare_worker()
	a.register_worker(w)
	_runner.assert_true(a.try_assign(w), "无位置工人认领应成功")
	_runner.assert_equal(a.get_worker_job(w).get("project"), p_first, "无位置退化挂板序（首个挂板项目）")


func _test_release_complete() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_completable_project(10)
	a.add_project(p)
	var w := _make_worker(0.0)
	a.register_worker(w)
	_runner.assert_true(a.try_assign(w))
	var unassigned: Array = []
	a.worker_unassigned.connect(func(worker, project): unassigned.append([worker, project]))
	# 完工：材料满 + 工作量满
	p.deliver_material(1.0)
	p.add_build_progress(8.0)
	_runner.assert_equal(p.state, ScriptConstructionProject.State.OPERATIONAL, "前置：项目完工")
	_runner.assert_false(a.is_assigned(w), "完工后工人不再派工")
	_runner.assert_equal(a.get_available_count(), 1, "完工后工人回空闲池")
	_runner.assert_equal(unassigned.size(), 1, "完工发射 worker_unassigned")
	_runner.assert_equal(a.get_project_count(), 0, "完工项目下板")
	# 复认领：池内工人对新项目正常派发
	var p2 := _make_project(20)
	a.add_project(p2)
	_runner.assert_true(a.try_assign(w), "回池工人可复认领")


func _test_release_cancel() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	a.add_project(p)
	var w := _make_worker(0.0)
	a.register_worker(w)
	_runner.assert_true(a.try_assign(w))
	var unassigned: Array = []
	a.worker_unassigned.connect(func(worker, project): unassigned.append([worker, project]))
	p.cancel()
	_runner.assert_false(a.is_assigned(w), "取消后工人不再派工")
	_runner.assert_equal(a.get_available_count(), 1, "取消后工人回池")
	_runner.assert_equal(unassigned.size(), 1, "取消发射 worker_unassigned")
	_runner.assert_equal(a.get_project_count(), 0, "取消项目下板")


func _test_slot_recompute() -> void:
	var p := _make_project(10)
	# 4 名工人先后入册 → 按在册序 slot 0..3
	var ws: Array[Node] = []
	for i in 4:
		var w := _make_worker(float(i))
		ws.append(w)
		p.assign_worker(w)
	var slots: Array = []
	for w in ws:
		slots.append(p.get_worker_slot_index(w))
	_runner.assert_equal(slots, [0, 1, 2, 3], "4 人在册 slot 0..3")
	# 第 2 人退出 → 剩余 3 人全量重排 0..2（ROOT-8：旧实现残留 0/2/3 空洞）
	p.unassign_worker(ws[1])
	var slots_after: Array = []
	for w in [ws[0], ws[2], ws[3]]:
		slots_after.append(p.get_worker_slot_index(w))
	_runner.assert_equal(slots_after, [0, 1, 2], "剩余 3 人收拢重排 0..2")
	# 补派新工人 → 0..3 全量无冲突（旧实现新人分到 3 与 ws[3] 同位站两人）
	var w4 := _make_worker(99.0)
	ws.append(w4)
	p.assign_worker(w4)
	var final_slots: Array = []
	for w in [ws[0], ws[2], ws[3], w4]:
		final_slots.append(p.get_worker_slot_index(w))
	_runner.assert_equal(final_slots, [0, 1, 2, 3], "补派后全量重排无冲突")


func _test_compat() -> void:
	var a := ScriptWorkCrewAssigner.new()
	var p := _make_project(10)
	a.add_project(p)
	# 裸 Node（旧测试桩形态）+ 缺省提示词：两族默认可领，缺料项目 → haul 族
	var w := _make_bare_worker()
	a.register_worker(w)
	_runner.assert_true(a.try_assign(w), "缺省提示词认领成功（默认 haul 可领）")
	_runner.assert_equal(String(a.get_worker_job(w).get("kind", "")), "haul", "缺省提示词下缺料即 haul")
	# get_worker_project 与任务同源
	_runner.assert_equal(a.get_worker_project(w), p, "get_worker_project 两族同源")
	# 幂等：已持任务再 try_assign 返回 true 且不换项目
	_runner.assert_true(a.try_assign(w, {"can_build": false, "can_haul": false}),
			"已持任务幂等成功（提示词不影响）")
	_runner.assert_equal(a.get_worker_project(w), p, "幂等认领不换项目")
	# assign_to 手动派工：族别随项目状态派生（与自动认领同源，缺料即 haul）
	var p2 := _make_project(20)
	a.add_project(p2)
	_runner.assert_true(a.assign_to(w, p2), "手动派工成功")
	_runner.assert_equal(a.get_worker_project(w), p2, "手动派工换项目")
	_runner.assert_equal(String(a.get_worker_job(w).get("kind", "")), "haul", "手动派工族别随项目状态派生")
	_runner.assert_equal(p.get_worker_count(), 0, "旧项目成员同步解除")
