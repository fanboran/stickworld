extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：A9 个体 AI 参数面板（设计文档12号 §2.2 R1~R5，AI集大成）。
## 覆盖：R2 兵种人格覆盖档 BalanceConfig 装载与合并序（代码基线 ← SWL 直译
## 兵种覆盖 ← .tres 行覆盖，引用比对热失效）/ R1 决策间隔族（默认零回归、
## 方差界内、下限钳制）/ R3 点射门禁与夜间判定 / R5 防扎堆治疗过滤与登记 /
## R4 权威值评分与换班滞回。
## 不进场景树主流程（确定性：档案注入 + 时间戳拨针；BalanceConfig autoload
## 注入行后须还原，先例 test_team_ai_personality）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")
const ScriptBehaviorHeal := preload("res://modules/units/scripts/ai/behavior_heal.gd")
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("R2 .tres 装载 baseline 行（A9 新键组）", _test_tres_loaded)
	_runner.add_test("R2 覆盖链：baseline 行覆盖代码默认", _test_overlay_baseline)
	_runner.add_test("R2 覆盖链：兵种行只对对应兵种生效", _test_overlay_class_row)
	_runner.add_test("R2 覆盖链：行数组引用变化即热失效重合并", _test_overlay_hot_reload)
	_runner.add_test("R2 缺载回退代码默认 + SWL 直译个性保留", _test_overlay_fallback_swl)
	_runner.add_test("R1 决策间隔：默认档案 0.3 恒定（零回归）", _test_r1_default)
	_runner.add_test("R1 决策间隔：方差界内 + 下限钳制", _test_r1_variance)
	_runner.add_test("R3 点射门禁：关=恒真（零回归）", _test_r3_gate_off)
	_runner.add_test("R3 点射门禁：计数到点插停顿、窗口过恢复", _test_r3_gate_cycle)
	_runner.add_test("R3 夜间判定：无环境=白天（保守），假环境黑/白分界", _test_r3_is_night)
	_runner.add_test("R5 防扎堆：过滤被登记伤员、过期恢复", _test_r5_skip_being_healed)
	_runner.add_test("R5 施放登记：HOT 时长 + 缓冲写入目标", _test_r5_mark)
	_runner.add_test("R4 权威值：无班 -INF、评分组合", _test_r4_authority)
	_runner.add_test("R4 换班滞回：margin 界内不动、界外换", _test_r4_switch_margin)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── R2 覆盖链 ────────────────────────────────

func _test_tres_loaded() -> void:
	_runner.assert_approx(BalanceConfig.get_value("ai.behavior_profiles.baseline.decision_interval"), 0.3, 0.001,
			"baseline.decision_interval = 0.3（R1 镜像旧常量）")
	_runner.assert_approx(BalanceConfig.get_value("ai.behavior_profiles.baseline.decision_variance"), 0.0, 0.001,
			"baseline.decision_variance = 0（零回归）")
	_runner.assert_equal(int(BalanceConfig.get_value("ai.behavior_profiles.baseline.burst_shots")), 0,
			"baseline.burst_shots = 0（R3 关）")
	var wait: Variant = BalanceConfig.get_value("ai.behavior_profiles.baseline.burst_wait")
	_runner.assert_true(wait is Vector2 and wait.is_equal_approx(Vector2(1.2, 1.8)), "baseline.burst_wait = 1.2~1.8")
	_runner.assert_approx(BalanceConfig.get_value("ai.behavior_profiles.baseline.heal_buzz_distance"), 60.0, 0.001,
			"baseline.heal_buzz_distance = 60px（R5）")


func _inject_rows(rows: Array) -> void:
	BalanceConfig.data["ai.behavior_profiles"] = rows
	ScriptBehaviorProfiles._cache.clear()


func _restore_rows() -> void:
	# 走装载器同款清理（类型键 + 前缀行键 + _type_paths 同步）后按 .tres 原样回装。
	# W1 修复：原实现只清不装（假定该类型不在 autoload 数据中），而
	# config/ai/behavior_profiles.tres 是 BalanceConfig 常驻数据——套件跑完净减
	# 2 键，污染后续 test_balance_config 的 reload 幂等断言（此前被本文件的
	# entity 类型解析错误掩盖：套件整体加载失败没跑，修复后暴露）。
	BalanceConfig._remove_type_data("ai.behavior_profiles")
	BalanceConfig._load_tres("res://config/ai/behavior_profiles.tres", "ai.behavior_profiles")
	ScriptBehaviorProfiles._cache.clear()


func _test_overlay_baseline() -> void:
	_inject_rows([{"id": "baseline", "decision_interval": 0.45, "burst_shots": 3}])
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(p.get("decision_interval", -1.0)), 0.45, 0.001, "baseline 行覆盖 decision_interval")
	_runner.assert_equal(int(p.get("burst_shots", -1)), 3, "baseline 行覆盖 burst_shots")
	_restore_rows()


func _test_overlay_class_row() -> void:
	# 兵种行只对对应兵种生效；baseline 行对所有兵种生效
	_inject_rows([
		{"id": "baseline", "decision_interval": 0.45},
		{"id": "bow", "leash_mult": 9.0},
	])
	var sword: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	var bow: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	_runner.assert_approx(float(sword.get("decision_interval", -1.0)), 0.45, 0.001, "baseline 行对剑士生效")
	_runner.assert_approx(float(sword.get("leash_mult", -1.0)), 6.0, 0.001, "bow 行不污染剑士（剑士直译 6.0）")
	_runner.assert_approx(float(bow.get("leash_mult", -1.0)), 9.0, 0.001, "bow 行对弓手生效")
	_restore_rows()


func _test_overlay_hot_reload() -> void:
	var rows_a: Array = [{"id": "baseline", "decision_interval": 0.45}]
	var rows_b: Array = [{"id": "baseline", "decision_interval": 0.6}]
	_inject_rows(rows_a)
	var first: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(first.get("decision_interval", -1.0)), 0.45, 0.001, "首轮合并取行 A")
	# reload 语义 = data 重建（引用变化）：直接换引用模拟，不改缓存
	BalanceConfig.data["ai.behavior_profiles"] = rows_b
	var second: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(second.get("decision_interval", -1.0)), 0.6, 0.001, "行引用变化 → 重合并取行 B")
	_restore_rows()


func _test_overlay_fallback_swl() -> void:
	_restore_rows()  # 无配置路径 → 代码默认
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(p.get("decision_interval", -1.0)), 0.3, 0.001, "缺载回落代码基线 0.3")
	# SWL 直译个性不被覆盖链打掉（P6 批次 7c 语义：剑士冲脸/弓手风筝/矛兵持阵）
	_runner.assert_approx(float(p.get("aggressive_push_prob", -1.0)), 0.25, 0.001, "剑士冲脸概率直译保留")
	var bow: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	_runner.assert_approx(float(bow.get("kite_range", -1.0)), 500.0, 0.001, "弓手保距直译保留")
	var spear: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SPEAR)
	_runner.assert_true(bool(spear.get("formation_block", false)), "矛兵行军举盾直译保留")


# ─────────────────────────────── R1 决策间隔族 ────────────────────────────────

func _test_r1_default() -> void:
	_restore_rows()
	var ai: AIController = ScriptAIController.new()
	# 默认档案 decision_variance=0 → 掷骰恒等于基值 0.3（与旧 DECISION_INTERVAL 常量一致）
	for i in 8:
		_runner.assert_approx(ai._roll_decision_interval(), 0.3, 0.0001, "默认间隔恒 0.3（第 %d 掷）" % i)
	ai.free()


func _test_r1_variance() -> void:
	# 注入 sword 行：0.5 ± 0.2 → 采样必落于 [0.3, 0.7]
	_inject_rows([{"id": "sword", "decision_interval": 0.5, "decision_variance": 0.2}])
	var ai: AIController = ScriptAIController.new()
	var lo: float = 2.0
	var hi: float = -2.0
	for i in 64:
		var v: float = ai._roll_decision_interval()
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_runner.assert_true(lo >= 0.3 - 0.0001 and hi <= 0.7 + 0.0001,
			"方差界内 [0.3, 0.7]（实测 %.3f~%.3f）" % [lo, hi])
	_restore_rows()
	# 钳下限：0.01 ± 0.5 → 掷骰可能为负，必须钳到 MIN_DECISION_INTERVAL=0.05
	_inject_rows([{"id": "sword", "decision_interval": 0.01, "decision_variance": 0.5}])
	for i in 64:
		var v2: float = ai._roll_decision_interval()
		if v2 < 0.05 - 0.0001:
			_runner.assert_true(false, "间隔低于下限 0.05（实测 %.3f）" % v2)
			break
	_runner.assert_true(true, "下限钳制 ≥ 0.05")
	ai.free()
	_restore_rows()


# ─────────────────────────────── R3 点射节奏 ────────────────────────────────

func _test_r3_gate_off() -> void:
	var atk: BehaviorAttack = ScriptBehaviorAttack.new()
	atk._profile = {"burst_shots": 0}
	for i in 5:
		atk._register_burst_shot()
	_runner.assert_true(atk._burst_gate(), "burst_shots=0 门禁恒真（零回归）")
	atk.free()


func _test_r3_gate_cycle() -> void:
	var atk: BehaviorAttack = ScriptBehaviorAttack.new()
	atk._profile = {"burst_shots": 3, "burst_wait": Vector2(0.05, 0.1)}
	# 连射 3 发内门禁恒真
	for i in 3:
		_runner.assert_true(atk._burst_gate(), "第 %d 发可出手" % (i + 1))
		atk._register_burst_shot()
	# 达 3 发 → 插停顿，门禁关
	_runner.assert_true(not atk._burst_gate(), "达点数后停顿窗内禁射")
	# 停顿窗过（拨针）→ 恢复，计数清零可再连 3 发
	atk._burst_wait_until = Time.get_ticks_msec() / 1000.0 - 1.0
	_runner.assert_true(atk._burst_gate(), "停顿窗过恢复出手")
	for i in 2:
		atk._register_burst_shot()
	_runner.assert_true(atk._burst_gate(), "计数已清零，未达点数仍可出手")
	atk.free()


func _test_r3_is_night() -> void:
	var atk: BehaviorAttack = ScriptBehaviorAttack.new()
	add_child(atk)
	# entity 形类型桩（CharacterBody2D）：_is_night 只经它取树；无
	# GameRoot/EnvironmentSystem 恒判白天。W1 修复：原 `atk.entity = self`
	# （Node→CharacterBody2D 字段）在类缓存重建后暴露为解析错误。
	var body := CharacterBody2D.new()
	add_child(body)
	atk.entity = body
	# 查询不可用（无 GameRoot/EnvironmentSystem）→ 白天（保守零回归）
	_runner.assert_true(not atk._is_night(), "无环境节点 = 白天")
	# 假环境：黑色（夜）→ true；白色（昼）→ false
	var game_root := Node.new()
	game_root.name = "GameRoot"
	var env := _FakeEnv.new()
	env.name = "EnvironmentSystem"
	game_root.add_child(env)
	get_tree().root.add_child(game_root)
	env.light = Color(0.01, 0.01, 0.02)  # 亮度 ≈ 0.01 < 0.55
	_runner.assert_true(atk._is_night(), "暗环境 = 夜")
	env.light = Color(1.0, 1.0, 1.0)
	_runner.assert_true(not atk._is_night(), "亮环境 = 昼")
	get_tree().root.remove_child(game_root)
	game_root.free()
	remove_child(atk)
	atk.free()
	remove_child(body)
	body.free()


class _FakeEnv extends Node:
	var light: Color = Color.WHITE

	func get_current_light_color() -> Color:
		return light


# ─────────────────────────────── R5 防扎堆治疗 ────────────────────────────────

func _test_r5_skip_being_healed() -> void:
	var battle := _FakeBattle.new()
	battle.add_unit(1, 0.2)  # A：重伤
	battle.add_unit(1, 0.5)  # B：中伤
	var healer := _FakeUnit.new()
	healer.faction = 1
	# 过滤关（默认）：血量最低优先 → A
	var t1: Node = ScriptTargetFinder.find_weakest_ally(healer, {"battle": battle})
	_runner.assert_equal(t1, battle.units[0], "不过滤时选血量最低 A")
	# 过滤开 + A 被登记（未过期）→ 让给 B（多祭司不扎堆）
	battle.units[0].set("being_healed_until", Time.get_ticks_msec() / 1000.0 + 5.0)
	var t2: Node = ScriptTargetFinder.find_weakest_ally(healer, {"battle": battle, "skip_being_healed": true})
	_runner.assert_equal(t2, battle.units[1], "被登记伤员跳过，选 B")
	# A 登记过期 → 恢复可选
	battle.units[0].set("being_healed_until", Time.get_ticks_msec() / 1000.0 - 1.0)
	var t3: Node = ScriptTargetFinder.find_weakest_ally(healer, {"battle": battle, "skip_being_healed": true})
	_runner.assert_equal(t3, battle.units[0], "登记过期恢复可选 A")
	battle.free()
	healer.free()


func _test_r5_mark() -> void:
	var heal: BehaviorHeal = ScriptBehaviorHeal.new()
	heal._profile = {"heal_duration": 3.0}
	var tgt := _FakeHealTarget.new()
	heal._mark_being_healed(tgt)
	var now: float = Time.get_ticks_msec() / 1000.0
	_runner.assert_true(tgt.being_healed_until > now + 3.0 and tgt.being_healed_until <= now + 3.6,
			"登记 = now + HOT 时长 + 缓冲（实测 %.2f，now+3=%.2f）" % [tgt.being_healed_until, now + 3.0])
	tgt.free()
	heal.free()


# ─────────────────────────────── R4 权威值择班 ────────────────────────────────

func _make_fs(org: _FakeOrgApi) -> FormationSystem:
	var fs: FormationSystem = ScriptFormationSystem.new()
	fs.setup(org)
	return fs


func _test_r4_authority() -> void:
	var org := _FakeOrgApi.new()
	var fs := _make_fs(org)
	_runner.assert_true(is_inf(fs.get_squad_authority("none")) and fs.get_squad_authority("none") < 0,
			"无班 = -INF")
	# 注入一个空班（无班长/无指挥官）
	fs._squads["s1"] = {"units": [], "leader": null, "preset_id": "squad_combat",
			"work_types": [], "role": "fighter", "name": "s1",
			"follow_squad_id": "", "follow_gap": 0.0, "slots": {}}
	_runner.assert_approx(fs.get_squad_authority("s1"), 0.0, 0.001, "空班 = 0")
	# 班长在场 → 1.0；附身 → +0.2 玩家光环
	var leader := _FakeUnit.new()
	fs._squads["s1"]["leader"] = leader
	_runner.assert_approx(fs.get_squad_authority("s1"), 1.0, 0.001, "有班长 = 1.0")
	leader.possessed = true
	_runner.assert_approx(fs.get_squad_authority("s1"), 1.2, 0.001, "班长被附身 = +0.2 玩家光环")
	leader.possessed = false
	# 组织指挥官在册 → +0.5
	org.commander_id = "7"
	_runner.assert_approx(fs.get_squad_authority("s1"), 1.5, 0.001, "指挥官在册 = +0.5")
	fs.free()
	org.free()


func _test_r4_switch_margin() -> void:
	var fs := _make_fs(_FakeOrgApi.new())
	# margin 0.07：界内不换（防来回跳），界外换
	_runner.assert_true(not fs.should_switch_squad(1.0, 1.05), "权威差 0.05 < margin 不换")
	_runner.assert_true(not fs.should_switch_squad(1.0, 1.07), "权威差 = margin 不换（严格大于）")
	_runner.assert_true(fs.should_switch_squad(1.0, 1.08), "权威差 0.08 > margin 换")
	# 无班（-INF）：任何有限权威候选班都值得进（-INF + margin 仍 -INF）
	_runner.assert_true(fs.should_switch_squad(-INF, 0.5), "无班单位可进任何班")
	fs.free()


class _FakeOrgApi extends Node:
	var commander_id: String = ""

	func get_organization(_org_id: String) -> Dictionary:
		if commander_id.is_empty():
			return {}
		return {"id": _org_id, "commander_id": commander_id}


class _FakeHealTarget extends Node2D:
	var being_healed_until: float = -1.0e9


class _FakeUnit extends Node2D:
	var faction: int = 0
	var possessed: bool = false

	func is_dead() -> bool:
		return false

	func get_faction() -> int:
		return faction

	func is_possessed() -> bool:
		return possessed

	func get_hp_ratio() -> float:
		return 1.0


class _FakeBattle extends Node:
	var units: Array = []

	func add_unit(faction: int, ratio: float) -> void:
		var u := _FakeWounded.new()
		u.faction = faction
		u.ratio = ratio
		units.append(u)

	func get_alive_allies_of(faction: int) -> Array:
		return units.filter(func(u) -> bool: return u.faction == faction and not u.is_dead())

	func get_allies_of(faction: int) -> Array:
		return get_alive_allies_of(faction)


class _FakeWounded extends Node2D:
	var faction: int = 0
	var ratio: float = 1.0
	var being_healed_until: float = -1.0e9

	func is_dead() -> bool:
		return false

	func get_faction() -> int:
		return faction

	# get_health 返回自身 + get_hp_ratio：对齐 TargetFinder._hp_ratio 消费协议
	func get_health() -> Node:
		return self

	func get_hp_ratio() -> float:
		return ratio
