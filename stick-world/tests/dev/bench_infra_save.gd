extends Node
## 基础设施基准①：存档往返全链（dev 层，headless）。
##
## 中期规模合成数据：WorldState 六容器塞满 + 组织 50 人 + 建筑 200 栋（真场景 placeholder）。
## 走 SaveManager.save_game → game_saving 信号 → 模块回调写 SQLite → load_game 读回全链。
## 分项计时：六容器序列化 / JSON.stringify / SQLite 建筑写入（现状逐行 vs 事务批包对照）/
## 全链存档 / 全链读回（含 JSON.parse + 反序列化）。
## 一致性对照：存前与读回后的 WorldState JSON 逐字节比对。
## 存档用独立槽位（slot 3/4），结束删除 db 文件清理现场。
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_save.tscn

const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")
const MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/village_a.tscn")

## 合成规模（中期存档体量）
const N_STICKMEN := 300
const N_ORGS := 20
const N_ORG_MEMBERS := 50
const N_REGIONS := 40
const N_BATTLES := 10
const N_PROJECTS := 50
const N_SUPPLY_CHAINS := 30
const N_BUILDINGS := 200

## SQLite 写入对照行数（与 N_BUILDINGS 同量级）
const BULK_ROWS := 200

# SQL 白名单（与 buildings 表一致，对照实验用）
const _SQL_BLD_DELETE := "DELETE FROM buildings WHERE slot_id = ? AND map_id = ?"

var _map: Node2D = null
var _cm: Node = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_fill_world_state()
	await _setup_building_fixture()
	_bench_world_state_serialize()
	_bench_sqlite_bulk_write()
	await _bench_full_roundtrip()
	_cleanup()
	print("BENCH save DONE")
	get_tree().quit(0)


# ─────────────────────────────── 合成数据 ────────────────────────────────

## 六容器塞满 + 组织 50 人（组织经 OrganizationManager 走真实注册路径）
func _fill_world_state() -> void:
	var org_mgr := OrganizationManager.new()
	org_mgr.set_world(WorldState)
	var root_result: Dictionary = org_mgr.create_organization("基准军团", "MILITARY", 1, "")
	var root_id: String = root_result["data"]["org_id"]
	for i in N_ORG_MEMBERS:
		var sid := "stm_%04d" % i
		WorldState.stickmen[sid] = _make_stickman(sid, i)
		org_mgr.assign_stickman(root_id, sid, "soldier")
	WorldState.organizations[root_id] = org_mgr.organizations[root_id]
	for i in range(1, N_ORGS):
		var oid := "org_%02d" % i
		var s: OrganizationState = OrganizationState.new()
		s.id = oid
		s.name = "组织%02d" % i
		s.tier = 2
		s.personnel = ["stm_%04d" % (i * 7 % N_ORG_MEMBERS), "stm_%04d" % (i * 13 % N_ORG_MEMBERS)]
		s.equipment_template = {"wpn_sword_001": 2}
		WorldState.organizations[oid] = s
	for i in N_REGIONS:
		var r := RegionState.new()
		r.id = i
		r.name = "区域%02d" % i
		r.resource_types = ["wood", "stone", "iron"]
		r.outline_points = _make_outline(i)
		r.buildings = []
		for j in 20:
			r.buildings.append("bld_%03d" % j)
		WorldState.regions[str(i)] = r
	for i in N_BATTLES:
		var b := BattleState.new()
		b.id = "battle_%02d" % i
		b.region_id = str(i % N_REGIONS)
		b.attacker_orgs = ["org_01", "org_02"]
		b.tactical_data = {"phase": i, "front_line": [float(i), float(i * 2)]}
		WorldState.battles[b.id] = b
	for i in N_PROJECTS:
		var p := ProjectState.new()
		p.id = "proj_%03d" % i
		p.name = "工程%03d" % i
		p.assigned_orgs = ["org_%02d" % (i % N_ORGS)]
		p.assigned_resources = {"wood": 100 + i, "stone": 50 + i}
		WorldState.projects[p.id] = p
	for i in N_SUPPLY_CHAINS:
		var sc := SupplyChainState.new()
		sc.id = "sc_%02d" % i
		sc.origin_region = str(i % N_REGIONS)
		sc.destination_region = str((i + 7) % N_REGIONS)
		sc.route = _make_route(i)
		WorldState.supply_chains[sc.id] = sc
	print("BENCH save 数据规模: stickmen=%d orgs=%d regions=%d battles=%d projects=%d supply_chains=%d"
		% [WorldState.stickmen.size(), WorldState.organizations.size(), WorldState.regions.size(),
		WorldState.battles.size(), WorldState.projects.size(), WorldState.supply_chains.size()])


func _make_stickman(id: String, i: int) -> StickmanState:
	var s := StickmanState.new()
	s.id = id
	s.name = "火柴人%04d" % i
	s.race = i % 8 as StickmanState.Race
	s.hp = 80.0 + i % 20
	s.max_hp = 100.0
	s.stamina = 70.0
	s.max_stamina = 100.0
	s.morale = 0.8
	s.attack = 10.0 + i % 5
	s.defense = 5.0
	s.speed = 60.0
	s.equipment = {"main_hand": "wpn_sword_001", "chest": "arm_chest_cloth"}
	s.skills = ["melee_%d" % (i % 3), "build"]
	s.traits = ["brave"]
	s.current_task = "drill_%d" % (i % 4)
	s.assigned_org = "org_00"
	s.org_rank = i % 5
	s.org_role = "soldier"
	s.location = Vector2(float(i * 13 % 2000), float(i * 7 % 1000))
	s.state = i % 4
	return s


## 区域轮廓：8 点多边形（正常数量级坐标；避免 cos 端点 1e-15 级数学噪声——
## 超小浮点经 JSON 往返不幂等，属测试数据病态值而非存档缺陷）
func _make_outline(seed_i: int) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	for k in 8:
		var ang := TAU * float(k) / 8.0 + float(seed_i)
		pts.append(Vector2(cos(ang) * 120.0 + 500.0, sin(ang) * 90.0 + 400.0))
	return pts


## 物流路线：24 个路点（Array[Vector2] 对齐 SupplyChainState.route）
func _make_route(seed_i: int) -> Array[Vector2]:
	var route: Array[Vector2] = []
	for k in 24:
		route.append(Vector2(float(k * 40 + seed_i), float(k * 17 % 500)))
	return route


# ─────────────────────────────── 建筑 fixture ────────────────────────────────

## 真场景 + 真 ConstructionManager，spawn 200 栋 placeholder（读档/存档路径真实）
func _setup_building_fixture() -> void:
	var t0 := Time.get_ticks_usec()
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	var cm := ScriptConstructionManager.new()
	cm.name = "BenchConstructionManager"
	add_child(cm)
	cm.set_map(_map)
	var ok: bool = await _await_cond(func(): return cm.is_building_registered("placeholder"), 5.0)
	if not ok:
		push_error("默认建筑场景未注册")
		get_tree().quit(1)
		return
	for i in N_BUILDINGS:
		var result: Dictionary = cm.spawn_operational_building("placeholder", 10 + i * 3)
		if not result.get("ok", false):
			push_error("预置建筑失败: %s" % str(result))
			get_tree().quit(1)
			return
	_cm = cm
	print("BENCH save setup: %d 栋建筑就绪（setup %d ms，非基准项）" % [N_BUILDINGS, (Time.get_ticks_usec() - t0) / 1000])


func _await_cond(cond: Callable, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


# ─────────────────────────────── 分项基准 ────────────────────────────────

## ① 六容器对象 → Dictionary（WorldStateSerializer 字段直写）
var _save_data: Dictionary = {}
var _json_before: String = ""

func _bench_world_state_serialize() -> void:
	var t0 := Time.get_ticks_usec()
	_save_data = WorldState.get_save_data()
	var t_ser := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	_json_before = JSON.stringify(_save_data)
	var t_json := Time.get_ticks_usec() - t0
	print("BENCH save WS序列化(六容器→Dict): %d us（%d 实体）" % [t_ser, WorldState.stickmen.size()])
	print("BENCH save JSON.stringify: %d us（%d 字符）" % [t_json, _json_before.length()])


## ② SQLite 建筑写入对照：现状逐行 insert_row vs 事务批包 insert_rows
## （直接复刻 building_persistence.save_to_db 的行构造，200 栋同量级；
##   fsync 延迟在 Windows 上抖动大，各跑 3 轮取最小值）
func _bench_sqlite_bulk_write() -> void:
	if not ClassDB.class_exists("SQLite"):
		print("BENCH save SQLite批量对照: 跳过（插件未加载）")
		return
	var rows_rowwise: Array = _make_building_rows()
	var path := ProjectSettings.globalize_path("user://bench_bulk_probe.db")
	var slot := 3
	var map_id := "bench_map"
	var t_rowwise := -1
	var t_bulk := -1
	for round_i in 3:
		# 现状：逐行 insert_row（autocommit，每行一次提交）
		var db = ClassDB.instantiate("SQLite")
		db.path = "user://bench_bulk_probe.db"
		db.foreign_keys = true
		db.open_db()
		db.query("CREATE TABLE IF NOT EXISTS buildings (slot_id INTEGER, building_id TEXT, map_id TEXT, def_id TEXT, cell_x INTEGER, width INTEGER, state INTEGER, health REAL, max_health REAL, is_terrain INTEGER, wall_tier INTEGER, is_gate INTEGER, region_id TEXT, PRIMARY KEY (slot_id, building_id))")
		var t0 := Time.get_ticks_usec()
		db.query_with_bindings(_SQL_BLD_DELETE, [slot, map_id])
		for row: Dictionary in rows_rowwise:
			db.insert_row("buildings", row)
		var t := Time.get_ticks_usec() - t0
		db.close_db()
		if t_rowwise < 0 or t < t_rowwise:
			t_rowwise = t
		# 对照：insert_rows 事务批包（单次提交）
		db = ClassDB.instantiate("SQLite")
		db.path = "user://bench_bulk_probe.db"
		db.foreign_keys = true
		db.open_db()
		t0 = Time.get_ticks_usec()
		db.query_with_bindings(_SQL_BLD_DELETE, [slot, map_id])
		db.insert_rows("buildings", rows_rowwise)
		t = Time.get_ticks_usec() - t0
		db.close_db()
		if t_bulk < 0 or t < t_bulk:
			t_bulk = t
	DirAccess.remove_absolute(path)
	print("BENCH save SQLite建筑写入200行 逐行insert_row(现状,3轮最优): %d us" % t_rowwise)
	print("BENCH save SQLite建筑写入200行 insert_rows批包(对照,3轮最优): %d us" % t_bulk)


func _make_building_rows() -> Array:
	var rows: Array = []
	for i in BULK_ROWS:
		rows.append({
			"slot_id": 3, "building_id": "%04d" % i, "map_id": "bench_map",
			"def_id": "placeholder", "cell_x": i * 3,
			"width": 2, "state": 2,
			"health": 100.0, "max_health": 100.0,
			"is_terrain": 0, "wall_tier": 0, "is_gate": 0,
			"region_id": "",
		})
	return rows


## ③ 全链存档 → 读回（真实 SaveManager + 信号 + 模块回调）
## 一致性口径：
##   第一跳（对象→JSON→parse→对象）：JSON 解析器把无类型字典里的 int 解成 float
##   （"phase":0 → 0.0），为既有序列化行为，只统计漂移不作门禁；
##   第二跳（读回状态 →再存→再读）：必须字节级一致（优化不得改变任何字节）。
func _bench_full_roundtrip() -> void:
	const SLOT := 3
	var t0 := Time.get_ticks_usec()
	var save_ok: bool = SaveManager.save_game(SLOT)
	var t_save := Time.get_ticks_usec() - t0
	print("BENCH save 全链存档(save_game): %d us（ok=%s，含WS表+建筑200+项目表+meta）" % [t_save, save_ok])
	if not save_ok:
		get_tree().quit(1)
		return
	# 篡改运行时状态再读回，确认读档真实覆盖
	WorldState.game_time = -1.0
	t0 = Time.get_ticks_usec()
	var load_ok: bool = SaveManager.load_game(SLOT)
	# 读档后立即 end_load（基准无场景恢复流程，不等 30s 兜底）
	SaveManager.end_load()
	var t_load := Time.get_ticks_usec() - t0
	print("BENCH save 全链读回(load_game+end_load): %d us（ok=%s，含JSON.parse+反序列化+建筑重建）" % [t_load, load_ok])
	if not load_ok:
		get_tree().quit(1)
		return
	# 第一跳漂移统计（int→float 既有行为）
	var t1 := Time.get_ticks_usec()
	var json_hop1 := JSON.stringify(WorldState.get_save_data())
	print("BENCH save 读回再序列化: %d us" % (Time.get_ticks_usec() - t1))
	print("BENCH save 第一跳: %s（%d → %d 字符，JSON int→float 既有漂移）"
		% ["一致" if json_hop1 == _json_before else "有漂移", _json_before.length(), json_hop1.length()])
	# 第二跳：读回状态原样再存再读，字节级一致 = 回归门禁
	var ok2: bool = SaveManager.save_game(SLOT)
	WorldState.game_time = -1.0
	var ok3: bool = SaveManager.load_game(SLOT)
	SaveManager.end_load()
	var json_hop2 := JSON.stringify(WorldState.get_save_data()) if ok3 else ""
	if ok2 and ok3 and json_hop2 == json_hop1:
		print("BENCH save 第二跳一致性: 字节级一致 PASS（回归门禁）")
	else:
		var diff_at := -1
		for c in mini(json_hop1.length(), json_hop2.length()):
			if json_hop1[c] != json_hop2[c]:
				diff_at = c
				break
		print("BENCH save 第二跳一致性: FAIL（存 ok=%s 读 ok=%s，%d → %d 字符，首差异 @%d）" % [ok2, ok3, json_hop1.length(), json_hop2.length(), diff_at])
		if diff_at >= 0:
			print("  hop1片段: …%s" % json_hop1.substr(maxi(0, diff_at - 40), 100))
			print("  hop2片段: …%s" % json_hop2.substr(maxi(0, diff_at - 40), 100))


func _cleanup() -> void:
	for slot in [3, 4]:
		SaveManager.delete_game(slot)
	# 独立槽位文件兜底清理
	var global_saves := ProjectSettings.globalize_path("user://saves")
	for slot in [3, 4]:
		var p := global_saves + "/save_%d.db" % slot
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
