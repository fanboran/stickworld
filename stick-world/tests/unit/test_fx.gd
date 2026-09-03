extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：FxLibrary 爆发特效配置 + FxPool 池化语义。
## 不进场景树（FxPool 不 add_child 到树，池节点局部持有）；不碰 autoload。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFxPool := preload("res://modules/fx/scripts/fx_pool.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("FxLibrary: 特效 ID 常量非空且互异", _test_ids)
	_runner.add_test("FxLibrary: 五种爆发特效配置齐备", _test_create_burst)
	_runner.add_test("FxLibrary: 未知 ID 返回 null", _test_unknown_id)
	_runner.add_test("FxPool: spawn_burst 空树静默忽略", _test_spawn_burst_null_tree)
	_runner.add_test("FxPool: 无池场景 spawn_burst 静默不崩", _test_spawn_burst_no_pool)
	_runner.add_test("FxPool: burst 池扩容并置 emitting", _test_burst_pools)
	_runner.add_test("FxPool: 空池 take_from_pool 返回 null", _test_take_empty)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_ids() -> void:
	var ids: Array = [FxLibrary.BUILD_DUST, FxLibrary.GATHER_DEBRIS, FxLibrary.HIT_SPARK,
			FxLibrary.MAGIC_BLAST, FxLibrary.AMBIENT_SPARKLE]
	var seen := {}
	for id: String in ids:
		_runner.assert_true(id != "", "特效 ID 不应为空")
		_runner.assert_true(not seen.has(id), "特效 ID 应互异: %s" % id)
		seen[id] = true


func _test_create_burst() -> void:
	for id: String in [FxLibrary.BUILD_DUST, FxLibrary.GATHER_DEBRIS, FxLibrary.HIT_SPARK,
			FxLibrary.MAGIC_BLAST, FxLibrary.AMBIENT_SPARKLE]:
		var p := FxLibrary.create_burst(id)
		_runner.assert_true(p != null, "%s 应产出粒子" % id)
		if p != null:
			_runner.assert_true(p.one_shot, "%s 应为一次性爆发" % id)
			_runner.assert_true(not p.emitting, "%s 创建时不应发射" % id)
			_runner.assert_true(p.process_material != null, "%s 应配置 process_material" % id)
			p.free()


func _test_unknown_id() -> void:
	_runner.assert_true(FxLibrary.create_burst("no_such_effect") == null, "未知 ID 应返回 null")


func _test_spawn_burst_null_tree() -> void:
	FxPool.spawn_burst(null, FxLibrary.HIT_SPARK, Vector2.ZERO)
	_runner.assert_true(true, "空树调用应静默返回不崩溃")


func _test_spawn_burst_no_pool() -> void:
	# 前置：本测试环境无 fx_pool 组节点（未装配 GameRoot）
	_runner.assert_true(get_tree().get_first_node_in_group("fx_pool") == null,
			"前置失败：测试环境不应存在 fx_pool")
	FxPool.spawn_burst(get_tree(), FxLibrary.HIT_SPARK, Vector2.ZERO)
	_runner.assert_true(true, "无池调用应静默返回不崩溃")


func _test_burst_pools() -> void:
	var pool: FxPool = ScriptFxPool.new()
	pool.burst(FxLibrary.HIT_SPARK, Vector2(10, 20))
	_runner.assert_equal(pool.get_child_count(), 1, "首次 burst 应扩池 1 个粒子")
	var child := pool.get_child(0) as GPUParticles2D
	_runner.assert_true(child != null, "池内应为 GPUParticles2D")
	if child != null:
		_runner.assert_true(child.emitting, "burst 后粒子应处于发射态")
		_runner.assert_true(child.global_position == Vector2(10, 20),
				"树外节点 global_position 应为设置值")
	# 清理（避免游离粒子泄漏到批量进程）
	for c in pool.get_children():
		c.free()
	pool.free()


func _test_take_empty() -> void:
	var pool: FxPool = ScriptFxPool.new()
	_runner.assert_true(pool.take_from_pool() == null, "空池取用应返回 null")
	pool.free()
