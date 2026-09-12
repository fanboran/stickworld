extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：权威值自主跳槽（R4 行为落地，RWR 编制加入的权威值经济）。
## 覆盖六条约束：默认关零回归 / 权威值排序决定去向（含玩家班优先）/ authority_margin
## 滞回不振荡 / 跳槽冷却窗（含到期）/ 「不该动的别动」守卫（班长·指挥官·溃逃·
## 被压制·接战中·玩家号令保护期·玩家本体）/ 单拍来源班限流 / 确定性错峰可复现。
## FormationSystem 不进场景树（_process 不触发），直接调 _tick_authority_switch，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


# ─────────────────────────────── 桩 ────────────────────────────────

## 假组织 API。commander_id 不随 assign_commander 自动登记——测试显式设置
## `commanders[org_id]`，以精确构造权威值组合（班长 / 班长+指挥官 / +玩家光环）。
class FakeOrgApi:
	extends Node
	var commanders: Dictionary = {}
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass

	func get_organization(org_id: String) -> Dictionary:
		return {
			"ok": true,
			"data": {"id": org_id, "parent_org": ""},
			"commander_id": String(commanders.get(org_id, "")),
		}


## 单位桩：faction / battle / ai / 附身 / 压制 / 武器射程。
class FakeUnit:
	extends Node2D
	var faction_id: int = 1
	var battle: Node = null
	var ai: Node = null
	var possessed: bool = false
	var suppressed: bool = false
	var attack_range: float = 100.0
	var role: String = ""
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func is_possessed() -> bool:
		return possessed

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_ai_controller() -> Node:
		return ai

	func get_weapon() -> Node:
		return self

	func get_status_effects() -> Node:
		return self

	func has_suppressed() -> bool:
		return suppressed

	func set_role(r: String) -> void:
		role = r


## AI 控制器桩：当前行为可强制（守卫测试用）。
class FakeAI:
	extends Node
	var cur_behavior: String = "idle"
	var _ordered_behavior: String = ""
	var _ordered_params: Dictionary = {}

	func get_current_behavior() -> String:
		return cur_behavior

	func force_behavior(b: String) -> void:
		cur_behavior = b

	func set_order(b: String, p: Dictionary = {}) -> void:
		_ordered_behavior = b
		_ordered_params = p.duplicate()
		cur_behavior = b

	func clear_order() -> void:
		_ordered_behavior = ""
		_ordered_params = {}

	func has_order() -> bool:
		return not _ordered_behavior.is_empty()

	func get_ordered_behavior() -> String:
		return _ordered_behavior

	func get_ordered_params() -> Dictionary:
		return _ordered_params


class FakeEnemy:
	extends Node2D
	func is_dead() -> bool:
		return false


## 战斗桩：敌方列表 + TeamAi 出口（玩家号令保护期查询链）。
class FakeBattle:
	extends Node
	var enemies: Array = []
	var team_ai: Node = null

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func is_active() -> bool:
		return true

	func get_team_ai(_faction: int) -> Node:
		return team_ai


## TeamAi 桩：只实现保护期查询出口（复用生产侧 is_manual_order_guarded 契约）。
class FakeTeamAi:
	extends Node
	var guarded: Dictionary = {}

	func is_manual_order_guarded(squad_id: String) -> bool:
		return bool(guarded.get(squad_id, false))


# ─────────────────────────────── 装配 ────────────────────────────────

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("约束1 默认关: 关闭态零行为零时钟；开闸同一局面才换班", _test_default_off)
	_runner.add_test("约束2 滞回: 容限带内两侧交替略高不振荡；越界才换", _test_hysteresis)
	_runner.add_test("约束3 冷却: 跳槽后窗内不评估，窗过恢复", _test_cooldown)
	_runner.add_test("约束4 排序: A(1.0)→B(1.7)；并列时玩家所在班优先吸引", _test_ordering_and_player_priority)
	_runner.add_test("约束5 守卫: 班长本人不被抽走（RWR 放人阈值）", _test_guard_leader)
	_runner.add_test("约束5 守卫: 组织在册指挥官本人不被抽走", _test_guard_commander)
	_runner.add_test("约束5 守卫: 玩家附身单位（玩家本体）不被搬动", _test_guard_possessed)
	_runner.add_test("约束5 守卫: 溃逃/找掩体（士气行为）中不换班", _test_guard_morale_behavior)
	_runner.add_test("约束5 守卫: 真实压制态中不换班", _test_guard_suppressed)
	_runner.add_test("约束5 守卫: 接战中（射程内有敌）不换班", _test_guard_engaged)
	_runner.add_test("约束5 守卫: 玩家手动号令保护期内不换班（复用 TeamAi 查询）", _test_guard_manual_order)
	_runner.add_test("约束5 限流: 单拍单来源班只放行名额内人数", _test_per_squad_flow_cap)
	_runner.add_test("约束6 错峰/确定性: 非同拍评估 + 同种子同局面可复现", _test_determinism_and_desync)
	_runner.add_test("档案: config/ai/formation_authority.tres 装载与缺省关闭", _test_resource)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _new_world() -> Dictionary:
	var org := FakeOrgApi.new()
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org)
	return {"fs": fs, "org": org}


func _unit(unit_name: String, pos: Vector2 = Vector2.ZERO) -> FakeUnit:
	var u := FakeUnit.new()
	u.name = unit_name
	u.position = pos
	u.ai = FakeAI.new()
	return u


## 建战斗班（默认预设 fp_combat_squad，工作类型含 WORK_COMBAT）；with_leader 时
## 将首员任命为班长。
func _squad(w: Dictionary, units: Array, with_leader: bool = true) -> String:
	var fs: Node = w["fs"]
	var sid: String = fs.create_squad(units)
	if with_leader:
		fs.assign_leader(sid, units[0])
	return sid


## 开闸（单测用短评估间隔：相位 ∈ [0,0.5) < 扫描拍 0.5 → 首拍全部到期，便于断言）。
func _enable(fs: Node, overrides: Dictionary = {}) -> void:
	var p: Dictionary = {
		"authority_switch_enabled": true,
		"authority_scan_interval": 0.5,
		"authority_eval_interval": 0.5,
		"authority_switch_cooldown": 20.0,
		"authority_candidate_radius": 2000.0,
		"authority_max_switches_per_squad_tick": 8,
		"authority_rng_seed": 4242,
	}
	p.merge(overrides, true)
	fs.set_authority_params(p)


func _tick(fs: Node, times: int = 1) -> void:
	for _i in times:
		fs._tick_authority_switch(0.5)


## 守卫场景骨架：A 班 = [班长, 受测者, 对照者]，B 班权威 1.7（班长+指挥官+玩家光环）。
## 断言口径：受测者留在 A、对照者投奔 B（证明该场景本来会换人，差异只来自守卫）。
func _guard_world() -> Dictionary:
	var w := _new_world()
	var fs: Node = w["fs"]
	var leader := _unit("leader")
	var subject := _unit("subject")
	var control := _unit("control")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [leader, subject, control])
	var sb := _squad(w, [b_lead])
	w["org"].commanders[sb] = str(b_lead.get_instance_id())
	b_lead.possessed = true
	_enable(fs)
	w.merge({
		"sa": sa, "sb": sb, "leader": leader,
		"subject": subject, "control": control, "b_lead": b_lead,
	})
	return w


func _assert_guard(w: Dictionary, msg: String) -> void:
	_runner.assert_equal(w["fs"].get_unit_squad(w["subject"]), w["sa"], msg)
	_runner.assert_equal(w["fs"].get_unit_squad(w["control"]), w["sb"],
			"对照者应正常投奔高权威班（场景有效性）")


# ─────────────────────────────── 约束 1：默认关 ────────────────────────────────

func _test_default_off() -> void:
	var w := _new_world()
	var fs: Node = w["fs"]
	var a := _unit("a0")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [a], false)
	var sb := _squad(w, [b_lead])
	w["org"].commanders[sb] = str(b_lead.get_instance_id())
	b_lead.possessed = true
	_runner.assert_approx(fs.get_squad_authority(sb), 1.7, 0.001, "B 班权威应为 1.7")
	_runner.assert_false(bool(fs._authority_params.get("authority_switch_enabled", true)),
			"缺省应关闭（零回归基线）")
	_tick(fs, 40)
	_runner.assert_equal(fs.get_unit_squad(a), sa, "关闭态成员不应换班")
	_runner.assert_approx(fs._authority_clock, 0.0, 0.001, "关闭态不应累积时钟（零开销）")
	_runner.assert_equal(fs._authority_last_eval_count, 0, "关闭态不应有任何评估")
	# 开闸后同一局面应转投：差异只来自开关
	_enable(fs)
	_tick(fs)
	_runner.assert_equal(fs.get_unit_squad(a), sb, "开闸后低权威班成员应投奔高权威班")


# ─────────────────────────────── 约束 2：滞回 ────────────────────────────────

func _test_hysteresis() -> void:
	var w := _new_world()
	var fs: Node = w["fs"]
	var a := _unit("a0")
	var a_lead := _unit("a_lead")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [a_lead, a])
	var sb := _squad(w, [b_lead])
	# 把两侧加成压到 0.05（< margin 0.07），构造"交替略高"的容限带内局面
	_enable(fs, {"authority_player_squad_bonus": 0.05, "authority_stay_in_player_squad_bonus": 0.05})
	for i in 6:
		fs.set_squad_follow(sb, i % 2 == 0)
		fs.set_squad_follow(sa, i % 2 == 1)
		_tick(fs)
		_runner.assert_equal(fs.get_unit_squad(a), sa,
				"第 %d 拍：容限带内（差 0.05 < margin 0.07）不应换班" % i)
	# 越界（0.08 > margin 0.07）→ 同一构造应换：证明 margin 是分界线
	fs.set_squad_follow(sa, false)
	fs.set_squad_follow(sb, true)
	fs.set_authority_params({"authority_player_squad_bonus": 0.08})
	_tick(fs)
	_runner.assert_equal(fs.get_unit_squad(a), sb, "权威差 0.08 > margin 0.07 应换班")


# ─────────────────────────────── 约束 3：冷却 ────────────────────────────────

func _test_cooldown() -> void:
	var w := _new_world()
	var fs: Node = w["fs"]
	var a := _unit("a0")
	var a_lead := _unit("a_lead")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [a_lead, a])
	var sb := _squad(w, [b_lead])
	_enable(fs)
	fs.set_squad_follow(sb, true)  # B 玩家班 = 1.2 > A 1.0
	_tick(fs)
	_runner.assert_equal(fs.get_unit_squad(a), sb, "首拍应投奔玩家班")
	_runner.assert_true(fs._authority_cooldown_until.has(a.get_instance_id()),
			"跳槽后应登记冷却截止时刻")
	# 反向：A 变成玩家班、B 失去吸引力 → 无冷却会立刻跳回
	fs.set_squad_follow(sb, false)
	fs.set_squad_follow(sa, true)
	_tick(fs, 38)  # 累计 19.5s < 冷却 20.5s
	_runner.assert_equal(fs.get_unit_squad(a), sb, "冷却窗内不应跳回（19.5s < 20.5s）")
	_tick(fs, 4)  # 累计 21.5s > 20.5s
	_runner.assert_equal(fs.get_unit_squad(a), sa, "冷却耗尽后应投奔新的高权威班")


# ─────────────────────────────── 约束 4：排序 / 玩家班优先 ────────────────────────────────

func _test_ordering_and_player_priority() -> void:
	# A 班 1.0（仅班长）→ B 班 1.7（班长 + 指挥官 + 玩家光环）
	var w := _new_world()
	var fs: Node = w["fs"]
	var a := _unit("a0")
	var a_lead := _unit("a_lead")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [a_lead, a])
	var sb := _squad(w, [b_lead])
	w["org"].commanders[sb] = str(b_lead.get_instance_id())
	b_lead.possessed = true
	_runner.assert_approx(fs.get_squad_authority(sa), 1.0, 0.001, "A 班权威 = 班长基础 1.0")
	_runner.assert_approx(fs.get_squad_authority(sb), 1.7, 0.001,
			"B 班权威 = 班长 1.0 + 指挥官 0.5 + 玩家光环 0.2")
	_enable(fs)
	_tick(fs)
	_runner.assert_equal(fs.get_unit_squad(a), sb, "成员应从低权威 A 流向高权威 B")
	# 两个候选班基础权威并列 → 玩家所在班（follow_player 加成）优先吸引
	var w2 := _new_world()
	var fs2: Node = w2["fs"]
	var m := _unit("m0")
	var m_lead := _unit("m_lead")
	var n_lead := _unit("n_lead")
	var p_lead := _unit("p_lead")
	var sm := _squad(w2, [m_lead, m])
	var sn := _squad(w2, [n_lead])
	var sp := _squad(w2, [p_lead])
	_runner.assert_approx(fs2.get_squad_authority(sn), 1.0, 0.001, "N 班 1.0")
	_enable(fs2)
	fs2.set_squad_follow(sp, true)  # 玩家班 +0.2 → 1.2
	_tick(fs2)
	_runner.assert_equal(fs2.get_unit_squad(m), sp, "基础权威并列时玩家所在班应优先吸引")


# ─────────────────────────────── 约束 5：不该动的别动 ────────────────────────────────

func _test_guard_leader() -> void:
	var w := _guard_world()
	w["fs"].assign_leader(w["sa"], w["subject"])  # 受测者即班长本人
	_tick(w["fs"])
	_assert_guard(w, "班长本人不应被抽走（RWR max_leader_authority 放人阈值语义）")


func _test_guard_commander() -> void:
	var w := _guard_world()
	w["org"].commanders[w["sa"]] = str(w["subject"].get_instance_id())
	_tick(w["fs"])
	_assert_guard(w, "组织在册指挥官本人不应被抽走")


func _test_guard_possessed() -> void:
	var w := _guard_world()
	w["subject"].possessed = true
	_tick(w["fs"])
	_assert_guard(w, "玩家附身单位（玩家本体）不应被 AI 搬动")


func _test_guard_morale_behavior() -> void:
	var w := _guard_world()
	w["subject"].ai.force_behavior("retreat")
	_tick(w["fs"])
	_assert_guard(w, "溃逃中单位不应换班")
	var w2 := _guard_world()
	w2["subject"].ai.force_behavior("seek_cover")
	_tick(w2["fs"])
	_assert_guard(w2, "找掩体中单位不应换班")


func _test_guard_suppressed() -> void:
	var w := _guard_world()
	w["subject"].suppressed = true
	_tick(w["fs"])
	_assert_guard(w, "被压制单位不应换班")


func _test_guard_engaged() -> void:
	var w := _guard_world()
	var battle := FakeBattle.new()
	var enemy := FakeEnemy.new()
	enemy.position = Vector2(50, 0)  # 距受测者 50px < 射程 100 = 接战
	battle.enemies = [enemy]
	w["subject"].battle = battle
	_tick(w["fs"])
	_assert_guard(w, "接战中单位不应换班（交还战斗行为）")


func _test_guard_manual_order() -> void:
	var w := _guard_world()
	var battle := FakeBattle.new()
	var tai := FakeTeamAi.new()
	tai.guarded[w["sa"]] = true  # 该班处于玩家手动号令保护期
	battle.team_ai = tai
	w["subject"].battle = battle
	_tick(w["fs"])
	_assert_guard(w, "玩家手动号令保护期内单位不应换班（复用 TeamAi 保护期查询）")


func _test_per_squad_flow_cap() -> void:
	var w := _new_world()
	var fs: Node = w["fs"]
	var m0 := _unit("m0")
	var m1 := _unit("m1")
	var m2 := _unit("m2")
	var b_lead := _unit("b_lead")
	var sa := _squad(w, [m0, m1, m2], false)  # 无班长 → 权威 0
	var sb := _squad(w, [b_lead])
	_enable(fs, {"authority_max_switches_per_squad_tick": 1})
	_tick(fs)
	_runner.assert_equal(fs.get_squad_size(sa), 2, "单拍单来源班只放行 1 人（防整班雪崩）")
	_runner.assert_equal(fs.get_squad_size(sb), 2, "B 班单拍应只新增 1 人")
	_tick(fs)
	_runner.assert_equal(fs.get_squad_size(sa), 1, "次拍再放行 1 人")
	_tick(fs)
	_runner.assert_equal(fs.get_squad_size(sa), 0, "第三拍最后 1 人离开")


# ─────────────────────────────── 约束 6：错峰 / 确定性 ────────────────────────────────

## 错峰世界：A 班 9 人 + B 班高权威班长（10 个单位，评估间隔 2.0s > 扫描拍 0.5s）。
func _build_desync_world() -> Dictionary:
	var w := _new_world()
	var fs: Node = w["fs"]
	var units: Array = []
	var a_members: Array = []
	for i in 9:
		var u := _unit("a%d" % i)
		units.append(u)
		a_members.append(u)
	var b_lead := _unit("b_lead")
	units.append(b_lead)
	var sa := _squad(w, a_members)
	var sb := _squad(w, [b_lead])
	w["org"].commanders[sb] = str(b_lead.get_instance_id())
	b_lead.possessed = true
	_enable(fs, {"authority_eval_interval": 2.0})
	w.merge({"sa": sa, "sb": sb, "units": units})
	return w


func _test_determinism_and_desync() -> void:
	var w1 := _build_desync_world()
	var w2 := _build_desync_world()
	var fs1: Node = w1["fs"]
	var fs2: Node = w2["fs"]
	var total: int = (w1["units"] as Array).size()
	# 两世界严格同拍推进（可复现性对照不能错拍）
	_tick(fs1)
	_tick(fs2)
	var c1: int = fs1._authority_last_eval_count
	_runner.assert_equal(fs2._authority_last_eval_count, c1,
			"同种子同局面的首拍到评估数应一致")
	# 首拍：只有相位落在 [0,0.5) 的单位到期，不应全部同拍评估
	_runner.assert_lt(float(c1), float(total), "首拍不应全部单位同拍评估")
	# 相位离散度：错峰相位应落在 ≥2 个扫描槽位
	var slots: Dictionary = {}
	for iid_v in fs1._authority_next_eval.keys():
		slots[int(floorf(float(fs1._authority_next_eval[iid_v]) / 0.5))] = true
	_runner.assert_gt(float(slots.size()), 1.0, "错峰相位应落在 ≥2 个扫描槽位")
	# 推进到评估间隔（再多 3 拍，共 2.0s）：全部单位各评估一次（错峰铺开而非一次齐发）
	var cumulative: int = c1
	for _i in 3:
		_tick(fs1)
		_tick(fs2)
		cumulative += fs1._authority_last_eval_count
	_runner.assert_equal(cumulative, total, "推进到评估间隔后全部单位应各评估一次")
	# 可复现：同构造 + 同种子 + 同 tick 序列 → 归属与相位逐单位一致
	var units1: Array = w1["units"]
	var units2: Array = w2["units"]
	for i in total:
		_runner.assert_equal(fs1.get_unit_squad(units1[i]), fs2.get_unit_squad(units2[i]),
				"同种子同局面第 %d 个单位归属应一致" % i)
	for i in total:
		_runner.assert_approx(
				float(fs1._authority_next_eval[units1[i].get_instance_id()]),
				float(fs2._authority_next_eval[units2[i].get_instance_id()]),
				0.0001, "第 %d 个单位错峰相位应可复现" % i)


# ─────────────────────────────── 档案 ────────────────────────────────

func _test_resource() -> void:
	var res: Resource = load("res://config/ai/formation_authority.tres")
	_runner.assert_not_null(res, "跳槽参数资源应可加载")
	if res == null:
		return
	var rows: Array = res.get("variables").get("data", [])
	_runner.assert_equal(rows.size(), 1, "应含 global 行")
	var row: Dictionary = rows[0]
	_runner.assert_equal(str(row.get("id", "")), "global", "行 id 应为 global")
	_runner.assert_equal(bool(row.get("authority_switch_enabled", true)), false,
			"资源缺省应关闭（零回归基线）")
	# RWR 真值项（小兵步枪逆向 §2.6）
	_runner.assert_approx(float(row.get("authority_player_squad_bonus", 0.0)), 0.2, 0.001,
			"玩家班吸引力 = RWR favor_joining_player_squad_value_increase 0.2")
	_runner.assert_approx(float(row.get("authority_stay_in_player_squad_bonus", 0.0)), 0.5, 0.001,
			"玩家班黏性 = RWR favor_staying_in_current_player_squad_value_increase 0.5")
	_runner.assert_approx(float(row.get("authority_leader_release_threshold", 0.0)), 0.3, 0.001,
			"班长放人阈值 = RWR max_leader_authority_willing_to_join_another_squad 0.3")
	# 代码默认档同步缺省关闭（BalanceConfig 缺载兜底）
	_runner.assert_equal(bool(ScriptFormationSystem.AUTHORITY_DEFAULTS.get("authority_switch_enabled", true)),
			false, "代码默认档应缺省关闭")
	# margin 仍是评分内核常量（行为侧不重写比较逻辑）
	_runner.assert_approx(ScriptFormationSystem.AUTHORITY_MARGIN, 0.07, 0.001,
			"authority_margin 保持 RWR 真值 0.07")
