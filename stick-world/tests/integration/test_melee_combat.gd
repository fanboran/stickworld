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

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
## 攻击方锚点（_pin_pair 用：把单位钉回这里，排除 AI 位移干扰）
var _atk_anchor: Vector2 = Vector2.ZERO


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


## 把两个单位钉成固定间距（AI 会各自走开，测试期间需保持几何关系）。
## atk 保持原位，def 固定在 atk 右侧 gap 像素处。
func _pin_pair(atk: Node, def: Node, gap: float) -> void:
	if atk == null or def == null:
		return
	if not is_instance_valid(atk) or not is_instance_valid(def):
		return
	atk.global_position = _atk_anchor
	def.global_position = _atk_anchor + Vector2(gap, 0.0)
	if atk.has_method("ai_stop"):
		atk.ai_stop()
	if def.has_method("ai_stop"):
		def.ai_stop()


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
	_atk_anchor = atk.global_position
	_pin_pair(atk, def, 60.0)
	await get_tree().process_frame
	var wm: Node = _get_weapon(atk)
	if wm == null:
		_runner.assert_true(false, "WeaponMount 为空")
		return
	# 固定命中率消除随机性（基础 0.9 有 10% miss 导致偶发测试失败）
	wm.base_hit_chance = 1.0
	var hp_before: float = def.get_health().hp if def.get_health() != null else 0.0
	var result: Dictionary = wm.perform_attack(def)
	# Strike 模式（Saga 复刻）：发起返回 striking，伤害在动画命中帧结算
	var launched: bool = result.get("hit", false) or result.get("reason", "") == "striking"
	_runner.assert_true(launched, "近距离应发起攻击，结果: %s" % str(result))
	if launched:
		# 轮询等待命中帧结算（动画内嵌 Hit 事件，Swordwrath-Attack1 Hit@1.0s）
		# 击退冲量衰减 700/s，需在结算后立即采样：先等到 HP 变化那一帧抓击退。
		# 每帧把双方钉回原位：两个单位都由 AI 接管，命中帧（~1s）之前早跑开了，
		# 不钉住就会因"目标跑出射程"被判空挥。
		# 按**墙钟时间**轮询而非固定帧数：headless 无 vsync 时 process_frame 能跑到
		# 120+ fps，固定 120 帧只覆盖不到 1 秒——而命中帧在动画 1.0s 处，会等不到。
		var kb_captured: Vector2 = Vector2.ZERO
		var t_start: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_start < 4000:
			_pin_pair(atk, def, 60.0)
			await get_tree().process_frame
			var hp_now: float = def.get_health().hp if def.get_health() != null else 0.0
			if hp_now < hp_before:
				if def.has_method("get_knockback_velocity"):
					kb_captured = def.get_knockback_velocity()
				break
		var hp_after: float = def.get_health().hp if def.get_health() != null else 0.0
		_runner.assert_true(hp_after < hp_before, "命中帧后目标 HP 应减少")
		# 受击击退：结算帧捕获的非零冲量
		if def.has_method("get_knockback_velocity"):
			_runner.assert_true(kb_captured.length() > 0.0, "受击后应有击退冲量，实际: %s" % str(kb_captured))
			_runner.assert_true(kb_captured.x > 0.0, "击退应背离攻击者（向右）")


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


## 挥砍：攻击后武器跟随手臂动画移动（剑挂 hand_inner 骨骼，attack 动画驱动）
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
	var pos_before: Vector2 = sword.global_position
	wm.perform_attack(def)
	# 触发攻击动画（Swordwrath-Attack1 转译）驱动手臂挥砍，剑挂手骨骼跟随移动
	if atk.has_method("play_attack"):
		atk.play_attack()
	# 动画异步推进：等待数帧后检查剑已跟随手臂移动（而非 Tween 自转）
	for i in 6:
		await get_tree().process_frame
	var pos_after: Vector2 = sword.global_position
	_runner.assert_true(pos_before.distance_to(pos_after) > 2.0,
		"攻击后武器应跟随手臂动画挥砍移动，before=%s after=%s" % [pos_before, pos_after])


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
	# 等上一用例遗留的未结算挥砍落地（P5 命中帧门禁：挥砍未到命中帧时拒绝新攻击）。
	# 按真实时间等（headless 下 process_frame 快于 physics tick，帧数等待不可靠）；
	# 上限 8s 兜底并行池 CPU 争用（物理 tick 变慢时动画推进同步变慢）
	var waited := 0.0
	while wm.has_pending_strike() and waited < 8.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	# 落地后再摆位：上用例的命中帧结算可能落在本等待窗口内，击退会把 def 推出
	# 剑长（并行负载下时序不定，曾致本用例被判 out_of_range）——位置/残余速度
	# 须在等待结束后最后确定
	def.velocity = Vector2.ZERO
	def.global_position = atk.global_position + Vector2(50, 0)
	await get_tree().process_frame
	# 第一次攻击（主动确保冷却恢复 + 固定命中率）
	wm.update_cooldown(10.0)
	wm.base_hit_chance = 1.0
	var first: Dictionary = wm.perform_attack(def)
	var first_launched: bool = first.get("hit", false) or first.get("reason", "") == "striking"
	_runner.assert_true(first_launched, "第一次攻击应发起 reason=%s pending=%s cd=%.2f" % [first.get("reason", ""), wm.has_pending_strike(), wm.get_cooldown_remaining()])
	# 立即第二次攻击：冷却拒绝
	var second: Dictionary = wm.perform_attack(def)
	_runner.assert_true(not second.get("hit", false), "冷却中第二次攻击应被拒绝 actual=%s" % [second])
	_runner.assert_equal(second.get("reason", ""), "cooldown", "应拒绝为 cooldown actual=%s" % [second])

