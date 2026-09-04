extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：9i+ 溃逃保真五项增强（P6 · 6.3）。
## 覆盖：五开关默认关（零回归闸门）/ 数值默认值 / 可覆盖开启 / TeamAi 姿态查询接口。
## 不进场景树，确定性（纯档案 + 接口存在性验证）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("9i+ 四开关默认全关（零回归闸门）", _test_defaults_off)
	_runner.add_test("近战兵种包抄开启（Demo P5 灵动化）", _test_flank_melee_on)
	_runner.add_test("9i+ 数值字段默认值", _test_numeric_defaults)
	_runner.add_test("re_engage_morale < 低士气阈值 0.25", _test_reengage_morale_bound)
	_runner.add_test("9i+ 开关可覆盖开启", _test_override_on)
	_runner.add_test("TeamAi get_stance 接口存在", _test_team_ai_stance_iface)
	_runner.add_test("TeamAi 姿态枚举对齐", _test_stance_enum_align)
	_runner.add_test("档案缓存不污染后续查询", _test_cache_isolation)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_defaults_off() -> void:
	# 零回归闸门：所有兵种档案的 9i+ 开关默认 false
	# （flank_enabled 已拆出：Demo P5 起近战兵种有意开启，由 _test_flank_melee_on 单独守护）
	var switches: Array = [
		"rout_reengage_enabled",
		"retreat_keep_block",
		"rout_strafe_enabled",
		"test_engage_enabled",
	]
	for wtype in [ScriptBehaviorProfiles.SWORD, ScriptBehaviorProfiles.SPEAR,
			ScriptBehaviorProfiles.BOW, ScriptBehaviorProfiles.STAFF,
			ScriptBehaviorProfiles.PICKAXE]:
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		for sw in switches:
			_runner.assert_false(bool(p.get(sw, true)), "%s 默认关 (wtype=%d)" % [sw, wtype])


## Demo P5 灵动化契约：包抄仅近战兵种开启（剑/矛），远程与工具兵种保持关
func _test_flank_melee_on() -> void:
	for wtype in [ScriptBehaviorProfiles.SWORD, ScriptBehaviorProfiles.SPEAR]:
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		_runner.assert_true(bool(p.get("flank_enabled", false)), "近战包抄应开启 (wtype=%d)" % wtype)
	for wtype in [ScriptBehaviorProfiles.BOW, ScriptBehaviorProfiles.STAFF,
			ScriptBehaviorProfiles.PICKAXE]:
		var p2: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		_runner.assert_false(bool(p2.get("flank_enabled", false)), "非近战包抄应保持关 (wtype=%d)" % wtype)


func _test_numeric_defaults() -> void:
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(p.get("re_engage_morale", -1.0)), 0.15, 0.001, "re_engage_morale=0.15")
	_runner.assert_approx(float(p.get("rout_strafe_strength", -1.0)), 0.35, 0.001, "rout_strafe_strength=0.35")
	_runner.assert_approx(float(p.get("test_pulse_on", -1.0)), 2.0, 0.001, "test_pulse_on=2.0")
	_runner.assert_approx(float(p.get("test_pulse_off", -1.0)), 3.0, 0.001, "test_pulse_off=3.0")
	_runner.assert_approx(float(p.get("test_engage_range", -1.0)), 480.0, 0.001, "test_engage_range=480.0")
	_runner.assert_approx(float(p.get("flank_y_offset", -1.0)), 120.0, 0.001, "flank_y_offset=120.0")
	_runner.assert_approx(float(p.get("flank_side_strength", -1.0)), 0.40, 0.001, "flank_side_strength=0.40")


func _test_reengage_morale_bound() -> void:
	# re_engage_morale 必须 < 低士气阈值 0.25 才能在脱战分支内触发
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	var re_engage: float = float(p.get("re_engage_morale", 1.0))
	_runner.assert_lt(re_engage, 0.25, "re_engage_morale < 0.25 低士气阈值")


func _test_override_on() -> void:
	# 验证 CLASS_PROFILES 覆盖机制：STAFF 有 kite_range=0.0 覆盖
	var staff: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.STAFF)
	_runner.assert_approx(float(staff.get("kite_range", -1.0)), 0.0, 0.001, "STAFF kite_range=0.0 覆盖")
	# 9i+ 开关可通过档案覆盖开启（模拟 battle_sim 扫参）
	# 直接修改缓存中的档案（battle_sim 扫参先例）
	var sword: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	sword["rout_reengage_enabled"] = true
	_runner.assert_true(bool(sword.get("rout_reengage_enabled", false)), "可覆盖开启 rout_reengage")


func _test_team_ai_stance_iface() -> void:
	# TeamAi.get_stance() 接口存在且返回有效姿态值
	var battle := _FakeBattle.new()
	var ai := ScriptTeamAi.new()
	ai.setup(battle, 1, null, null, {})
	var stance: int = ai.get_stance()
	_runner.assert_true(stance >= 0 and stance <= 2, "get_stance 返回 0~2")
	_runner.assert_equal(stance, ScriptTeamAi.STANCE_DEFEND, "初始 DEFEND")
	# get_stance_reason 接口
	_runner.assert_equal(ai.get_stance_reason(), "init", "初始原因 init")
	# get_garrison_anchor 接口
	var anchor: Vector2 = ai.get_garrison_anchor()
	_runner.assert_approx(anchor.x, 500.0, 1.0, "锚点 x=500")
	ai.dispose()
	battle.queue_free()


func _test_stance_enum_align() -> void:
	# TeamAi 姿态枚举与 TeamAiProfiles 对齐
	_runner.assert_equal(ScriptTeamAi.STANCE_GARRISON, ScriptTeamAiProfiles.STANCE_GARRISON, "GARRISON 对齐")
	_runner.assert_equal(ScriptTeamAi.STANCE_DEFEND, ScriptTeamAiProfiles.STANCE_DEFEND, "DEFEND 对齐")
	_runner.assert_equal(ScriptTeamAi.STANCE_ATTACK, ScriptTeamAiProfiles.STANCE_ATTACK, "ATTACK 对齐")
	_runner.assert_equal(ScriptTeamAi.STANCE_GARRISON, 0, "GARRISON=0")
	_runner.assert_equal(ScriptTeamAi.STANCE_DEFEND, 1, "DEFEND=1")
	_runner.assert_equal(ScriptTeamAi.STANCE_ATTACK, 2, "ATTACK=2")


func _test_cache_isolation() -> void:
	# 档案缓存返回同一引用（RWR 制：运行时修改即生效，battle_sim 扫参先例）
	var p1: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	var p2: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	_runner.assert_true(p1 == p2, "同兵种档案缓存一致")


# ─────────────────────────────── Mock 夹具 ────────────────────────────────

class _FakeBattle extends Node:
	var duration: float = 0.0
	var _units: Array = []
	var _anchor_faction1 := Vector2(500, 300)
	var _anchor_faction2 := Vector2(1500, 300)

	func get_allies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction == faction)

	func get_enemies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction != faction)

	func get_duration() -> float:
		return duration

	func is_active() -> bool:
		return true

	func get_battle_id() -> String:
		return "test_battle"

	func get_faction_side_anchor(faction: int) -> Vector2:
		return _anchor_faction1 if faction == 1 else _anchor_faction2