extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：A6 · C9 压制=定时锁死（设计文档12号 §三C9 / §五批次表 A6，AI集大成；
## CoH pinned-reaction-plan isInterruptablePlan=false + 等 7.5s 真值见逆向笔记 §4.2）。
## 覆盖：档案新键默认值（开关默认关=零回归）/ SUPPRESSED 状态落地与过期 / 触发门槛
## （远程命中/近战重击/格挡残余不触发）/ 豁免规则（溃逃/死亡/附身/兵种免疫）/
## 同 type 刷新不叠加 / 压制期士气流失（不伤血）/ ai_controller 禁令（强制停滞+
## 号令挂起续行）/ 强制溃逃链优先 / 无组件零回归 / behavior_attack 在途兜底 /
## squad_phase_plan 真实压制替换点 / **箭矢近失压制**（开关关零回归、总门约束、
## 半径内外边界、豁免集复用、只压制不伤害）。
## 确定性：压制链无掷骰（触发/禁令/解除续行全确定；BehaviorIdle 时长随机不影响
## 断言语义）。不进场景树（fixture 用 new() + 直注入，StatusEffects 经
## _owner 注入 + _connect_suppression_trigger 直调，test_meric_heal 先例）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")
const ScriptSquadPhasePlan := preload("res://modules/combat/scripts/command/squad_phase_plan.gd")
const ScriptArrowProjectile := preload("res://modules/units/scripts/weapons/arrow_projectile.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("A6 档案新键默认值（开关默认关 = 零回归）", _test_profile_defaults)
	_runner.add_test("SUPPRESSED 状态落地：apply/查询/过期/list_active", _test_suppressed_state)
	_runner.add_test("开关门控：默认关时受击不压制（零回归门）", _test_gate_off)
	_runner.add_test("触发：弓手命中达下限压制 / 格挡残余不压制", _test_ranged_trigger)
	_runner.add_test("触发：近战重击达下限压制 / 轻击不压制", _test_melee_trigger)
	_runner.add_test("豁免：已溃逃/已死亡/玩家附身/兵种免疫", _test_exemptions)
	_runner.add_test("同 type 刷新不叠加：再受击重置时长", _test_refresh)
	_runner.add_test("士气流失：压制期 tick 经 lose_morale，不伤血", _test_morale_drain)
	_runner.add_test("ai_controller 禁令：强制停滞 + 号令挂起，解除后续行", _test_ban_stall_order)
	_runner.add_test("强制溃逃链优先：压制期溃逃照样跑", _test_rout_priority)
	_runner.add_test("零回归：无状态效果组件实体决策原样", _test_no_component_regression)
	_runner.add_test("behavior_attack 兜底：压制期在途行为立即停", _test_attack_segment)
	_runner.add_test("squad_phase_plan 替换点：压制成员跳过/未压制走代理", _test_phase_plan)
	_runner.add_test("A6 近失压制：档案默认关 + 半径键约束", _test_near_miss_defaults)
	_runner.add_test("A6 近失压制：总门关/近失门关不压制（零回归）", _test_near_miss_gate_off)
	_runner.add_test("A6 近失压制：半径内触发 / 半径外与友军不触发", _test_near_miss_radius)
	_runner.add_test("A6 近失压制：豁免集复用（溃逃/死亡/附身/兵种免疫）", _test_near_miss_exemptions)
	_runner.add_test("A6 近失压制：只压制不伤害（命中路径语义不受影响）", _test_near_miss_no_damage)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────
# A6 近失压制（箭矢投射物侧；压制主体用例见下）

func _test_near_miss_defaults() -> void:
	_runner.assert_false(bool(ScriptBehaviorProfiles.BASELINE.get("suppression_near_miss_enabled", true)),
			"suppression_near_miss_enabled 基线默认关（零回归）")
	_reset_profile_cache()
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	_runner.assert_false(bool(p.get("suppression_near_miss_enabled", true)),
			"弓手近失门默认关（.tres baseline 行覆盖后仍关）")
	var radius: float = float(p.get("suppression_near_miss_radius", 0.0))
	_runner.assert_true(radius > ScriptArrowProjectile.HIT_RADIUS,
			"近失半径须大于命中半径 34（实测 %.1f）" % radius)
	_runner.assert_approx(radius, 80.0, 0.001, "近失半径档案初值 80px")
	_reset_profile_cache()


func _test_near_miss_gate_off() -> void:
	# 总门关：近失门即使开也不压制（近失受既有 suppression_enabled 约束）
	_arm_near_miss_profiles(true, 80.0, false)
	var v1 := _make_near_miss_victim(Vector2(20.0, 0.0))
	var s1 := _make_shooter(ScriptBehaviorProfiles.BOW)
	var a1: ArrowProjectile = _nfire(Vector2.ZERO, [v1], s1)
	_runner.assert_equal(a1.try_near_miss_suppression(), 0, "总门关：近失施加数为 0")
	_runner.assert_false(v1.effects.has_suppressed(), "总门关：落点近失不压制")
	a1.free()
	s1.free()
	_free_victim(v1)

	# 近失门关（默认）：总门开也不压制——受击命中才是既有触发源
	_arm_near_miss_profiles(false, 80.0, true)
	var v2 := _make_near_miss_victim(Vector2(20.0, 0.0))
	var s2 := _make_shooter(ScriptBehaviorProfiles.BOW)
	var a2: ArrowProjectile = _nfire(Vector2.ZERO, [v2], s2)
	_runner.assert_equal(a2.try_near_miss_suppression(), 0, "近失门关：施加数为 0")
	_runner.assert_false(v2.effects.has_suppressed(), "近失门关：落点近失不压制（零回归）")
	a2.free()
	s2.free()
	_free_victim(v2)
	_reset_profile_cache()


func _test_near_miss_radius() -> void:
	_arm_near_miss_profiles(true, 80.0, true)
	var inside := _make_near_miss_victim(Vector2(60.0, 0.0))     # 60 ≤ 80
	var edge := _make_near_miss_victim(Vector2(80.0, 0.0))       # 恰在半径上（含）
	var outside := _make_near_miss_victim(Vector2(80.5, 0.0))    # > 80
	var ally := _make_near_miss_victim(Vector2(10.0, 0.0))
	ally.faction = 1  # 同阵营（射手 faction=1）
	var shooter := _make_shooter(ScriptBehaviorProfiles.BOW)
	var arrow: ArrowProjectile = _nfire(Vector2.ZERO, [inside, edge, outside, ally], shooter)
	var applied: int = arrow.try_near_miss_suppression()
	_runner.assert_equal(applied, 2, "近失只压制半径内敌人（半径上计入；半径外/友军不计）")
	_runner.assert_true(inside.effects.has_suppressed(), "半径内（60 ≤ 80）触发压制")
	_runner.assert_true(edge.effects.has_suppressed(), "半径边界（恰 80）触发压制")
	_runner.assert_false(outside.effects.has_suppressed(), "半径外（80.5 > 80）不触发")
	_runner.assert_false(ally.effects.has_suppressed(), "友军不压制（不误伤）")
	arrow.free()
	shooter.free()
	for v in [inside, edge, outside, ally]:
		_free_victim(v)
	_reset_profile_cache()


func _test_near_miss_exemptions() -> void:
	# 新触发源复用受击路径同一豁免集（不因走通用入口而绕过）
	_arm_near_miss_profiles(true, 80.0, true)
	var routed := _make_near_miss_victim(Vector2(20.0, 0.0))
	routed.hp.routed = true
	var dead := _make_near_miss_victim(Vector2(20.0, 0.0))
	dead.dead = true
	var possessed := _make_near_miss_victim(Vector2(20.0, 0.0))
	possessed.possessed = true
	# 兵种级免疫：单开 STAFF 档置 immune（SWORD 档保持不免疫，隔离其余三类豁免判定）
	var staff: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.STAFF)
	staff["suppression_enabled"] = true
	staff["suppression_immune"] = true
	var immune := _make_near_miss_victim(Vector2(20.0, 0.0), ScriptBehaviorProfiles.STAFF)
	# 对照组：同装具但走 SWORD 档（不免疫）→ 近失压制正常施加
	var control := _make_near_miss_victim(Vector2(20.0, 0.0))
	var s3 := _make_shooter(ScriptBehaviorProfiles.BOW)
	var arrow: ArrowProjectile = _nfire(Vector2.ZERO, [routed, dead, possessed, immune], s3)
	var applied: int = arrow.try_near_miss_suppression()
	_runner.assert_equal(applied, 0, "四类豁免全部拒绝近失压制")
	_runner.assert_false(routed.effects.has_suppressed(), "已溃逃豁免（同受击路径）")
	_runner.assert_false(dead.effects.has_suppressed(), "已死亡豁免")
	_runner.assert_false(possessed.effects.has_suppressed(), "玩家附身豁免")
	_runner.assert_false(immune.effects.has_suppressed(), "兵种级 suppression_immune 豁免")
	var s4 := _make_shooter(ScriptBehaviorProfiles.BOW)
	var arrow2: ArrowProjectile = _nfire(Vector2.ZERO, [control], s4)
	_runner.assert_equal(arrow2.try_near_miss_suppression(), 1,
			"对照（不免疫档）：同一发近失正常压制——豁免来自档案而非入口失效")
	_runner.assert_true(control.effects.has_suppressed(), "对照单位被压制")
	arrow.free()
	arrow2.free()
	s3.free()
	s4.free()
	for v in [routed, dead, possessed, immune, control]:
		_free_victim(v)
	_reset_profile_cache()


func _test_near_miss_no_damage() -> void:
	# 近失压制只走行为禁令 + 士气流失通道：不产生伤害、不即时扣士气（tick 制），
	# 也不触碰命中路径参数（伤害量/锁定目标）——两条触发源互不污染
	_arm_near_miss_profiles(true, 80.0, true)
	var v := _make_near_miss_victim(Vector2(40.0, 0.0))
	var shooter := _make_shooter(ScriptBehaviorProfiles.BOW)
	var arrow: ArrowProjectile = _nfire(Vector2.ZERO, [v], shooter)
	arrow._stick_ground()
	_runner.assert_true(v.effects.has_suppressed(), "插地近失终态施加压制")
	_runner.assert_approx(v.hp.hp, 100.0, 0.0, "近失不产生伤害（hp 不变，未走 DamagePipeline）")
	_runner.assert_approx(v.hp.morale_lost, 0.0, 0.0, "近失不即时流失士气（0.5s tick 制）")
	_runner.assert_approx(arrow._damage, 10.0, 0.0, "近失不篡改箭矢伤害量")
	_runner.assert_true(arrow._target == null, "近失不改动锁定目标（命中路径前提不变）")
	arrow.free()
	shooter.free()
	_free_victim(v)
	_reset_profile_cache()


## A6 压制主体用例（受击门槛 / 禁令 / 替换点）
func _test_profile_defaults() -> void:
	_runner.assert_false(bool(ScriptBehaviorProfiles.BASELINE.get("suppression_enabled", true)),
			"suppression_enabled 基线默认关（零回归）")
	for wtype in [ScriptBehaviorProfiles.SWORD, ScriptBehaviorProfiles.SPEAR,
			ScriptBehaviorProfiles.BOW, ScriptBehaviorProfiles.STAFF,
			ScriptBehaviorProfiles.PICKAXE, ScriptBehaviorProfiles.MERIC]:
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		_runner.assert_false(bool(p.get("suppression_enabled", true)),
				"suppression_enabled 默认关 (wtype=%d)" % wtype)
	var p2: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(p2.get("suppression_duration", -1.0)), 4.5, 0.001,
			"压制时长 = 4.5s（CoH 7.5s × 节拍比 0.6 校准）")
	_runner.assert_approx(float(p2.get("suppression_ranged_min_damage", -1.0)), 4.0, 0.001,
			"远程命中触发下限 = 4.0（格挡残余 0.45~3 不触发）")
	_runner.assert_approx(float(p2.get("suppression_melee_min_damage", -1.0)), 12.0, 0.001,
			"近战重击触发下限 = 12.0（对齐 HIT_BIG_DAMAGE_THRESHOLD）")
	_runner.assert_approx(float(p2.get("suppression_morale_per_tick", -1.0)), 2.0, 0.001,
			"压制期士气流失 = 2.0/0.5s tick")
	_runner.assert_false(bool(p2.get("suppression_immune", true)), "兵种免疫豁免默认关")


func _test_suppressed_state() -> void:
	var se: StatusEffects = ScriptStatusEffects.new()
	se._owner = _SupEntity.new()
	se.apply(ScriptStatusEffects.Type.SUPPRESSED, 4.5, 2.0, null)
	_runner.assert_true(se.has_suppressed(), "apply 后 has_suppressed 为真")
	_runner.assert_true(se.has_effect(ScriptStatusEffects.Type.SUPPRESSED), "has_effect 同真")
	var active: Array = se.list_active()
	_runner.assert_equal(active.size(), 1, "list_active 仅压制一项")
	_runner.assert_equal(int(active[0]["type"]), ScriptStatusEffects.Type.SUPPRESSED,
			"list_active 类型正确")
	# 过期：白盒把 until 拨到过去（时间源为墙钟，测试不可快进——直拨状态）
	se._effects[ScriptStatusEffects.Type.SUPPRESSED]["until"] = se._now() - 1.0
	_runner.assert_false(se.has_suppressed(), "过期后 has_suppressed 为假")
	se.free()


func _test_gate_off() -> void:
	# 开关保持默认关（零回归基线）：重击/远程命中都不产生压制
	var ctx := _make_sup_ctx({})
	ctx.hit(20.0, _make_shooter())
	_runner.assert_false(ctx.se.has_suppressed(), "开关关：近战重击不压制")
	ctx.hit(8.0, _make_shooter(ScriptBehaviorProfiles.BOW))
	_runner.assert_false(ctx.se.has_suppressed(), "开关关：弓手命中不压制")
	ctx.teardown()


func _test_ranged_trigger() -> void:
	# 弓手命中 8 伤害（≥4 下限）→ 压制
	var ctx := _make_sup_ctx({"suppression_enabled": true})
	ctx.hit(8.0, _make_shooter(ScriptBehaviorProfiles.BOW))
	_runner.assert_true(ctx.se.has_suppressed(), "弓手命中 8 ≥ 4 → 压制")
	ctx.teardown()
	# 剑士（近战源）8 伤害 < 12 重击下限 → 不压制（量级不足）
	var ctx2 := _make_sup_ctx({"suppression_enabled": true})
	ctx2.hit(8.0, _make_shooter(ScriptBehaviorProfiles.SWORD))
	_runner.assert_false(ctx2.se.has_suppressed(), "近战源 8 伤害不压制")
	ctx2.teardown()
	# 格挡残余 1.5（< 4 下限）→ 不压制（"挡住的箭不压制"）
	var ctx3 := _make_sup_ctx({"suppression_enabled": true})
	ctx3.hit(1.5, _make_shooter(ScriptBehaviorProfiles.BOW))
	_runner.assert_false(ctx3.se.has_suppressed(), "格挡残余 1.5 不压制")
	ctx3.teardown()


func _test_melee_trigger() -> void:
	# 近战重击 12（= HIT_BIG_DAMAGE_THRESHOLD）→ 压制；轻击 5（近战源）→ 不压制
	var ctx := _make_sup_ctx({"suppression_enabled": true})
	ctx.hit(12.0, _make_shooter(ScriptBehaviorProfiles.SWORD))
	_runner.assert_true(ctx.se.has_suppressed(), "近战重击 12 ≥ 12 → 压制")
	ctx.teardown()
	var ctx2 := _make_sup_ctx({"suppression_enabled": true})
	ctx2.hit(5.0, _make_shooter(ScriptBehaviorProfiles.SWORD))
	_runner.assert_false(ctx2.se.has_suppressed(), "近战轻击 5 不压制")
	ctx2.teardown()


func _test_exemptions() -> void:
	# 已溃逃：强制溃逃链优先，压制不施加
	var ctx := _make_sup_ctx({"suppression_enabled": true})
	ctx.health.routed = true
	ctx.hit(20.0, _make_shooter())
	_runner.assert_false(ctx.se.has_suppressed(), "已溃逃豁免")
	ctx.teardown()
	# 兵种免疫
	var ctx2 := _make_sup_ctx({"suppression_enabled": true, "suppression_immune": true})
	ctx2.hit(20.0, _make_shooter())
	_runner.assert_false(ctx2.se.has_suppressed(), "suppression_immune 豁免")
	ctx2.teardown()
	# 已死亡
	var ctx3 := _make_sup_ctx({"suppression_enabled": true})
	ctx3.entity.dead = true
	ctx3.hit(20.0, _make_shooter())
	_runner.assert_false(ctx3.se.has_suppressed(), "已死亡豁免")
	ctx3.teardown()
	# 玩家附身
	var ctx4 := _make_sup_ctx({"suppression_enabled": true})
	ctx4.entity.possessed = true
	ctx4.hit(20.0, _make_shooter())
	_runner.assert_false(ctx4.se.has_suppressed(), "玩家附身豁免")
	ctx4.teardown()


func _test_refresh() -> void:
	# 同 type 刷新不叠加（既有 apply 语义）：再受击 → until 后移（时长重置），
	# 效果仍只有一项
	var ctx := _make_sup_ctx({"suppression_enabled": true})
	ctx.hit(8.0, _make_shooter(ScriptBehaviorProfiles.BOW))
	_runner.assert_true(ctx.se.has_suppressed(), "首箭压制")
	var until_1: float = float(ctx.se._effects[ScriptStatusEffects.Type.SUPPRESSED]["until"])
	ctx.hit(8.0, _make_shooter(ScriptBehaviorProfiles.BOW))
	_runner.assert_equal(ctx.se._effects.size(), 1, "同 type 不叠加（仍一项）")
	var until_2: float = float(ctx.se._effects[ScriptStatusEffects.Type.SUPPRESSED]["until"])
	_runner.assert_true(until_2 >= until_1, "刷新后时长重置（until 不前移）")
	ctx.teardown()


func _test_morale_drain() -> void:
	# power = 每 0.5s tick 士气流失点数；只损士气不伤血（lose_morale 语义）
	var ctx := _make_sup_ctx({})
	ctx.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 2.0, null)
	for i in 3:
		ctx.se._physics_process(0.5)  # 每次恰好跨一个 tick
	_runner.assert_approx(ctx.health.morale_lost, 6.0, 0.001, "3 tick × 2.0 = 流失 6")
	_runner.assert_approx(ctx.health.hp, 100.0, 0.001, "压制流失不伤血")
	# tick 未满间隔不结算
	var lost: float = ctx.health.morale_lost
	ctx.se._physics_process(0.2)
	_runner.assert_approx(ctx.health.morale_lost, lost, 0.001, "tick 未满不流失")
	ctx.teardown()


func _test_ban_stall_order() -> void:
	# 压制期：强制停滞（idle + ai_stop），号令挂起不清除；解除后号令自动续行
	var ctx := _make_ai_ctx({"suppression_enabled": true})
	ctx.ai.set_order("move", {"target": Vector2(1200, 300)})
	_runner.assert_equal(ctx.ai.get_current_behavior(), "move", "号令已下达")
	ctx.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 2.0, null)
	ctx.ai._make_decision()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "idle", "压制期强制停滞 idle")
	_runner.assert_true(ctx.entity.stopped, "压制期停步（ai_stop）")
	_runner.assert_equal(ctx.ai.get_ordered_behavior(), "move", "号令挂起不清除（玩家意图保留）")
	# 压制结束（白盒清效果）：命令覆盖段检测 cur != ordered 自动续行
	ctx.se._effects.erase(ScriptStatusEffects.Type.SUPPRESSED)
	ctx.entity.stopped = false
	ctx.ai._make_decision()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "move", "压制解除后号令续行")
	ctx.teardown()
	# 无号令压制：同样强制停滞
	var ctx2 := _make_ai_ctx({"suppression_enabled": true})
	ctx2.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 2.0, null)
	ctx2.ai._make_decision()
	_runner.assert_equal(ctx2.ai.get_current_behavior(), "idle", "无号令压制期强制停滞")
	ctx2.teardown()


func _test_rout_priority() -> void:
	# 强制溃逃链 > 压制禁令：士气崩溃的压制单位照样跑（禁令是"不敢动"不是"不能逃"）
	var ctx := _make_ai_ctx({"suppression_enabled": true})
	ctx.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 2.0, null)
	ctx.health.routed = true
	ctx.ai._make_decision()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "retreat", "压制期溃逃优先（retreat）")
	ctx.teardown()


func _test_no_component_regression() -> void:
	# 无 get_status_effects 的实体（测试桩/未装配）：_is_suppressed 恒 false，
	# 决策链原样进 attack（零回归）
	var ctx := _make_ai_ctx({}, false)
	ctx.ai._make_decision()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "attack", "无组件决策原样（attack）")
	ctx.teardown()


func _test_attack_segment() -> void:
	# 在途攻击行为兜底：压制发生（两拍之间）→ update 立即停且不 finish；
	# 对照：未压制 + 无战斗 → 走既有 finish 路径
	var ctx := _make_ai_ctx({"suppression_enabled": true})
	ctx.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 2.0, null)
	var attack: BehaviorAttack = ScriptBehaviorAttack.new()
	attack.entity = ctx.entity
	attack.enter("", {"battle": null})
	attack.update(0.016)
	_runner.assert_false(attack.is_finished(), "压制期在途攻击不完成（禁令接管）")
	_runner.assert_true(ctx.entity.stopped, "压制期在途攻击停步")
	attack.free()
	ctx.teardown()
	var ctx2 := _make_ai_ctx({}, false)
	var attack2: BehaviorAttack = ScriptBehaviorAttack.new()
	attack2.entity = ctx2.entity
	ctx2.entity.battle = null  # 先断开战斗（enter 回落 get_battle_instance，后断无效）
	attack2.enter("", {"battle": null})
	attack2.update(0.016)
	_runner.assert_true(attack2.is_finished(), "未压制无战斗走既有 finish 路径")
	attack2.free()
	ctx2.teardown()


func _test_phase_plan() -> void:
	# 真实压制替换点：压制成员被 _contact_reaction 跳过（禁令本体已锁死，
	# 不叠加 seek_cover 号令）；未压制成员被瞄准走既有 arrow_threat_time 轻量代理
	var plan: SquadPhasePlan = ScriptSquadPhasePlan.new()
	plan.setup(_PlanHost.new(), {"rng_seed": 7})
	# 压制成员（也被瞄准登记——最严苛场景）
	var sup_member := _make_plan_member()
	sup_member.se = ScriptStatusEffects.new()
	sup_member.se._owner = sup_member
	sup_member.se.apply(ScriptStatusEffects.Type.SUPPRESSED, 1000.0, 0.0, null)
	sup_member.arrow_threat_time = Time.get_ticks_msec() / 1000.0
	plan._contact_reaction([sup_member])
	_runner.assert_equal(sup_member.ai.orders.size(), 0, "压制成员不发 seek_cover（禁令本体已锁死）")
	# 未压制成员（仅被瞄准）→ 既有代理触发 seek_cover
	var proxy_member := _make_plan_member()
	proxy_member.arrow_threat_time = Time.get_ticks_msec() / 1000.0
	plan._contact_reaction([proxy_member])
	_runner.assert_equal(proxy_member.ai.orders_for("seek_cover"), 1, "未压制成员走 arrow_threat_time 代理")
	sup_member.free()
	proxy_member.free()
	plan.free()


# ─────────────────────────────── 夹具 ────────────────────────────────

## 档案覆盖（直改 SWORD 合并档案缓存引用，test_ai_retreat_modulation 先例；
## 用后 _reset_profile_cache 清缓存重合并恢复原值）
func _mod_profile(overrides: Dictionary) -> void:
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	for k in overrides.keys():
		p[k] = overrides[k]


func _reset_profile_cache() -> void:
	ScriptBehaviorProfiles._cache.clear()


## 压制触发夹具：真实 StatusEffects（_owner 注入 + 接线直调）挂到假实体
func _make_sup_ctx(profile_overrides: Dictionary) -> _SupCtx:
	var ctx := _SupCtx.new()
	ctx.setup(profile_overrides)
	return ctx


## 决策链夹具（AIController 直注入 _entity，test_ai_retreat_modulation 先例）；
## with_se=false 造无状态效果组件实体（零回归对照）
func _make_ai_ctx(profile_overrides: Dictionary, with_se: bool = true) -> _AiCtx:
	var ctx := _AiCtx.new()
	ctx.setup(profile_overrides, with_se)
	return ctx


func _make_shooter(wtype: int = ScriptBehaviorProfiles.SWORD) -> _Shooter:
	var s := _Shooter.new()
	s.weapon_type = wtype
	return s


func _make_plan_member() -> _PlanUnit:
	var u := _PlanUnit.new()
	u.global_position = Vector2(400, 300)
	return u


## 近失用例档案装配：射手（BOW）侧配总门/近失门/半径，受害者（SWORD）侧配总门。
## 直改合并档案缓存（_SupCtx 同款先例）；用后 _reset_profile_cache 清缓存重合并。
func _arm_near_miss_profiles(near_miss_enabled: bool, radius: float,
		shooter_total_gate: bool = true) -> void:
	_reset_profile_cache()
	var bow: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.BOW)
	bow["suppression_enabled"] = shooter_total_gate
	bow["suppression_near_miss_enabled"] = near_miss_enabled
	bow["suppression_near_miss_radius"] = radius
	var sw: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	sw["suppression_enabled"] = true
	sw["suppression_immune"] = false
	sw["suppression_duration"] = 4.5
	sw["suppression_morale_per_tick"] = 2.0


## 近失箭矢夹具：真实 ArrowProjectile（非树，候选经 near_miss_candidates_override
## 注入 = _stick_ground 调用点同款路径），setup 走生产入口解析射手档案快照
func _nfire(arrow_pos: Vector2, candidates: Array,
		shooter: _Shooter = null) -> ArrowProjectile:
	var s: _Shooter = shooter if shooter != null else _make_shooter(ScriptBehaviorProfiles.BOW)
	var arrow: ArrowProjectile = ScriptArrowProjectile.new()
	arrow.global_position = arrow_pos
	arrow.near_miss_candidates_override = candidates
	arrow.setup(Vector2.RIGHT * 640.0, 10.0, s, null)
	return arrow


## 近失受害者桩：真实 StatusEffects（_owner 注入）+ 显式 Collider 子节点 = 身体中心
func _make_near_miss_victim(body_center: Vector2,
		wtype: int = ScriptBehaviorProfiles.SWORD) -> _NearMissVictim:
	var v := _NearMissVictim.new()
	v.setup_victim(body_center, wtype)
	return v


func _free_victim(v: _NearMissVictim) -> void:
	v.effects.free()
	v.hp.free()
	v.free()


class _NearMissVictim extends _SupEntity:
	## 身体中心节点（Collider 语义）：_target_body_pos 优先读取，半径断言按身体中心直算
	var collider: Node2D = null
	## 类型化别名（基类 se/health 声明为 Node，鸭子面不便直接断言）
	var effects: StatusEffects = null
	var hp: _SupHealth = null

	func _init() -> void:
		var c := Node2D.new()
		c.name = "Collider"
		add_child(c)
		collider = c

	## 装配：faction=2（与射手 faction=1 敌对）+ 真状态效果部门 + 假生命组件
	func setup_victim(body_center: Vector2, wtype: int) -> void:
		faction = 2
		var w := _SupWeapon.new()
		w.weapon_type = wtype
		add_child(w)
		weapon = w
		hp = _SupHealth.new()
		health = hp
		effects = StatusEffects.new()
		effects._owner = self
		se = effects
		set_body_center(body_center)

	## 设置身体中心世界坐标（实体自身在原点 = collider.position 即世界位）
	func set_body_center(p: Vector2) -> void:
		collider.position = p


class _SupCtx:
	var entity: _SupEntity
	var health: _SupHealth
	var se: StatusEffects

	func setup(profile_overrides: Dictionary) -> void:
		ScriptBehaviorProfiles._cache.clear()
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
		p["suppression_enabled"] = bool(profile_overrides.get("suppression_enabled", false))
		for k in profile_overrides.keys():
			if k == "suppression_enabled":
				continue
			p[k] = profile_overrides[k]
		entity = _SupEntity.new()
		var w := _SupWeapon.new()
		entity.add_child(w)  # 挂子节点：entity.free() 一并释放（Node 须手动管理生命周期）
		entity.weapon = w
		health = _SupHealth.new()
		entity.health = health
		se = StatusEffects.new()
		se._owner = entity
		se._connect_suppression_trigger()
		entity.se = se

	## 测试受击入口：发射 damaged 后即收伤害源（Node 夹具即用即弃，防泄漏；
	## 源引用残留 _effects["source"] 无读取点，安全）
	func hit(amount: float, source: Node) -> void:
		health.take_hit(amount, source)
		if source != null:
			source.free()

	func teardown() -> void:
		se.free()
		entity.free()
		health.free()
		ScriptBehaviorProfiles._cache.clear()


class _AiCtx:
	var entity: _SupEntity
	var health: _SupHealth
	var se: StatusEffects
	var battle: _FakeBattle
	var ai: AIController

	func setup(profile_overrides: Dictionary, with_se: bool) -> void:
		ScriptBehaviorProfiles._cache.clear()
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
		for k in profile_overrides.keys():
			p[k] = profile_overrides[k]
		health = _SupHealth.new()
		entity = _SupEntity.new()
		entity.health = health
		entity.global_position = Vector2(900, 300)
		battle = _FakeBattle.new()
		battle.units.append(entity)
		entity.battle = battle
		var enemy := _Shooter.new()
		enemy.faction = 2
		enemy.global_position = Vector2(1000, 300)  # 近身威胁（< THREAT_RANGE 140）
		battle.enemies.append(enemy)
		if with_se:
			se = StatusEffects.new()
			se._owner = entity
			entity.se = se
		ai = AIController.new()
		ai._entity = entity  # 不进树直接注入（_ready cast 等价物，batch 准入：不进场景树）
		ai._setup_state_machine()

	func teardown() -> void:
		ai.free()
		battle.free()
		entity.free()
		health.free()
		if se != null:
			se.free()
		ScriptBehaviorProfiles._cache.clear()


## 假射手/伤害源（触发源判定查 get_weapon().weapon_type；决策夹具兼做近身敌人）
class _Shooter extends Node2D:
	var weapon_type: int = ScriptBehaviorProfiles.SWORD
	var faction: int = 1

	func get_weapon() -> Node:
		return self

	## 阵营查询面（近失压制敌方过滤消费；缺失时投射物侧按"可命中"处理，
	## 会误把友军算作近失目标——夹具补上以锁定"不误伤友军"断言）
	func get_faction() -> int:
		return faction


## 压制/决策夹具实体：duck 面齐（get_weapon/get_health/get_status_effects/
## is_possessed/is_dead/ai_stop）
class _SupEntity extends CharacterBody2D:
	var health: Node = null
	var battle: Node = null
	var weapon: Node = null  # _SupWeapon（Node，get_weapon -> Node 签名兼容）
	var se: Node = null
	var stopped: bool = false
	var possessed: bool = false
	var dead: bool = false
	var faction: int = 1

	func get_weapon() -> Node:
		return weapon

	func get_faction() -> int:
		return faction

	func get_battle_instance() -> Node:
		return battle

	func is_possessed() -> bool:
		return possessed

	func is_dead() -> bool:
		return dead

	func get_health() -> Node:
		return health

	func get_status_effects() -> Node:
		return se

	func ai_move(_dir: Vector2, _run: bool) -> void:
		pass

	func ai_stop() -> void:
		stopped = true


class _SupWeapon extends Node:
	var weapon_type: int = ScriptBehaviorProfiles.SWORD


## 假生命组件：damaged 信号（触发源）+ 决策链查询面 + 士气流失记录
class _SupHealth extends Node:
	signal damaged(amount: float, source: Node)
	var routed: bool = false
	var dead: bool = false
	var morale_lost: float = 0.0
	var hp: float = 100.0

	func is_routed() -> bool:
		return routed

	func is_dead() -> bool:
		return dead

	func get_hp_ratio() -> float:
		return 1.0

	func get_morale_ratio() -> float:
		return 1.0

	func lose_morale(amount: float) -> void:
		morale_lost += amount

	## 测试用受击入口（生产链路 = HealthComponent.take_damage → damaged.emit）
	func take_hit(amount: float, source: Node = null) -> void:
		damaged.emit(amount, source)


## 最小战斗实例桩（决策链 _try_combat 取数面，test_ai_retreat_modulation 同款）
class _FakeBattle extends Node:
	var duration: float = 0.0
	var units: Array = []
	var enemies: Array = []
	var allies: Array = []

	func is_active() -> bool:
		return true

	func get_duration() -> float:
		return duration

	func get_nearest_enemy(_unit: Node) -> Node:
		return enemies[0] if not enemies.is_empty() else null

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func get_allies_of(_faction: int) -> Array:
		return allies


## 相位计划宿主桩（_contact_reaction 只取 get_squad_units 成员列表）
class _PlanHost extends Node:
	var units: Array = []

	func get_squad_units(_squad_id: String) -> Array:
		return units


## 相位计划成员桩：AI 桩（号令记录）+ 可挂真实 StatusEffects（压制查询面）
class _PlanUnit extends Node2D:
	var ai: _PlanAI = null
	var se: Node = null
	var battle: Node = null
	var faction_id: int = 1
	var arrow_threat_time: float = -1000.0

	func _init() -> void:
		ai = _PlanAI.new()
		add_child(ai)

	func is_dead() -> bool:
		return false

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_ai_controller() -> Node:
		return ai

	func get_status_effects() -> Node:
		return se


## 相位计划 AI 桩（号令记录面，test_squad_phase_plan FakeAI 精简版）
class _PlanAI extends Node:
	var orders: Array = []
	var _ordered_behavior: String = ""

	func set_order(b: String, p: Dictionary = {}) -> void:
		orders.append({"behavior": b, "params": p.duplicate()})
		_ordered_behavior = b

	func has_order() -> bool:
		return not _ordered_behavior.is_empty()

	func get_current_behavior() -> String:
		return "idle"

	func orders_for(b: String) -> int:
		var n: int = 0
		for o in orders:
			if o.behavior == b:
				n += 1
		return n
