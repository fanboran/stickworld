extends Node
## PlacementGrid 纯单元测试 -- 阶段 0.2 占地网格核心逻辑。
##
## 这是「重新设计测试」的示范样本（见 P0 重审方案 §三）：
##   - 纯逻辑：不加载 GameRoot / 地图 / 场景，只测 PlacementGrid 自身
##   - 隔离：每个用例自建 fixture（_new_grid），无跨用例共享状态
##   - AAA：Arrange-Act-Assert，每个用例只断言一件事的主题
##   - 确定性：无 await、无固定帧等待、无时序依赖
##
## 运行：
##   godot --headless --path "F:\VSCode\game-2\stick-world" "res://tests/unit/test_placement_grid.tscn"
## 退出码：0 全过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptPlacementGrid := preload("res://modules/world/scripts/placement/placement_grid.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_test_cell_size_constant()
	_test_world_to_cell_round_trip()
	_test_occupy_marks_cells()
	_test_occupy_conflict_returns_false()
	_test_release_by_occupant()
	_test_can_place_respects_bounds()
	_test_expand_to_negative_cells()
	_test_build_mask_blocks_placement()
	_test_get_occupied_count()
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── fixture ────────────────────────────────

func _new_grid(w: int = 16) -> ScriptPlacementGrid:
	var g := ScriptPlacementGrid.new()
	g.grid_width = w
	add_child(g) # 触发 _ready -> _init_cells，叶子节点同步完成
	return g


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_cell_size_constant() -> void:
	_runner.add_test("PlacementGrid: CELL_SIZE == 32", func():
		_runner.assert_equal(ScriptPlacementGrid.CELL_SIZE, 32, "条带宽度应为 32px")
	)


func _test_world_to_cell_round_trip() -> void:
	_runner.add_test("PlacementGrid: 世界坐标<->条带互转", func():
		var g := _new_grid()
		_runner.assert_equal(g.world_to_cell(Vector2(100, 999)), 3, "100px -> cell 3（仅看 X）")
		_runner.assert_equal(g.cell_to_world(3), 112.0, "cell 3 中心 = 3*32+16 = 112")
	)


func _test_occupy_marks_cells() -> void:
	_runner.add_test("PlacementGrid: occupy 标记连续条带", func():
		var g := _new_grid()
		var ok := g.occupy(5, 2, "bld_a")
		_runner.assert_true(ok, "occupy(5,2) 应成功")
		_runner.assert_true(g.is_occupied(5), "cell 5 应被占用")
		_runner.assert_true(g.is_occupied(6), "cell 6 应被占用")
		_runner.assert_true(not g.is_occupied(4), "cell 4 不应被占用")
	)


func _test_occupy_conflict_returns_false() -> void:
	_runner.add_test("PlacementGrid: 冲突 occupy 返回 false", func():
		var g := _new_grid()
		_runner.assert_true(g.occupy(5, 2, "bld_a"), "首次 occupy(5,2) 成功")
		_runner.assert_true(not g.occupy(6, 1, "bld_b"), "occupy(6,1) 与已占用冲突应失败")
	)


func _test_release_by_occupant() -> void:
	_runner.add_test("PlacementGrid: release 按 occupant 释放", func():
		var g := _new_grid()
		g.occupy(5, 2, "bld_a")
		g.release("bld_a")
		_runner.assert_true(not g.is_occupied(5), "release 后 cell 5 应空闲")
		_runner.assert_true(not g.is_occupied(6), "release 后 cell 6 应空闲")
	)


func _test_can_place_respects_bounds() -> void:
	_runner.add_test("PlacementGrid: can_place 越界返回 false", func():
		var g := _new_grid(16) # cells 0..15
		_runner.assert_true(g.can_place(14, 2), "cell 14-15 在界内应可建")
		_runner.assert_true(not g.can_place(15, 2), "cell 15-16 越界应不可建")
	)


func _test_expand_to_negative_cells() -> void:
	_runner.add_test("PlacementGrid: expand_to 支持负坐标", func():
		var g := _new_grid(8)
		_runner.assert_true(not g.is_in_bounds(-3), "扩展前 cell -3 应越界")
		g.expand_to(-5)
		_runner.assert_equal(g.get_min_cell(), -5, "扩展后 min_cell = -5")
		_runner.assert_true(g.is_in_bounds(-3), "扩展后 cell -3 应在界内")
		_runner.assert_true(g.occupy(-3, 2, "bld_neg"), "负坐标 occupy 应成功")
	)


func _test_build_mask_blocks_placement() -> void:
	_runner.add_test("PlacementGrid: BuildMask 阻止占用", func():
		var g := _new_grid(16)
		g.set_blocked_area(8, 2)
		_runner.assert_true(not g.can_place(8, 1), "被 BuildMask 标记的 cell 8 不可建")
		_runner.assert_true(g.can_place(10, 1), "未标记的 cell 10 可建")
		_runner.assert_equal(g.get_blocked_count(), 2, "应有 2 个 blocked 条带")
	)


func _test_get_occupied_count() -> void:
	_runner.add_test("PlacementGrid: get_occupied_count 统计", func():
		var g := _new_grid(16)
		g.occupy(2, 3, "a")
		g.occupy(10, 2, "b")
		_runner.assert_equal(g.get_occupied_count(), 5, "3+2=5 条带被占用")
	)
