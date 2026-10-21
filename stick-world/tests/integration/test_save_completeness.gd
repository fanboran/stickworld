extends Node
## 集成测试：读档完整性三件——真实 SaveManager + SaveHandler + 编队/组织模块全链路
## （存 → 读 → 断言；GameRoot 全链 boot，全链 boot 模式）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_save_completeness.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 覆盖（任务档案 docs/项目/待办/读档完整性.md，纯逻辑层见 tests/unit/test_save_completeness.gd）：
##   1. 阵营恢复：faction_id 曾"存而不读"→ mid-session 读档经 set_faction 回填
##   2. 编队编制存档：班（班长/跟队链）+ 排（排长）落 world_state 表 formation 行 →
##      读档原位还原（组织 id 不变、成员/班长/排长换绑新实体、人员账重写为活 iid、
##      计数器推进新建不撞车）
##   3. world_state 表空壳：formation 行真实落表可查（成员为 ent_* 稳定键）
##   4. 旧档兼容：档内无 formation 行 / entities.extra_data 缺 faction_id →
##      空编队 + 默认阵营 0，不崩（缺字段落默认值）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

## 测试存档槽（用后即删，防污染玩家槽位）
const SLOT := 4
## 新图就位/恢复就绪等待上限（含地图场景加载）
const SETTLE_TIMEOUT := 20.0
## 存档采样与读档恢复的位置配对容差（px）：存→读之间单位可能被 AI 推移几帧
const POS_EPS := 80.0

var _runner: TestRunner
var _game_root: Node = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_boot_async()


func _boot_async() -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	_game_root.set("boot_map_id_override", "battlefield")  # HD-2D 城郊战场（HD-2D 城郊战场图）
	add_child(_game_root)
	var ok: bool = await TestHelpers.await_condition(
		func(): return _get_map() != null, SETTLE_TIMEOUT, "GameRoot 地图就绪")
	if not ok:
		print("[FATAL] 地图未就绪")
		get_tree().quit(1)
		return
	await _frames(2)
	_runner.add_test("阵营: 存→读 faction 回填（位置配对全量断言）", _test_faction_roundtrip, true)
	_runner.add_test("编队: 存→读 班/排原位还原 + formation 行落 world_state 表", _test_formation_roundtrip, true)
	_runner.add_test("旧档: 无 formation 行 + 缺 faction_id → 空编队默认阵营不崩", _test_legacy_compat, true)
	await _runner.run_async()
	print(_runner.summary())
	SaveManager.delete_game(SLOT)
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────── 基建 ───────────────────────────

func _get_map() -> Node2D:
	if _game_root != null and _game_root.has_method("get_current_map"):
		return _game_root.get_current_map()
	return null


func _fs() -> Node:
	return _game_root.get_node_or_null("FormationSystem") if _game_root != null else null


func _org_api() -> Node:
	return _game_root.get_organization_api() if _game_root != null else null


func _spawn_y() -> float:
	var map := _get_map()
	return map.ground_y + (map.ground_bottom - map.ground_y) * 0.5


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## 生成一个 NPC 单位（非附身、指定阵营）
func _spawn_unit(x: float, faction: int) -> Node2D:
	var map := _get_map()
	var e: Node2D = map.spawn_entity(STICKMAN_SCENE, Vector2(x, _spawn_y()))
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = _spawn_y() - e.foot_offset
	if e.has_method("set_user_controlled"):
		e.set_user_controlled(false)
	if e.has_method("set_faction"):
		e.set_faction(faction)
	return e


## 实体快照：按 x 升序 [{x, faction, ent}]
func _snapshot(map: Node2D) -> Array:
	var out: Array = []
	for e in map.get_entities():
		if is_instance_valid(e) and e.has_method("get_faction"):
			out.append({"x": float(e.global_position.x), "faction": int(e.get_faction()), "ent": e})
	out.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
	return out


## 从快照中找 x 最近的实体（POS_EPS 内），无则 null
func _entity_near(snap: Array, x: float) -> Node2D:
	var best: Node2D = null
	var best_d: float = POS_EPS
	for s_v in snap:
		var s: Dictionary = s_v
		var d: float = absf(float(s["x"]) - x)
		if d < best_d:
			best_d = d
			best = s["ent"]
	return best


## mid-session 读档（真实链路 load_game_from_slot → 换图 → _restore_from_save）
## 并等待恢复就绪（新图就位 + 实体数下限）。返回新图；失败返回 null（已断言）。
func _load_and_settle(min_entities: int) -> Node2D:
	var old_map := _get_map()
	# 旧图经 queue_free 释放，等待谓词只传 instance id（freed 对象过不了类型化形参）
	var old_eid: int = old_map.get_instance_id() if old_map != null else 0
	var accepted: bool = _game_root.load_game_from_slot(SLOT)
	if not accepted:
		_runner.assert_true(false, "读档受理失败: %s" % str(SaveManager.last_load_fail_reason))
		return null
	var map_ok: bool = await TestHelpers.await_condition(
		_new_map_ready.bind(old_eid), SETTLE_TIMEOUT, "新图就位")
	if not map_ok:
		_runner.assert_true(false, "读档后新图未就位（%.0fs）" % SETTLE_TIMEOUT)
		return null
	var ent_ok: bool = await TestHelpers.await_condition(
		_entities_ready.bind(min_entities), SETTLE_TIMEOUT, "实体恢复就位")
	if not ent_ok:
		_runner.assert_true(false, "恢复后实体数未达 %d（%.0fs）" % [min_entities, SETTLE_TIMEOUT])
		return null
	await _frames(3)
	return _get_map()


func _new_map_ready(old_eid: int) -> bool:
	var m := _get_map()
	return m != null and m.get_instance_id() != old_eid


func _entities_ready(min_entities: int) -> bool:
	var m := _get_map()
	return m != null and m.get_entities().size() >= min_entities


## 直开存档库读 world_state 表 formation 行（save_game 已关库，独立连接只读）
func _read_formation_row() -> Variant:
	if not ClassDB.class_exists("SQLite"):
		_runner.assert_true(false, "SQLite 插件未加载")
		return null
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = "user://saves/save_%d.db" % SLOT
	if not db.open_db():
		_runner.assert_true(false, "存档库打开失败")
		return null
	db.query_with_bindings(
		"SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'formation'", [SLOT])
	var rows: Array = db.query_result
	db.close_db()
	if rows.is_empty():
		return null
	return JSON.parse_string(str(rows[0].get("data", "")))


## 把存档库改造成"旧档"：抹掉 formation 行 + 清空实体 extra_data（缺 faction_id 等全部扩展字段）
func _mutate_db_to_legacy() -> bool:
	if not ClassDB.class_exists("SQLite"):
		_runner.assert_true(false, "SQLite 插件未加载")
		return false
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = "user://saves/save_%d.db" % SLOT
	if not db.open_db():
		_runner.assert_true(false, "旧档构造：存档库打开失败")
		return false
	db.query("DELETE FROM world_state WHERE module_name = 'formation'")
	db.query("UPDATE entities SET extra_data = '{}'")
	db.close_db()
	return true


# ─────────────────────────── 用例 ───────────────────────────

## 用例 1：阵营恢复。4 个不同阵营 NPC → 存 → mid-session 读档 →
## 实体全量（含 boot 玩家）位置配对断言 faction 回填。
func _test_faction_roundtrip() -> void:
	SaveManager.delete_game(SLOT)
	var xs := [900.0, 1100.0, 1300.0, 1500.0]
	var facs := [1, 2, 3, 0]
	for i in xs.size():
		var e := _spawn_unit(xs[i], facs[i])
		_runner.assert_not_null(e, "布阵单位 %d 生成" % i)
	await _frames(2)
	var map := _get_map()
	var before := _snapshot(map)
	_runner.assert_true(before.size() >= xs.size(), "快照至少含布阵单位（实测 %d）" % before.size())
	_runner.assert_true(SaveManager.save_game(SLOT), "存档成功")
	var new_map := await _load_and_settle(before.size())
	if new_map == null:
		return
	var after := _snapshot(new_map)
	_runner.assert_equal(after.size(), before.size(), "实体全量往返（含玩家）")
	var problems: Array = []
	for i in mini(before.size(), after.size()):
		var dx: float = absf(float(after[i]["x"]) - float(before[i]["x"]))
		if dx > POS_EPS:
			problems.append("#%d x 漂移 %.0f→%.0f" % [i, before[i]["x"], after[i]["x"]])
		elif int(after[i]["faction"]) != int(before[i]["faction"]):
			problems.append("#%d faction %d→%d" % [i, before[i]["faction"], after[i]["faction"]])
	_runner.assert_equal(problems.size(), 0, "阵营/位置全量回填 %s" % [problems])


## 用例 2：编队编制存档。两班（班长/跟队链）+ 一排（排长）→ 存 → formation 行断言
## → mid-session 读档 → 班/排原位还原 + 换绑 + 人员账重写 + 计数器推进。
func _test_formation_roundtrip() -> void:
	var fs := _fs()
	var org_api := _org_api()
	_runner.assert_not_null(fs, "FormationSystem 就位")
	_runner.assert_not_null(org_api, "OrganizationApi 就位")
	if fs == null or org_api == null:
		return
	# 布阵：5 单位（x 间隔 200，与用例 1 残留实体拉开距离）
	var units: Array = []
	for i in 5:
		var e := _spawn_unit(2100.0 + i * 200.0, 0)
		_runner.assert_not_null(e, "编队布阵单位 %d 生成" % i)
		units.append(e)
	await _frames(2)
	var sa: String = fs.create_squad([units[0], units[1]], "squad_save_a")
	var sb: String = fs.create_squad([units[2], units[3]], "squad_save_b")
	_runner.assert_false(sa.is_empty(), "班A 建成")
	_runner.assert_false(sb.is_empty(), "班B 建成")
	if sa.is_empty() or sb.is_empty():
		return
	fs.assign_leader(sa, units[0])
	fs.set_squad_follow_squad(sb, sa, 150.0)
	var pid: String = fs.create_platoon([sa, sb], "platoon_save")
	_runner.assert_false(pid.is_empty(), "排建成")
	if pid.is_empty():
		return
	fs.assign_platoon_leader(pid, units[2])
	var before := _snapshot(_get_map())
	_runner.assert_true(SaveManager.save_game(SLOT), "存档成功")
	# world_state 表通道断言（表不再是空壳）：formation 行 + ent_* 稳定键
	var row: Variant = _read_formation_row()
	_runner.assert_not_null(row, "world_state 表有 formation 行")
	if row is Dictionary:
		var squads_row: Array = row.get("squads", [])
		var platoons_row: Array = row.get("platoons", [])
		_runner.assert_equal(squads_row.size(), 2, "formation 行含两班")
		_runner.assert_equal(platoons_row.size(), 1, "formation 行含一排")
		if not squads_row.is_empty():
			var mem: Array = squads_row[0].get("members", [])
			var all_ent_keys: bool = mem.size() == 2 and String(mem[0]).begins_with("ent_") \
					and String(mem[1]).begins_with("ent_")
			_runner.assert_true(all_ent_keys, "行内成员为存档稳定键 ent_*")
	# mid-session 读档
	var new_map := await _load_and_settle(before.size())
	if new_map == null:
		return
	# 班原位还原（组织 id 不变）
	var all_squads: Array = fs.get_all_squads()
	_runner.assert_true(all_squads.has(sa), "班A 组织 id 原位还原")
	_runner.assert_true(all_squads.has(sb), "班B 组织 id 原位还原")
	# 成员/班长换绑新实体（读档后实体为重新 spawn 的新 iid，按 x 配对）
	var after := _snapshot(new_map)
	var s_a0 := _entity_near(after, 2100.0)
	var s_a1 := _entity_near(after, 2300.0)
	var s_b0 := _entity_near(after, 2500.0)
	var s_b1 := _entity_near(after, 2700.0)
	_runner.assert_not_null(s_a0, "班A 班长位实体恢复")
	_runner.assert_not_null(s_b0, "班B 成员位实体恢复")
	var sa_units: Array = fs.get_squad_units(sa)
	_runner.assert_equal(sa_units.size(), 2, "班A 两成员")
	_runner.assert_true(s_a0 in sa_units and s_a1 in sa_units, "班A 成员换绑新实体")
	_runner.assert_equal(fs.get_squad_leader(sa), s_a0, "班长恢复（新实体）")
	# 跟队链恢复
	var follow: Dictionary = fs.get_squad_follow(sb)
	_runner.assert_equal(String(follow.get("front", "")), sa, "班B 跟队班A")
	_runner.assert_approx(float(follow.get("gap", 0.0)), 150.0, 0.5, "跟队间距恢复")
	# 排聚合层恢复
	_runner.assert_equal(String(fs.get_platoon_of_squad(sa)), pid, "排 id 原位还原")
	_runner.assert_equal(fs.get_platoon_leader(pid), s_b0, "排长恢复（新实体）")
	# 组织人员账重写为活实体 iid（档内存的是旧 iid，跨会话已死）
	var org_info: Dictionary = org_api.get_organization(sa)
	_runner.assert_true(org_info.get("ok", false), "档内组织已收编")
	var personnel: Array = org_info.get("data", {}).get("personnel", [])
	var want := [str(s_a0.get_instance_id()), str(s_a1.get_instance_id())]
	_runner.assert_equal(personnel, want, "人员账整表重写为活实体 iid")
	# 计数器推进：读档后新建班/排不撞车（组织计数器收编续算 + 班/排号按档内最大后缀）
	var u4 := _entity_near(after, 2900.0)
	_runner.assert_not_null(u4, "第 5 单位恢复")
	var ns := ""
	if u4 != null:
		ns = String(fs.create_squad([u4], ""))
	_runner.assert_false(ns.is_empty(), "读档后可新建班")
	_runner.assert_true(ns != sa and ns != sb, "新班 id 不与档内班撞车")
	var np := ""
	if not ns.is_empty():
		np = String(fs.create_platoon([ns], ""))
	_runner.assert_false(np.is_empty(), "读档后可新建排")
	_runner.assert_true(np != pid, "新排 id 不与档内排撞车")


## 用例 3：旧档兼容。当前态存档后把库改造成旧档（抹 formation 行 + 清 extra_data）
## → 读档：空编队、全实体默认阵营 0、组织仍在（组织账在 world_state 行不受影响）。
func _test_legacy_compat() -> void:
	var fs := _fs()
	_runner.assert_not_null(fs, "FormationSystem 就位")
	if fs == null:
		return
	var org_api := _org_api()
	# 存一份"新态"，随后降格为旧档形态
	_runner.assert_true(SaveManager.save_game(SLOT), "存档成功（降格前基准）")
	var before := _snapshot(_get_map())
	_runner.assert_true(_mutate_db_to_legacy(), "旧档构造成功")
	_runner.assert_null(_read_formation_row(), "formation 行已抹除")
	var new_map := await _load_and_settle(before.size())
	if new_map == null:
		return
	# 无 formation 行 = 空编队（旧档缺字段落默认值，不崩）
	_runner.assert_equal(fs.get_squad_count(), 0, "旧档读入空编队")
	# 全实体阵营回退默认 0（extra_data 被清 = faction_id 缺失 → null → 保持 spawn 默认）
	var bad_faction: int = 0
	for e in new_map.get_entities():
		if is_instance_valid(e) and e.has_method("get_faction") and int(e.get_faction()) != 0:
			bad_faction += 1
	_runner.assert_equal(bad_faction, 0, "缺 faction_id 全部回退默认阵营 0")
	# 组织账在 world_state 行（未抹）→ 组织仍恢复；组织收编不因旧档缺编队而崩
	var org_info: Dictionary = org_api.get_organization("org_1")
	_runner.assert_true(org_info.get("ok", false), "旧档组织账仍恢复（world_state 行未受影响）")
