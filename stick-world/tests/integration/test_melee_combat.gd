extends Node
## 集成测试：近战剑击（临时配剑 + 程序化挥砍 + 受击反馈）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_melee_combat.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 火柴人自动配剑（WeaponMount 挂载占位剑到右手）
##   - 近战攻击：距离内命中、扣血、受击击退冲量
##   - 距离判定：超出剑长拒绝
##   - 挥砍动画：攻击后武器旋转变化
##   - 攻击冷却：连续攻击被拒绝
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

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
	_tests.append({"name": "配剑: 火柴人右手挂载占位剑", "fn": Callable(self, "_test_sword_mounted"), "async": true})
	_tests.append({"name": "近战: 距离内命中扣血并击退", "fn": Callable(self, "_test_hit_in_range"), "async": true})
	_tests.append({"name": "近战: 超出剑长拒绝", "fn": Callable(self, "_test_out_of_range"), "async": true})
	_tests.append({"name": "挥砍: 攻击后武器旋转变化", "fn": Callable(self, "_test_swing_rotation"), "async": true})
	_tests.append({"name": "冷却: 连续攻击被拒绝", "fn": Callable(self, "_test_cooldown"), "async": true})


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


## 获取单位武器挂载点
func _get_weapon(unit: Node) -> Node:
	if unit == null or not unit.has_method("get_weapon"):
		return null
	return unit.get_weapon()


## 配剑：WeaponMount 挂载了占位剑实例
func _test_sword_mounted() -> void:
	var u: Node = _helper.units[0]
	_runner.assert_true(u != null, "单位应存在")
	if u == null:
		return
	var wm: Node = _get_weapon(u)
	_runner.assert_true(wm != null, "应有 WeaponMount")
	if wm == null:
		return
	_runner.assert_true(wm.has_method("get_weapon_node"), "WeaponMount 应提供 get_weapon_node")
	var sword: Node2D = wm.get_weapon_node()
	_runner.assert_true(sword != null and is_instance_valid(sword), "右手应挂载占位剑")
	if sword != null and is_instance_valid(sword):
		_runner.assert_true(sword.get_parent() != null, "剑应挂载到骨骼节点下")
		# 剑应有握把锚点（GripPoint）
		_runner.assert_true(sword.get_node_or_null("GripPoint") != null, "剑应有 GripPoint")


## 近战：站近命中 → 扣血 + 受击击退冲量
func _test_hit_in_range() -> void:
	var atk: Node = _helper.units[0]
	var def: Node = _helper.units[1]
	if atk == null or def == null:
		_runner.assert_true(false, "单位缺失")
		return
	# 把防守方移到攻击方 60px 内（近战剑长 80px）
	var atk_pos: Vector2 = atk.global_position
	def.global_position = atk_pos + Vector2(60, 0)
	await get_tree().process_frame
	var wm: Node = _get_weapon(atk)
	if wm == null:
		_runner.assert_true(false, "WeaponMount 为空")
		return
	var hp_before: float = def.get_health().hp if def.get_health() != null else 0.0
	var result: Dictionary = wm.perform_attack(def)
	_runner.assert_true(result.get("hit", false), "近距离应命中，结果: %s" % str(result))
	if result.get("hit", false):
		var hp_after: float = def.get_health().hp if def.get_health() != null else 0.0
		_runner.assert_true(hp_after < hp_before, "命中后目标 HP 应减少")
		# 受击击退：目标获得非零击退冲量
		if def.has_method("get_knockback_velocity"):
			var kb: Vector2 = def.get_knockback_velocity()
			_runner.assert_true(kb.length() > 0.0, "受击后应有击退冲量，实际: %s" % str(kb))
			# 击退方向背离攻击者
			_runner.assert_true(kb.x > 0.0, "击退应背离攻击者（向右）")


## 近战：超出剑长拒绝
func _test_out_of_range() -> void:
	var atk: Node = _helper.units[0]
	var def: Node = _helper.units[1]
	if atk == null or def == null:
		_runner.assert_true(false, "单位缺失")
		return
	var wm: Node = _get_weapon(atk)
	if wm == null:
		_runner.assert_true(false, "WeaponMount 为空")
		return
	# 确保冷却已恢复（上一用例攻击过）
	wm.update_cooldown(10.0)
	def.global_position = atk.global_position + Vector2(400, 0)
	await get_tree().process_frame
	var result: Dictionary = wm.perform_attack(def)
	_runner.assert_true(not result.get("hit", false), "超出剑长不应命中")
	_runner.assert_equal(result.get("reason", ""), "out_of_range", "应拒绝为 out_of_range")


## 挥砍：攻击后武器旋转发生变化（Tween 推进后）
func _test_swing_rotation() -> void:
	var atk: Node = _helper.units[0]
	var def: Node = _helper.units[1]
	if atk == null or def == null:
		_runner.assert_true(false, "单位缺失")
		return
	var wm: Node = _get_weapon(atk)
	if wm == null:
		_runner.assert_true(false, "WeaponMount 为空")
		return
	var sword: Node2D = wm.get_weapon_node()
	if sword == null:
		_runner.assert_true(false, "剑未挂载")
		return
	# 等冷却恢复
	wm.update_cooldown(10.0)
	def.global_position = atk.global_position + Vector2(50, 0)
	await get_tree().process_frame
	var rot_before: float = sword.rotation
	wm.perform_attack(def)
	# 挥砍是 Tween 异步推进：等待数帧后检查旋转已偏离
	for i in 3:
		await get_tree().process_frame
	var rot_after: float = sword.rotation
	_runner.assert_true(absf(rot_after - rot_before) > 0.01, "攻击后武器旋转应变化（挥砍），before=%f after=%f" % [rot_before, rot_after])


## 冷却：攻击后立即再攻被拒绝
func _test_cooldown() -> void:
	var atk: Node = _helper.units[0]
	var def: Node = _helper.units[1]
	if atk == null or def == null:
		_runner.assert_true(false, "单位缺失")
		return
	var wm: Node = _get_weapon(atk)
	if wm == null:
		_runner.assert_true(false, "WeaponMount 为空")
		return
	def.global_position = atk.global_position + Vector2(50, 0)
	await get_tree().process_frame
	# 第一次攻击（主动确保冷却恢复）
	wm.update_cooldown(10.0)
	var first: Dictionary = wm.perform_attack(def)
	_runner.assert_true(first.get("hit", false), "第一次攻击应命中")
	# 立即第二次攻击：冷却拒绝
	var second: Dictionary = wm.perform_attack(def)
	_runner.assert_true(not second.get("hit", false), "冷却中第二次攻击应被拒绝")
	_runner.assert_equal(second.get("reason", ""), "cooldown", "应拒绝为 cooldown")
