extends Node
## 集成测试：放置网格（PlacementGrid / PlacementValidator / BuildMask）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_placement_grid_units.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - PlacementGrid 初始化 / 占用释放 / 冲突检测 / 边界 / 坐标转换
##   - PlacementValidator 校验通过 / 越界失败 / 冲突失败
##   - BuildMask 标记 / 影响占用 / 区域标记
##
## 从 test_village_map.gd 拆分（原 PlacementGrid / Validator / BuildMask 单元测试区块）。
## 纯单元测试，不依赖 GameRoot 场景。

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptPlacementGrid := preload("res://modules/world/placement_grid/placement_grid.gd")
const ScriptPlacementValidator := preload("res://modules/world/placement_grid/placement_validator.gd")

var _runner: TestRunner
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	for t in _tests:
		_runner.add_test(t["name"], t["fn"])
	_runner.run()
	print(_runner.summary())

	var exit_code := 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "PlacementGrid: 初始化格子数", "fn": Callable(self, "_test_grid_init")})
	_tests.append({"name": "PlacementGrid: 占用与释放", "fn": Callable(self, "_test_grid_occupy_release")})
	_tests.append({"name": "PlacementGrid: 冲突检测", "fn": Callable(self, "_test_grid_conflict")})
	_tests.append({"name": "PlacementGrid: 边界检查", "fn": Callable(self, "_test_grid_bounds")})
	_tests.append({"name": "PlacementGrid: 坐标转换", "fn": Callable(self, "_test_grid_coords")})
	_tests.append({"name": "PlacementGrid: BuildMask 标记与查询", "fn": Callable(self, "_test_grid_build_mask")})
	_tests.append({"name": "PlacementGrid: BuildMask 影响占用查询", "fn": Callable(self, "_test_grid_build_mask_occupied")})
	_tests.append({"name": "PlacementGrid: BuildMask 区域标记", "fn": Callable(self, "_test_grid_build_mask_area")})
	_tests.append({"name": "PlacementValidator: 校验通过", "fn": Callable(self, "_test_validator_pass")})
	_tests.append({"name": "PlacementValidator: 越界失败", "fn": Callable(self, "_test_validator_oob")})
	_tests.append({"name": "PlacementValidator: 冲突失败", "fn": Callable(self, "_test_validator_conflict")})


# ─────────────────────────────── 辅助 ────────────────────────────────

func _make_grid() -> ScriptPlacementGrid:
	var g: ScriptPlacementGrid = ScriptPlacementGrid.new()
	g.grid_width = 8
	add_child(g)
	g._ready()
	return g


# ─────────────────────────────── PlacementGrid 单元测试 ────────────────────────────────

func _test_grid_init() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	_runner.assert_equal(g.get_total_count(), 8, "8 条带")
	_runner.assert_equal(g.get_occupied_count(), 0, "初始应无占用")
	g.queue_free()


func _test_grid_occupy_release() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 占用 2 条带宽
	var ok: bool = g.occupy(1, 2, "building_a")
	_runner.assert_true(ok, "占用 2 条带应成功")
	_runner.assert_true(g.is_occupied(1), "(1) 应占用")
	_runner.assert_true(g.is_occupied(2), "(2) 应占用")
	_runner.assert_true(not g.is_occupied(0), "(0) 应空闲")
	_runner.assert_equal(g.get_occupied_count(), 2, "应占用 2 条带")
	# 释放
	g.release("building_a")
	_runner.assert_true(not g.is_occupied(1), "释放后 (1) 应空闲")
	_runner.assert_equal(g.get_occupied_count(), 0, "释放后应无占用")
	g.queue_free()


func _test_grid_conflict() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	g.occupy(0, 2, "a")
	# 重叠占用应失败
	var ok: bool = g.occupy(1, 2, "b")
	_runner.assert_true(not ok, "重叠占用应失败")
	# 不重叠应成功
	ok = g.occupy(3, 2, "c")
	_runner.assert_true(ok, "不重叠占用应成功")
	g.queue_free()


func _test_grid_bounds() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	_runner.assert_true(g.is_in_bounds(0), "(0) 应在边界内")
	_runner.assert_true(g.is_in_bounds(7), "(7) 应在边界内")
	_runner.assert_true(not g.is_in_bounds(8), "(8) 应越界")
	_runner.assert_true(not g.is_in_bounds(-1), "(-1) 应越界")
	# 越界占用应失败
	var oob_ok: bool = g.occupy(7, 2, "x")
	_runner.assert_true(not oob_ok, "越界占用应失败")
	# 越界 is_occupied 返回 true
	_runner.assert_true(g.is_occupied(100), "越界 is_occupied 应返回 true")
	g.queue_free()


func _test_grid_coords() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 条带 0 中心 = 16.0
	var w: float = g.cell_to_world(0)
	_runner.assert_equal(w, 16.0, "条带 0 中心应为 16.0")
	# world_to_cell
	var c: int = g.world_to_cell(Vector2(16, 16))
	_runner.assert_equal(c, 0, "(16,16) 应映射到 0")
	c = g.world_to_cell(Vector2(33, 33))
	_runner.assert_equal(c, 1, "(33,33) 应映射到 1")
	g.queue_free()


# ─────────────────────────────── BuildMask 测试 ────────────────────────────────

func _test_grid_build_mask() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 初始无 blockage
	_runner.assert_true(not g.is_blocked(0), "(0) 初始应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 0, "初始 blocked 数应为 0")
	# 标记单格
	g.set_blocked(1)
	_runner.assert_true(g.is_blocked(1), "(1) 标记后应 blocked")
	_runner.assert_true(not g.is_blocked(0), "(0) 应仍未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 1, "blocked 数应为 1")
	# 取消标记
	g.set_blocked(1, false)
	_runner.assert_true(not g.is_blocked(1), "(1) 取消后应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 0, "取消后 blocked 数应为 0")
	g.queue_free()


func _test_grid_build_mask_occupied() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# BuildMask 标记的格应视为 occupied
	g.set_blocked(2)
	_runner.assert_true(g.is_occupied(2), "blocked 格应视为 occupied")
	# can_place 应返回 false
	_runner.assert_true(not g.can_place(2, 1), "blocked 格 can_place 应失败")
	# occupy 应失败（因 is_occupied 返回 true -> can_place false）
	var ok: bool = g.occupy(2, 1, "test")
	_runner.assert_true(not ok, "blocked 格 occupy 应失败")
	# 未标记的格应正常
	_runner.assert_true(not g.is_occupied(3), "(3) 应未 occupied")
	_runner.assert_true(g.can_place(3, 1), "(3) can_place 应成功")
	g.queue_free()


func _test_grid_build_mask_area() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 标记 2 条带
	g.set_blocked_area(0, 2)
	_runner.assert_true(g.is_blocked(0), "(0) 应 blocked")
	_runner.assert_true(g.is_blocked(1), "(1) 应 blocked")
	_runner.assert_true(not g.is_blocked(2), "(2) 应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 2, "2 条带应有 2 blocked")
	# clear_blockage
	g.clear_blockage()
	_runner.assert_equal(g.get_blocked_count(), 0, "clear 后应无 blocked")
	g.queue_free()


# ─────────────────────────────── PlacementValidator 测试 ────────────────────────────────

func _test_validator_pass() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	var v := ScriptPlacementValidator.new()
	var r = v.validate_placement(g, 0, 2)
	_runner.assert_true(r.ok, "空闲区域应校验通过")
	g.queue_free()


func _test_validator_oob() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	var v := ScriptPlacementValidator.new()
	var r = v.validate_placement(g, 7, 2)
	_runner.assert_true(not r.ok, "越界应校验失败")
	_runner.assert_true(r.reason.length() > 0, "失败应有原因")
	g.queue_free()


func _test_validator_conflict() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	g.occupy(0, 2, "a")
	var v := ScriptPlacementValidator.new()
	var r = v.validate_placement(g, 1, 2)
	_runner.assert_true(not r.ok, "冲突应校验失败")
	g.queue_free()
