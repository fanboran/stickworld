extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：town_life 读档持久化（职业 id + 村民身份标志随档）。
## 背景：主街读档后村民全员罚站——存档 extra_data 从未落 profession/is_villager，
## _restore_entities 恢复的是"无职业、非村民"实体，AI 决策链（_try_harvest/_is_villager）
## 双双拒绝。本套件锁存/取两侧行为：
##   - 往返：在职村民（职业+标志+装具）与无职业实体分野恢复；
##   - 待业村民（空职业+标志）往返；
##   - 老档（extra 无字段）安全回退不崩；
##   - 配置已删改的未知职业 id 回待业池且不挂装具。
## 用真实 SQLite（内存级最小建表）+ 真实 SaveHandler + 真实体场景；GameRoot.new()
## 作 _root 桩（不进树不跑 _ready，仅取 _STICKMAN_ENTITY_SCENE 常量与空引用字段）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSaveHandler := preload("res://modules/world/scripts/setup/save_handler.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")
const UnitsAPI := preload("res://modules/units/api.gd")
const ScriptWeaponMount := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const ScriptTownLifeAPI := preload("res://modules/town_life/api.gd")

const SLOT := 9
const MAP_ID := "test_street"
const DB_PATH := "user://temp/test_townlife_save_persistence.db"

## 与 SaveManager 建表同构的最小 entities 表（本套件只用到该表）
const ENTITIES_SQL := """
	CREATE TABLE IF NOT EXISTS entities (
		slot_id       INTEGER NOT NULL,
		map_id        TEXT    NOT NULL,
		entity_id     TEXT    NOT NULL,
		entity_type   TEXT    NOT NULL DEFAULT 'stickman',
		def_id        TEXT    NOT NULL DEFAULT '',
		pos_x         REAL    NOT NULL,
		pos_y         REAL    NOT NULL,
		facing        INTEGER NOT NULL DEFAULT 1,
		is_player     INTEGER NOT NULL DEFAULT 0,
		extra_data    TEXT    NOT NULL DEFAULT '{}',
		PRIMARY KEY (slot_id, map_id, entity_id)
	);
"""

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("往返：职业/村民标志/装具随档恢复，无职业实体保持分野", _test_roundtrip)
	_runner.add_test("待业村民往返：空职业+标志仍在（wander 作用域恢复）", _test_idle_villager)
	_runner.add_test("老档无字段：安全回退不崩不误标", _test_legacy_no_fields)
	_runner.add_test("未知职业 id：回待业池且不挂装具", _test_unknown_profession)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试桩 ────────────────────────────────

class _StubMap extends Node2D:
	## spawn_entity 进来 / get_entities 出去的最小地图（_map_ref 判空语义同真图）
	var entities: Array = []

	func get_entities() -> Array:
		return entities

	func spawn_entity(scene: PackedScene, pos: Vector2) -> Node2D:
		var e: Node2D = scene.instantiate()
		e.position = pos
		add_child(e)
		entities.append(e)
		return e


## 真实 SQLite 最小库：本套件专用临时文件，套件头删除重建
func _open_db() -> Object:
	var gpath := ProjectSettings.globalize_path(DB_PATH)
	DirAccess.make_dir_recursive_absolute(gpath.get_base_dir())
	if FileAccess.file_exists(DB_PATH):
		DirAccess.remove_absolute(gpath)
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = gpath
	_runner.assert_true(db.open_db(), "临时库应能打开: %s" % gpath)
	db.query(ENTITIES_SQL)
	return db


func _make_handler() -> Node:
	var handler: Node = ScriptSaveHandler.new()
	# GameRoot.new()：不进树不跑 _ready——_STICKMAN_ENTITY_SCENE 是 const 可直接取，
	# camera_rig/_construction_api 默认 null（NPC 行不触碰；判空守卫在 save_handler）
	handler._root = ScriptGameRoot.new()
	return handler


func _spawn_villager(map: _StubMap, prof: String, x: float) -> Node2D:
	var e: Node2D = map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(x, 1000.0))
	e.set("is_villager", true)
	e.call("set_profession", prof)
	return e


## 存 → 清空 → 全新图恢复（round-trip 公共通道），返回新图
func _roundtrip(db: Object, handler: Node, map: _StubMap) -> _StubMap:
	handler._save_entities(db, SLOT, MAP_ID, map)
	var fresh := _StubMap.new()
	add_child(fresh)
	handler._restore_entities(db, SLOT, MAP_ID, fresh)
	return fresh


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_roundtrip() -> void:
	var db: Object = _open_db()
	var handler: Node = _make_handler()
	var map := _StubMap.new()
	add_child(map)
	_spawn_villager(map, "miner", 100.0)   # 矿工（pickaxe 装具）
	map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(200.0, 1000.0))   # 无职业实体（对照）
	# fixture 自检：保存侧 extra_data 必须带出两字段
	handler._save_entities(db, SLOT, MAP_ID, map)
	db.query("SELECT extra_data FROM entities WHERE slot_id = %d" % SLOT)
	var rows: Array = db.query_result
	_runner.assert_equal(rows.size(), 2, "实体行数 = 2")
	var has_prof: bool = false
	var has_flag: bool = false
	for r: Dictionary in rows:
		var parsed: Variant = JSON.parse_string(str(r.get("extra_data", "{}")))
		if parsed is Dictionary:
			has_prof = has_prof or parsed.has("profession")
			has_flag = has_flag or parsed.has("is_villager")
	_runner.assert_true(has_prof, "存侧 extra_data 落 profession 字段")
	_runner.assert_true(has_flag, "存侧 extra_data 落 is_villager 字段")

	var restored := _roundtrip(db, handler, map)
	_runner.assert_equal(restored.get_entities().size(), 2, "读侧恢复实体数 = 2")
	for e: Node2D in restored.get_entities():
		var is_smith: bool = e.position.x < 150.0
		if is_smith:
			_runner.assert_equal(String(e.call("get_profession")), "miner", "矿工职业随档恢复")
			_runner.assert_true(bool(e.get("is_villager")), "矿工村民标志随档恢复")
			var wt: int = int(e.get("weapon_mount").get("weapon_type"))
			_runner.assert_equal(wt, int(ScriptWeaponMount.WeaponType.PICKAXE),
					"装具按职业 id 重挂（pickaxe）")
		else:
			_runner.assert_equal(String(e.call("get_profession")), "", "无职业实体保持空职业")
			_runner.assert_true(not bool(e.get("is_villager")), "无标志实体不误标村民")
	db.close_db()
	_runner.assert_true(true, "往返闭环")


func _test_idle_villager() -> void:
	var db: Object = _open_db()
	var handler: Node = _make_handler()
	var map := _StubMap.new()
	add_child(map)
	_spawn_villager(map, "", 100.0)   # 待业（空职业）但仍是村民
	var restored := _roundtrip(db, handler, map)
	_runner.assert_equal(restored.get_entities().size(), 1, "恢复实体数 = 1")
	var e: Node2D = restored.get_entities()[0]
	_runner.assert_equal(String(e.call("get_profession")), "", "空职业往返保持待业")
	_runner.assert_true(bool(e.get("is_villager")), "待业村民标志仍在（_is_villager wander 作用域）")
	db.close_db()


func _test_legacy_no_fields() -> void:
	var db: Object = _open_db()
	var handler: Node = _make_handler()
	# 手工插入老档行（extra_data 无 town_life 字段——修复前的存量档）
	db.insert_row("entities", {
		"slot_id": SLOT, "map_id": MAP_ID, "entity_id": "ent_0000",
		"entity_type": "stickman", "def_id": "stickman_basic",
		"pos_x": 100.0, "pos_y": 1000.0, "facing": 1, "is_player": 0,
		"extra_data": "{}",
	})
	var fresh := _StubMap.new()
	add_child(fresh)
	handler._restore_entities(db, SLOT, MAP_ID, fresh)
	_runner.assert_equal(fresh.get_entities().size(), 1, "老档实体照常恢复")
	var e: Node2D = fresh.get_entities()[0]
	_runner.assert_equal(String(e.call("get_profession")), "", "老档恢复保持默认无职业")
	_runner.assert_true(not bool(e.get("is_villager")), "老档恢复不误标村民")
	db.close_db()


func _test_unknown_profession() -> void:
	var db: Object = _open_db()
	var handler: Node = _make_handler()
	# 手工插入配置里已不存在的职业 id（配置删改后的档）
	db.insert_row("entities", {
		"slot_id": SLOT, "map_id": MAP_ID, "entity_id": "ent_0000",
		"entity_type": "stickman", "def_id": "stickman_basic",
		"pos_x": 100.0, "pos_y": 1000.0, "facing": 1, "is_player": 0,
		"extra_data": JSON.stringify({"profession": "phantom_job", "is_villager": true}),
	})
	var fresh := _StubMap.new()
	add_child(fresh)
	handler._restore_entities(db, SLOT, MAP_ID, fresh)
	var e: Node2D = fresh.get_entities()[0]
	_runner.assert_equal(String(e.call("get_profession")), "",
			"未知职业 id 回待业池（不挂空档案进劳作链）")
	var wt: int = int(e.get("weapon_mount").get("weapon_type"))
	_runner.assert_true(wt != int(ScriptWeaponMount.WeaponType.PICKAXE), "未知职业不挂装具")
	db.close_db()
