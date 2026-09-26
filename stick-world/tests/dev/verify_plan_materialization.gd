extends Node
## 验证探针：CityGen plan → Building 实体物化层（ROOT-2）。
##   godot --path stick-world res://tests/dev/verify_plan_materialization.tscn
## 流程：GameRoot 完整链启动直连主街（townlet 档 plan）→ 断言 plan 数据口 →
## 物化结果（数量/分组/状态/视觉壳/缩放/落位/占用/注册）→ 工位几何落在
## 卡脚印内 → 读档清场保留 plan 建筑（存档过滤）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const BuildingGenAPI: GDScript = preload("res://modules/building_gen/api.gd")

var _fails: int = 0
var _gr: Node = null
var _map: Node2D = null


func _ready() -> void:
	_gr = GameRootScene.instantiate()
	add_child(_gr)
	await _wait(6.0)
	var sl: Node = _gr.get("scene_loader")
	_map = sl.get_current_map() if sl != null and sl.has_method("get_current_map") else null
	_check(_map != null, "主街地图已加载")
	if _map == null:
		_finish()
		return
	_check_plan_port()
	_check_materialized()
	_check_geometry()
	_check_clear_survival()
	_finish()


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _check(ok: bool, label: String) -> void:
	if ok:
		print("[PASS] ", label)
	else:
		_fails += 1
		print("[FAIL] ", label)


# ── plan 数据口 ─────────────────────────────────────────────────────────

func _check_plan_port() -> void:
	var entries: Array = _map.get_plan_buildings() if _map.has_method("get_plan_buildings") else []
	_check(not entries.is_empty(), "get_plan_buildings 非空（主街 townlet plan 前排，实 %d 条）" % entries.size())
	var mapped: int = 0
	for e: Variant in entries:
		if not BuildingGenAPI.runtime_def_for_pipeline(str(e.get("def", ""))).is_empty():
			mapped += 1
	_check(mapped > 0, "plan 前排含可物化条目（映射命中 %d/%d）" % [mapped, entries.size()])
	if _map.has_method("get_plan_baseline_y"):
		var b0: float = _map.get_plan_baseline_y(0.6)
		_check(absf(b0 - (516.0 + 0.6 * 24.0)) < 0.01,
				"plan 基线公式与 3D 卡脚线同源（z=0.6 → %.1f）" % b0)


# ── 物化结果 ─────────────────────────────────────────────────────────────

func _check_materialized() -> void:
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	var grid: Node = _map.get("placement_grid") if "placement_grid" in _map else null
	_check(host != null, "building_host 存在")
	if host == null:
		return
	var entries: Array = _map.get_plan_buildings()
	var expected: int = 0
	for e: Variant in entries:
		var def_id: String = BuildingGenAPI.runtime_def_for_pipeline(str(e.get("def", "")))
		if not def_id.is_empty():
			expected += 1
	var shells: Array = []
	for c in host.get_children():
		if c is Node2D and c.has_meta("plan_generated"):
			shells.append(c)
	_check(shells.size() == expected,
			"物化数量与映射命中数一致（%d/%d，plan 共 %d 条）" % [shells.size(), expected, entries.size()])

	var api: Node = _gr.get_construction_api() if _gr.has_method("get_construction_api") else null
	var manager: Node = api.get("_manager") if api != null else null
	var registry: Dictionary = manager.get("_buildings") if manager != null else {}
	var group_all: Array = get_tree().get_nodes_in_group("building")
	var smithy_seen: bool = false
	for b in shells:
		var b2d: Node2D = b as Node2D
		var label: String = "def=%s cell=%d" % [str(b2d.get("def_id")), int(b2d.get("cell_x"))]
		_check(b2d in group_all, "物化建筑进 building 组（%s）" % label)
		_check(bool(b2d.get("is_terrain")), "物化建筑 is_terrain（不可拆，%s）" % label)
		_check(int(b2d.get("state")) == 2, "物化建筑 OPERATIONAL（%s）" % label)  # State.OPERATIONAL=2
		var ext: Node = b2d.get_node_or_null("Exterior")
		_check(ext == null or not (ext as CanvasItem).visible,
				"外部视觉已关（视觉壳，%s）" % label)
		var bid: String = str(b2d.get_meta("building_id", ""))
		_check(registry.has(bid), "已注册进管理表（%s id=%s）" % [label, bid])
		if grid != null:
			var occ: Variant = grid.get_occupant(int(b2d.get("cell_x")))
			_check(occ == b2d, "网格占用者=实体（%s）" % label)
			_check(not grid.can_place(int(b2d.get("cell_x")), 1),
					"占用+封锁双态下不可再建（%s）" % label)
		if str(b2d.get("def_id")) == "smithy_lv1":
			_check_smithy_slots(b2d)
			smithy_seen = true
	_check(smithy_seen, "铁匠铺已物化（townlet craft 带 smithy1/2，工位链有宿主）")


func _check_smithy_slots(b2d: Node2D) -> void:
	if b2d.has_method("get_work_slot_count"):
		_check(int(b2d.call("get_work_slot_count")) >= 2, "铁匠铺工位 ≥2（铁砧+熔炉）")


# ── 几何：实体贴卡（工位世界位落在卡脚印 x 区间内）────────────────────────

func _check_geometry() -> void:
	var entries: Array = _map.get_plan_buildings()
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	if host == null:
		return
	for e: Variant in entries:
		var def_id: String = BuildingGenAPI.runtime_def_for_pipeline(str(e.get("def", "")))
		if def_id != "smithy_lv1":
			continue
		var center: float = float(e.get("x", 0.0))
		var cells: float = float(e.get("cells", 0.0))
		var left_px: float = (center - cells * 0.5) * 24.0
		var right_px: float = (center + cells * 0.5) * 24.0
		# 找对应物化实体（同 def 且 x 贴左沿）
		for c in host.get_children():
			if not (c is Node2D) or not c.has_meta("plan_generated"):
				continue
			var b2d: Node2D = c as Node2D
			if str(b2d.get("def_id")) != "smithy_lv1":
				continue
			if absf(b2d.global_position.x - left_px) > 0.5:
				continue
			var scale_f: float = b2d.scale.x
			var expect_scale: float = float(int(b2d.get("width"))) / 16.0  # def 宽=16
			_check(absf(scale_f - expect_scale) < 0.001,
					"缩放=plan宽/def宽（%.3f，width=%d）" % [scale_f, int(b2d.get("width"))])
			var slots: Array = b2d.call("get_work_slot_positions") if b2d.has_method("get_work_slot_positions") else []
			var in_span: int = 0
			for p in slots:
				var px: float = float((p as Vector2).x)
				if px >= left_px - 1.0 and px <= right_px + 1.0:
					in_span += 1
			_check(not slots.is_empty() and in_span == slots.size(),
					"工位全部落在卡脚印 x 区间（%d/%d，[%.0f,%.0f]）" % [in_span, slots.size(), left_px, right_px])
			# y 落位：实体根 y = 基线 − 碰撞底×缩放
			var z: float = float(e.get("z", 0.6))
			var baseline: float = 516.0 + z * 24.0
			var cbl: float = float(b2d.call("get_collision_bottom_local"))
			var expect_y: float = baseline - cbl * scale_f
			_check(absf(b2d.global_position.y - expect_y) < 0.5,
					"y 贴卡脚基线（%.1f vs 期望 %.1f）" % [b2d.global_position.y, expect_y])
			return
	_check(false, "未找到铁匠铺物化实体做几何断言")


# ── 读档清场保留 plan 建筑 ───────────────────────────────────────────────

func _check_clear_survival() -> void:
	var api: Node = _gr.get_construction_api() if _gr.has_method("get_construction_api") else null
	var manager: Node = api.get("_manager") if api != null else null
	if manager == null:
		_check(false, "manager 不可达，清场断言跳过")
		return
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	var grid: Node = _map.get("placement_grid") if "placement_grid" in _map else null
	if host == null or grid == null:
		_check(false, "host/grid 不可达，清场断言跳过")
		return
	# 摆一栋玩家建筑（DB 侧语义），再模拟读档清场
	var placed: Dictionary = {}
	for c in range(grid.get_min_cell(), grid.get_max_cell()):
		if grid.can_place(c, 2):
			var r: Dictionary = api.spawn_operational_building("placeholder", c, 2)
			if r.get("ok", false):
				placed = r
				break
	_check(placed.get("ok", false), "玩家建筑已摆放（清场对照样本，cell=%s）" % str(placed.get("cell_x", "?")))
	var persistence: Node = manager.get_node_or_null("BuildingPersistence")
	if persistence == null:
		_check(false, "BuildingPersistence 不可达")
		return
	var plan_before: int = 0
	for c in host.get_children():
		if c is Node2D and c.has_meta("plan_generated"):
			plan_before += 1
	persistence.call("_clear_all_buildings_and_projects")
	var plan_after: int = 0
	var freed_player: bool = true
	for c in host.get_children():
		if c is Node2D and c.has_meta("plan_generated"):
			plan_after += 1
			if c.is_queued_for_deletion():
				freed_player = false
		elif c is Node2D and not c.is_queued_for_deletion():
			freed_player = false
	_check(plan_after == plan_before, "读档清场保留 plan 建筑（%d → %d）" % [plan_before, plan_after])
	_check(freed_player, "读档清场释放玩家建筑（DB 侧语义）")


func _finish() -> void:
	if _fails > 0:
		print("=== ROOT-2 物化探针: %d 项失败 ===" % _fails)
		get_tree().quit(1)
	else:
		print("=== ROOT-2 物化探针: 全部通过 ===")
		get_tree().quit(0)
