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
##   - 满血不显示 / 受击后显示且比例正确 / 死亡隐藏
##   - 群体分离：两单位贴近时 AI 移动方向被推开（不叠人）
##   - 分离推力随距离衰减（远处无影响）
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
	_tests.append({"name": "血条: 组件已装配", "fn": Callable(self, "_test_bar_assembled"), "async": true})
	_tests.append({"name": "血条: 满血隐藏/受击显示/比例正确", "fn": Callable(self, "_test_bar_visibility"), "async": true})
	_tests.append({"name": "血条: 死亡隐藏", "fn": Callable(self, "_test_bar_on_death"), "async": true})
	_tests.append({"name": "分离: 贴近时 AI 方向被推开", "fn": Callable(self, "_test_separation_pushes"), "async": true})
	_tests.append({"name": "分离: 远处无影响", "fn": Callable(self, "_test_separation_far"), "async": true})
	_tests.append({"name": "分离: 停住的单位被推开（防黏住）", "fn": Callable(self, "_test_static_separation"), "async": true})


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


## 满血隐藏 / 受击显示 / 比例正确
func _test_bar_visibility() -> void:
	var u: Node = _helper.units[0]
	var bar: Node = u.get_health_bar() if u != null and u.has_method("get_health_bar") else null
	if bar == null:
		_runner.assert_true(false, "血条缺失")
		return
	# 满血：不显示
	_runner.assert_true(not bar.visible, "满血时血条应隐藏")
	# 受击 30%：显示且比例 ≈ 0.7
	var health: Node = u.get_health() if u.has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "HealthComponent 缺失")
		return
	health.take_damage(30.0)
	await get_tree().process_frame
	_runner.assert_true(bar.visible, "受击后血条应显示")
	var ratio: float = bar.get("_ratio")
	_runner.assert_true(absf(ratio - 0.7) < 0.001, "比例应约 0.7，实际: %f" % ratio)
	# 治疗恢复满血：重新隐藏
	health.heal(999.0)
	await get_tree().process_frame
	_runner.assert_true(not bar.visible, "恢复满血后血条应隐藏")


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


## 群体分离：贴近时 AI 移动方向被推开
func _test_separation_pushes() -> void:
	var a: Node = _helper.units[0]
	var b: Node = _helper.units[1]
	if a == null or b == null:
		_runner.assert_true(false, "单位缺失")
		return
	# b 移到 a 正右方 20px（远小于分离半径 42px）
	a.global_position = Vector2(1000, 500)
	b.global_position = Vector2(1020, 500)
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
	a.global_position = Vector2(2000, 500)
	b.global_position = Vector2(2400, 500)  # 400px 远
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
	a.global_position = Vector2(3000, 500)
	b.global_position = Vector2(3010, 500)
	# 双方都不移动（静止）
	if a.has_method("ai_stop"):
		a.ai_stop()
	if b.has_method("ai_stop"):
		b.ai_stop()
	await get_tree().process_frame
	var dist_before: float = a.global_position.distance_to(b.global_position)
	# 等 0.3s（静态分离逐帧推开）。固定墙钟等待在并行负载下会被饿死，
	# 改为条件轮询：最多 2s 墙钟，每 50ms 检查一次是否已推开 ≥5px。
	var moved := false
	var dist_after := dist_before
	for i in range(40):
		await get_tree().create_timer(0.05).timeout
		dist_after = a.global_position.distance_to(b.global_position)
		if dist_after > dist_before + 5.0:
			moved = true
			break
	_runner.assert_true(moved, "贴近停住的单位应被静态分离推开，before=%.1f after=%.1f" % [dist_before, dist_after])
