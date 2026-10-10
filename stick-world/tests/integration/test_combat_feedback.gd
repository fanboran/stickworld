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
##   - 入战满血圆点 / 掉血展开横条且比例正确 / 回满退回圆点 / 死亡隐藏
##     （快照口径：HD-2D 下实体侧血条切数据模式停画，绘制终点在 billboard
##     镜像——断言走公共快照 get_bar_state()，不再直探 visible/_expand）
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
	_tests.append({"name": "分离: 不反转意图纯函数（零速顶住/前向偏航）", "fn": Callable(self, "_test_sep_no_reverse_fn")})
	_tests.append({"name": "分离: 对顶不倒走", "fn": Callable(self, "_test_separation_pushes"), "async": true})
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


## 满血 = 阵营色小圆点 / 掉血 = 展开手绘横条 / 回满 = 退回圆点。
## 快照口径：HD-2D 下实体侧血条切数据模式（visible 恒 false 停画，状态机照
## 跑），绘制终点在 billboard 镜像——断言改查公共快照 get_bar_state()
## （active=显示门，expand=圆点↔横条展开度，ratio=血量比例）。
## 满血显示已收窄为"入战/掉血/悬浮"三通道（2026-09 脱战渐隐语义）：
## 满血且脱战时快照 active=false 是设计行为，故注入入战桩点亮"在战"通道。
func _test_bar_visibility() -> void:
	var u: Node = _helper.units[0]
	var bar: Node = u.get_health_bar() if u != null and u.has_method("get_health_bar") else null
	if bar == null:
		_runner.assert_true(false, "血条缺失")
		return
	var health: Node = u.get_health() if u.has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "HealthComponent 缺失")
		return
	# 受测单位固定近景档：镜头外的夹具单位会被 LOD FAR 冻结血条状态机
	# （_update_hz=0 停更，_expand 恒 0）；director 只在档位变化时下发，
	# 手动固定不会被下一拍顶回
	u.set_perf_tier(0)
	# 入战桩：血条显示状态机只探 is_active() 鸭子方法（_check_in_combat），
	# 满血圆点的显示靠"在战"通道点亮
	var stub := InCombatStub.new()
	u.set_battle_instance(stub)
	var snap: Dictionary = {}
	# 入战满血：圆点形态（快照点亮 + 从未展开）。渐显 FADE_SPEED=3/s，条件轮询
	var wait_ms: int = 0
	while wait_ms < 2000:
		snap = bar.get_bar_state()
		if bool(snap.get("active", false)):
			break
		await get_tree().create_timer(0.05).timeout
		wait_ms += 50
	_runner.assert_true(bool(snap.get("active", false)),
		"入战满血时应显示阵营色小圆点（阵营识别来源，active=true）")
	_runner.assert_true(absf(float(snap.get("expand", -1.0))) < 0.001,
		"满血时应为圆点形态（expand=0），实际 %s" % str(snap.get("expand")))
	# 受击 30%：展开横条且比例 ≈ 0.7（展开动画 EXPAND_SPEED=7/s，~0.15s 走完）
	health.take_damage(health.max_hp * 0.3)  # 按 max_hp 比例扣血（P5 校准后 HP 不再固定 100）
	# 条件等待：按真实时间轮询等展开完成或 2s 超时（固定帧数在负载波动下时序脆弱）
	wait_ms = 0
	snap = bar.get_bar_state()
	while wait_ms < 2000 and float(snap.get("expand", 0.0)) <= 0.9:
		await get_tree().create_timer(0.05).timeout
		wait_ms += 50
		snap = bar.get_bar_state()
	_runner.assert_true(float(snap.get("expand", 0.0)) > 0.9,
		"掉血后横条应展开完成，实际 %s（等待 %d ms）" % [str(snap.get("expand")), wait_ms])
	_runner.assert_true(absf(float(snap.get("ratio", 0.0)) - 0.7) < 0.001,
		"比例应约 0.7，实际: %s" % str(snap.get("ratio")))
	# 治疗恢复满血：退回圆点形态（收拢 EXPAND_SPEED 同速，条件轮询）
	health.heal(999.0)
	wait_ms = 0
	snap = bar.get_bar_state()
	while wait_ms < 2000 and float(snap.get("expand", 1.0)) > 0.001:
		await get_tree().create_timer(0.05).timeout
		wait_ms += 50
		snap = bar.get_bar_state()
	_runner.assert_true(absf(float(snap.get("expand", -1.0))) < 0.001,
		"恢复满血后应退回圆点形态（expand=0），实际 %s" % str(snap.get("expand")))
	_runner.assert_true(absf(float(snap.get("ratio", 0.0)) - 1.0) < 0.001,
		"回满后比例应为 1.0，实际: %s" % str(snap.get("ratio")))
	# 清理入战桩（脱战，不泄漏给后续用例）
	u.set_battle_instance(null)


## 死亡隐藏（快照口径：死亡 _on_died 置 ratio=0 停更，快照 active 随之熄灭）
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
	# 近景档（同 _test_bar_visibility：防 LOD FAR 冻结状态机）
	u.set_perf_tier(0)
	health.take_damage(20.0)
	# 掉血通道点亮显示（渐显需要时间，条件轮询）
	var snap: Dictionary = bar.get_bar_state()
	var wait_ms: int = 0
	while wait_ms < 2000 and not bool(snap.get("active", false)):
		await get_tree().create_timer(0.05).timeout
		wait_ms += 50
		snap = bar.get_bar_state()
	_runner.assert_true(bool(snap.get("active", false)), "受击后血条快照应点亮（active=true）")
	health.take_damage(99999.0)
	await get_tree().process_frame
	snap = bar.get_bar_state()
	_runner.assert_true(absf(float(snap.get("ratio", -1.0))) < 0.001,
		"死亡后血量比例应为 0，实际: %s" % str(snap.get("ratio")))
	_runner.assert_true(not bool(snap.get("active", true)), "死亡后血条快照应熄灭（active=false）")


## 入战桩：血条显示状态机的"在战"判定只探 is_active() 鸭子方法
## （_check_in_combat），实体侧 battle_instance 其余消费点同样鸭子兼容
class InCombatStub extends Node:
	func is_active() -> bool:
		return true


## 图内安全放置：x 钳制到地图边界内（越界点会被活体每帧夹回边界，测量失真——
## 曾用 x=3000 超出村庄图右边界导致静态分离误报）；y 不动，单位出生时已按
## 脚底对齐到地面带，活体每帧也会把 y 夹回带内。
func _place_x(u: Node, x: float) -> void:
	var m: Node2D = _helper.map
	if m == null or u == null or not is_instance_valid(u):
		return
	u.global_position.x = clampf(x, m.map_left + 60.0, m.map_right - 60.0)


## 分离不反转意图的纯函数契约（批3）：反向推力压过走力=零速顶住（ZERO），
## 否则按横向分量偏航全速前进（单位长）；前向/顶住二值，永不倒走。
func _test_sep_no_reverse_fn() -> void:
	var motion: GDScript = preload("res://modules/units/scripts/entity/entity_motion.gd")
	var dir_r := Vector2(1, 0)
	# 纯对顶：意图(1,0)+逆推力(-1.6,0) → 零速顶住
	_runner.assert_true(motion._sep_no_reverse(Vector2(-0.6, 0), dir_r) == Vector2.ZERO,
			"反向推力压过走力应零速顶住")
	# 横推（垂直分量，不逆意图）：保持单位长偏航
	var lat: Vector2 = motion._sep_no_reverse(Vector2(1.0, 0.2), dir_r)
	_runner.assert_true(is_equal_approx(lat.length(), 1.0) and lat.x > 0.9,
			"横推应偏航不减速（单位长），实际 %s" % str(lat))
	# 强横推弱逆推（净投影仍>0）：前向偏航
	var weak_opp: Vector2 = motion._sep_no_reverse(Vector2(0.3, 0.9), dir_r)
	_runner.assert_true(weak_opp.x > 0.0 and is_equal_approx(weak_opp.length(), 1.0),
			"净前向推挤应保持前进（单位长），实际 %s" % str(weak_opp))


## 群体分离：对顶不倒走（分离不反转意图）——批3 契约
func _test_separation_pushes() -> void:
	var a: Node = _helper.units[0]
	var b: Node = _helper.units[1]
	if a == null or b == null:
		_runner.assert_true(false, "单位缺失")
		return
	# b 移到 a 正右方 20px（远小于分离半径 42px）
	_place_x(a, 1000.0)
	_place_x(b, a.global_position.x + 20.0)
	await get_tree().physics_frame
	# a 朝右移动（dir=+x），b 在正右方对顶——批3 分离不反转意图（SWL PushApart
	# 推位置不推意图）：对顶全程 vel.x 不取负（顶住/前进均可，倒走不可）。
	# （纯函数契约另见"分离: 不反转意图纯函数"用例；重叠解开速率属整场动态，
	# 由 --twitch 探针的待机漂移指标对账，不在此断言——AI 自治意图会盖掉
	# 测试输入，多帧位置断言天生脆弱）
	if not a.has_method("ai_move"):
		_runner.assert_true(false, "实体缺 ai_move")
		return
	a.ai_move(Vector2(1, 0), false)
	# 等 12 物理帧：速度爬升 + 对顶失速进入稳态（物理行为断言等物理帧——
	# 30Hz 物理 + headless 高渲染帧率下 process_frame 不保证物理帧已跑）
	for i in 12:
		await get_tree().physics_frame
	var vel: Vector2 = a.velocity
	_runner.assert_true(vel.x >= -1.0, "对顶友军时不倒走（分离不反转意图），vel=%s" % str(vel))
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
	await get_tree().physics_frame
	a.ai_move(Vector2(1, 0), false)
	await get_tree().physics_frame
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
