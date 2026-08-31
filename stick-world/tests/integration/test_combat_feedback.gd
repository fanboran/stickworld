extends Node
## 集成测试：头顶血条 + 群体分离（战斗反馈与移动质量）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_combat_feedback.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 血条装配：实体有 HealthBar 组件
##   - 满血阵营圆点 / 掉血展开横条且比例正确 / 回满退回圆点 / 死亡隐藏
##   - 群体分离：两单位贴近时 AI 移动方向被推开（不叠人）
##   - 分离推力随距离衰减（远处无影响）+ 静态分离（停住防黏住）
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	# 顺序约束：分离测试在前（需要两个**活**单位），
	# 血条死亡测试最后（会把 units[1] 打死——尸体不再参与分离/物理，P0-1 死亡收口）
	_tests.append({"name": "血条: 组件已装配", "fn": Callable(self, "_test_bar_assembled"), "async": true})
	_tests.append({"name": "分离: 贴近时 AI 方向被推开", "fn": Callable(self, "_test_separation_pushes"), "async": true})
	_tests.append({"name": "分离: 远处无影响", "fn": Callable(self, "_test_separation_far"), "async": true})
	_tests.append({"name": "分离: 停住的单位被推开（防黏住）", "fn": Callable(self, "_test_static_separation"), "async": true})
	_tests.append({"name": "血条: 满血圆点/掉血展开横条/比例正确", "fn": Callable(self, "_test_bar_visibility"), "async": true})
	_tests.append({"name": "血条: 死亡隐藏", "fn": Callable(self, "_test_bar_on_death"), "async": true})


func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	# 生成 2 个测试单位
	_helper.spawn_test_units(2)
	for i in 2:
		await get_tree().process_frame

	for t in _tests:
		_runner.begin_test(t["name"])
		await t["fn"].call()
		_runner.end_test()
		print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## 血条组件已装配
func _test_bar_assembled() -> void:
	var u: Node = _helper.units[0]
	_runner.assert_true(u != null, "单位应存在")
	if u == null:
		return
	_runner.assert_true(u.has_method("get_health_bar"), "实体应提供 get_health_bar")
	var bar: Node = u.get_health_bar()
	_runner.assert_true(bar != null and is_instance_valid(bar), "血条组件应已装配")
	if bar != null and is_instance_valid(bar):
		_runner.assert_true(bar.get_parent() == u, "血条应挂在实体下")


## 满血 = 阵营色小圆点 / 掉血 = 展开手绘横条 / 回满 = 退回圆点
## （2026-08-31 观察场审计：阵营识别走血条本身，不再满血隐藏）
func _test_bar_visibility() -> void:
	var u: Node = _helper.units[0]
	var bar: Node = u.get_health_bar() if u != null and u.has_method("get_health_bar") else null
	if bar == null:
		_runner.assert_true(false, "血条缺失")
		return
	# 满血：圆点形态（可见 + 从未展开）
	_runner.assert_true(bar.visible, "满血时应显示阵营色小圆点（阵营识别来源）")
	_runner.assert_false(bar.get("_ever_damaged"), "满血时应为圆点形态（_ever_damaged=false）")
	# 受击 30%：展开横条且比例 ≈ 0.7（展开动画 EXPAND_SPEED=7/s，~0.15s 走完）
	var health: Node = u.get_health() if u.has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "HealthComponent 缺失")
		return
	health.take_damage(30.0)
	for i in 20:
		await get_tree().process_frame
	_runner.assert_true(bar.get("_ever_damaged"), "掉血后应进入横条形态")
	_runner.assert_true(float(bar.get("_expand")) > 0.9,
		"掉血后横条应展开完成，实际 %f" % float(bar.get("_expand")))
	_runner.assert_true(absf(float(bar.get("_ratio")) - 0.7) < 0.001,
		"比例应约 0.7，实际: %f" % float(bar.get("_ratio")))
	# 治疗恢复满血：退回圆点形态
	health.heal(999.0)
	for i in 20:
		await get_tree().process_frame
	_runner.assert_false(bar.get("_ever_damaged"), "恢复满血后应退回圆点形态")
	_runner.assert_true(absf(float(bar.get("_ratio")) - 1.0) < 0.001,
		"回满后比例应为 1.0，实际: %f" % float(bar.get("_ratio")))


## 死亡隐藏
func _test_bar_on_death() -> void:
	var u: Node = _helper.units[1]
	var bar: Node = u.get_health_bar() if u != null and u.has_method("get_health_bar") else null
	if bar == null:
		_runner.assert_true(false, "血条缺失")
		return
	var health: Node = u.get_health() if u.has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "HealthComponent 缺失")
		return
	health.take_damage(20.0)
	await get_tree().process_frame
	_runner.assert_true(bar.visible, "受击后血条应显示")
	health.take_damage(99999.0)
	await get_tree().process_frame
	_runner.assert_true(not bar.visible, "死亡后血条应隐藏")


## 图内安全放置：x 钳制到地图边界内（越界点会被活体每帧夹回边界，测量失真——
## 曾用 x=3000 超出村庄图右边界导致静态分离误报）；y 不动，单位出生时已按
## 脚底对齐到地面带，活体每帧也会把 y 夹回带内。
func _place_x(u: Node, x: float) -> void:
	var m: Node2D = _helper.map
	if m == null or u == null or not is_instance_valid(u):
		return
	u.global_position.x = clampf(x, m.map_left + 60.0, m.map_right - 60.0)


## 群体分离：贴近时 AI 移动方向被推开
func _test_separation_pushes() -> void:
	var a: Node = _helper.units[0]
	var b: Node = _helper.units[1]
	if a == null or b == null:
		_runner.assert_true(false, "单位缺失")
		return
	# b 移到 a 正右方 20px（远小于分离半径 42px）
	_place_x(a, 1000.0)
	_place_x(b, a.global_position.x + 20.0)
	await get_tree().process_frame
	# a 朝右移动（dir=+x），b 在右方应把 a 的移动方向推开（x 速度下降/y 偏离）
	if not a.has_method("ai_move"):
		_runner.assert_true(false, "实体缺 ai_move")
		return
	a.ai_move(Vector2(1, 0), false)
	await get_tree().process_frame
	# 读 a 的 velocity（物理帧已应用分离修正）
	var vel: Vector2 = a.velocity
	# 纯右向 = (speed, 0)；被推开后应偏离 x 轴（y 分量非零或 x 速度低于全速）
	_runner.assert_true(absf(vel.y) > 5.0 or vel.x < 100.0, "贴近友军时移动方向应被推开，vel=%s" % str(vel))
	a.ai_stop()


## 分离：远处无影响（> 半径时方向不修正）
func _test_separation_far() -> void:
	var a: Node = _helper.units[0]
	var b: Node = _helper.units[1]
	if a == null or b == null:
		_runner.assert_true(false, "单位缺失")
		return
	_place_x(a, 2000.0)
	_place_x(b, a.global_position.x + 400.0)  # 400px 远
	await get_tree().process_frame
	a.ai_move(Vector2(1, 0), false)
	await get_tree().process_frame
	var vel: Vector2 = a.velocity
	# 远处无邻居：速度应基本沿 +x（y 分量≈0）
	_runner.assert_true(absf(vel.y) < 5.0, "远处无邻居时不应被推开，vel=%s" % str(vel))
	a.ai_stop()


## 静态分离：两个停住的单位贴近放置（模拟射程边缘互停黏住），数帧后应被推开
func _test_static_separation() -> void:
	var a: Node = _helper.units[0]
	var b: Node = _helper.units[1]
	if a == null or b == null:
		_runner.assert_true(false, "单位缺失")
		return
	# 贴近放置（相距 10px，碰撞体约 40px 宽，即"黏住"状态）
	_place_x(a, 1200.0)
	_place_x(b, a.global_position.x + 10.0)
	# 双方都不移动（静止）
	if a.has_method("ai_stop"):
		a.ai_stop()
	if b.has_method("ai_stop"):
		b.ai_stop()
	await get_tree().process_frame
	# 放置后第一帧内物理去重叠 + 静态分离就可能已把两者弹到接近分离半径
	# （实测 before 采样时已 41.6/42），相对位移断言对时序敏感。
	# 防黏住的本质：停住单位不会被永久卡在重叠状态 → 断言"达到分离半径"。
	var dist_after: float = a.global_position.distance_to(b.global_position)
	for i in range(40):
		await get_tree().create_timer(0.05).timeout
		dist_after = a.global_position.distance_to(b.global_position)
		if dist_after >= 40.0:
			break
	_runner.assert_true(dist_after >= 40.0,
		"贴近停住的单位应被推开到分离半径（~42），最终间距=%.1f" % dist_after)
