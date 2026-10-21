extends Node
## 存档 fixture 生成器 —— 经真实 SaveManager 链路产出 tests/fixtures/saves/ 样例档。
##
## 运行（headless，数秒）：
##   godot --headless --path stick-world res://tools/save/generate_save_fixtures.tscn
##
## 产物（v 前缀 = 生成时的 CURRENT_SCHEMA_VERSION；旧版本 fixture 不清理，留库供迁移链回归）：
##   tests/fixtures/saves/v<N>_minimal_empty.db   最小空档（save_meta + WorldState 容器行 + 空表）
##   tests/fixtures/saves/v<N>_full_fields.db     满字段档（各数据表 ≥1 行，列值取非默认形态）
##   tests/fixtures/saves/v<N>_formation_org.db   带编队组织档（4 实体 + formation 行 + 组织账入容器行）
##
## 纪律：每次存档格式变更（CURRENT_SCHEMA_VERSION 增一）后必须重跑本工具，
## 新增一份当前版 fixture 入库——回归面见 tests/integration/test_save_migration.gd，
## 口径见 docs/技术/架构/数据与契约/存储架构设计.md §版本迁移链。
##
## 机制：SaveManager.save_game 产出基础档（真实建表/版本盖章/WorldState 容器行），
## 复制后对满字段/编队档做裸 SQL 富化——行形状对齐真实写入方
## （save_handler._remap_formation_keys / world_state_serializer.organization_to_dict）。

## 生成专用槽位（用后即删，不碰玩家槽位）
const SLOT := 4
const OUT_DIR := "res://tests/fixtures/saves"


func _ready() -> void:
	var prefix := "v%d" % SaveManager.CURRENT_SCHEMA_VERSION
	SaveManager.set_auto_save_enabled(false)
	SaveManager.delete_game(SLOT)
	if not SaveManager.save_game(SLOT):
		push_error("[fixtures] 基础档生成失败（save_game）")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var src := "%s/save_%d.db" % [SaveManager.SAVE_DIR, SLOT]
	# 1) 最小空档：save_game 产物原样（world_state 容器行由本进程真实 WorldState 写入）
	_export(src, "%s_minimal_empty.db" % prefix)
	# 2) 满字段档 / 3) 编队组织档：复制后 SQL 富化
	_export_enriched(src, "%s_full_fields.db" % prefix, _enrich_full_fields)
	_export_enriched(src, "%s_formation_org.db" % prefix, _enrich_formation_org)
	SaveManager.delete_game(SLOT)
	print("[fixtures] 生成完成: %s/%s_{minimal_empty,full_fields,formation_org}.db" % [OUT_DIR, prefix])
	get_tree().quit(0)


# ─────────────────────────────── 导出基建 ────────────────────────────────

func _export(src: String, fname: String) -> void:
	var dst := "%s/%s" % [OUT_DIR, fname]
	var err: int = DirAccess.copy_absolute(src, dst)
	if err != OK:
		push_error("[fixtures] 复制失败 %s → %s（err=%d）" % [src, dst, err])
		get_tree().quit(1)


func _export_enriched(src: String, fname: String, enrich: Callable) -> void:
	_export(src, fname)
	var dst := "%s/%s" % [OUT_DIR, fname]
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = dst
	if not db.open_db():
		push_error("[fixtures] 富化库打开失败: %s" % dst)
		get_tree().quit(1)
		return
	enrich.call(db)
	db.close_db()


## 单条 SQL 执行守卫：fixture 富化失败必须响亮退出，绝不静默产出残缺样例
func _exec(db: Object, tag: String, sql: String, bindings: Array = []) -> void:
	var ok: bool = false
	if bindings.is_empty():
		ok = db.query(sql)
	else:
		ok = db.query_with_bindings(sql, bindings)
	if not ok:
		push_error("[fixtures] %s 执行失败: %s（%s）" % [tag, sql.left(48), str(db.error_message)])
		db.close_db()
		get_tree().quit(1)


# ─────────────────────────────── 富化：满字段档 ────────────────────────────────

## 各数据表插一行全列显式赋值。ground_y/ground_bottom 等取真实地图常量——
## 满字段目标是"字段齐全可断言"，非字面反默认值。
func _enrich_full_fields(db: Object) -> void:
	var s := SLOT
	_exec(db, "maps", ("INSERT INTO maps (slot_id, map_id, town_center_world_x, map_left_cell, map_right_cell,"
		+ " city_left_x, city_right_x, ground_y, ground_bottom)"
		+ " VALUES (?, 'battlefield', 1234.5, -12, 34, -500.5, 600.5, 810.0, 1080.0)"), [s])
	_exec(db, "buildings", ("INSERT INTO buildings (slot_id, building_id, map_id, def_id, cell_x, width, state,"
		+ " health, max_health, is_terrain, wall_tier, is_gate, region_id)"
		+ " VALUES (?, 'bld_fixture_0001', 'battlefield', 'wall_stone', 5, 3, 1, 66.5, 120.0, 1, 2, 1, 'region_fixture')"), [s])
	_exec(db, "construction_projects", ("INSERT INTO construction_projects (slot_id, project_id, map_id, def_id,"
		+ " cell_x, width, state, total_work, current_work, material_progress, region_id)"
		+ " VALUES (?, 'proj_fixture_0001', 'battlefield', 'house_a', 9, 2, 1, 40.0, 12.5, 0.5, 'region_fixture')"), [s])
	_exec(db, "entities#0", ("INSERT INTO entities (slot_id, map_id, entity_id, entity_type, def_id, pos_x, pos_y,"
		+ " facing, is_player, extra_data) VALUES (?, 'battlefield', 'ent_0000', 'stickman', 'stickman_basic',"
		+ " 100.5, 200.25, -1, 1, ?)"), [s, JSON.stringify({"faction_id": 0, "profession": "farmer"})])
	_exec(db, "entities#1", ("INSERT INTO entities (slot_id, map_id, entity_id, entity_type, def_id, pos_x, pos_y,"
		+ " facing, is_player, extra_data) VALUES (?, 'battlefield', 'ent_0001', 'stickman', 'stickman_basic',"
		+ " 300.0, 200.25, 1, 0, ?)"), [s, JSON.stringify({"faction_id": 1})])
	_exec(db, "resource_nodes", ("INSERT INTO resource_nodes (slot_id, map_id, node_id, pos_x, pos_y,"
		+ " resource_type, amount) VALUES (?, 'battlefield', 'node_fixture_0001', 150.0, 220.0, 1, 87)"), [s])


# ─────────────────────────────── 富化：编队组织档 ────────────────────────────────

## 4 实体 + formation 行（两班一排，行形状 = save_handler._remap_formation_keys 输出）
## + 组织账注入 world_state 容器行（形状 = world_state_serializer.organization_to_dict）。
## personnel 存死 iid 字符串——与真实旧档同形态（跨会话已失效，读侧按活实体重写）。
func _enrich_formation_org(db: Object) -> void:
	var s := SLOT
	for i in 4:
		_exec(db, "entities#%d" % i, ("INSERT INTO entities (slot_id, map_id, entity_id, entity_type, def_id,"
			+ " pos_x, pos_y, facing, is_player, extra_data) VALUES (?, 'battlefield', ?, 'stickman',"
			+ " 'stickman_basic', ?, 200.25, 1, 0, ?)"),
			[s, "ent_%04d" % i, 2100.0 + i * 200.0, JSON.stringify({"faction_id": 0})])
	var formation := {
		"squads": [
			{
				"org_id": "org_1", "name": "fixture一班", "preset_id": "", "work_types": [],
				"leader_ent": "ent_0000", "members": ["ent_0000", "ent_0001"],
				"follow_player": false, "follow_front": "", "follow_gap": 0.0,
			},
			{
				"org_id": "org_2", "name": "fixture二班", "preset_id": "", "work_types": [],
				"leader_ent": "ent_0002", "members": ["ent_0002", "ent_0003"],
				"follow_player": false, "follow_front": "org_1", "follow_gap": 150.0,
			},
		],
		"platoons": [
			{
				"platoon_id": "platoon_1", "name": "fixture排", "squads": ["org_1", "org_2"],
				"leader_ent": "ent_0002", "company_id": "",
			},
		],
	}
	_exec(db, "formation_row",
		"DELETE FROM world_state WHERE slot_id = ? AND module_name = 'formation'", [s])
	_exec(db, "formation_row", ("INSERT INTO world_state (slot_id, module_name, data) VALUES (?, 'formation', ?)"),
		[s, JSON.stringify(formation)])
	# 组织账注入容器行：读真实行 → 填 organizations → 写回（保留容器其余真实字段）
	if not db.query_with_bindings(
			"SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'world_state'", [s]):
		push_error("[fixtures] 容器行读取失败: %s" % str(db.error_message))
		db.close_db()
		get_tree().quit(1)
		return
	var rows: Array = db.query_result
	if rows.is_empty():
		push_error("[fixtures] 基础档缺 world_state 容器行（WorldState 未写入？）")
		db.close_db()
		get_tree().quit(1)
		return
	var container: Dictionary = JSON.parse_string(str(rows[0].get("data", "{}")))
	# 死 iid 形态（真实旧档同款）：personnel 指向已失效的实例 id，读档按活实体重写
	container["organizations"] = {
		"org_1": {
			"id": "org_1", "name": "fixture一班", "tag": 0, "tier": 1,
			"parent_org": "", "child_orgs": [], "commander_id": "",
			"personnel": ["1125899906842624", "1125899906842625"],
			"personnel_template": {}, "equipment_template": {},
			"autonomy_level": 1, "succession_rule": 0, "default_behavior": {},
			"supply_priority": 1, "current_project": "", "location": "", "state": 0,
		},
		"org_2": {
			"id": "org_2", "name": "fixture二班", "tag": 0, "tier": 1,
			"parent_org": "", "child_orgs": [], "commander_id": "",
			"personnel": ["1125899906842626", "1125899906842627"],
			"personnel_template": {}, "equipment_template": {},
			"autonomy_level": 1, "succession_rule": 0, "default_behavior": {},
			"supply_priority": 1, "current_project": "", "location": "", "state": 0,
		},
	}
	_exec(db, "container_row", ("UPDATE world_state SET data = ? WHERE slot_id = ? AND module_name = 'world_state'"),
		[JSON.stringify(container), s])
