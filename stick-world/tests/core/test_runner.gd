class_name TestRunner
extends RefCounted
## 测试运行器（加固版）。
##
## 使用：
##   var runner := TestRunner.new()
##   runner.add_test("my test", func():
##       runner.assert_equal(2 + 2, 4)
##   )
##   runner.run()
##   print(runner.summary())
##
## 加固点（相对旧版，见 docs/项目/P0重审与稳定化方案.md §3.2）：
##   - **零断言守卫**：用例跑完 0 次断言直接判失败（防 return 静默通过）
##   - **async 用例内建**：add_test(name, fn, true) + run_async()，免去手动 begin/end_test 配对
##   - 断言 API 扩充：assert_false / assert_lt / assert_gt / assert_approx / assert_null / assert_not_null
##   - 汇总输出断言总数
##
## 兼容旧用法：add_test(name, fn) + run()、begin_test/end_test 手动配对仍然有效。

var _tests: Array = []
var _results: Array = []
var _current_test_name: String = ""
var _current_failed: bool = false
var _current_messages: Array = []
var _current_assertions: int = 0


func add_test(name: String, fn: Callable, is_async: bool = false) -> void:
	_tests.append({"name": name, "fn": fn, "async": is_async})


## 同步运行（仅适用于纯同步用例；async 用例请用 run_async）。
func run() -> void:
	_results.clear()
	for t in _tests:
		_start(t["name"])
		var fn: Callable = t["fn"]
		if fn.is_valid():
			fn.call()
		_finish()


## 异步运行（推荐）：async 用例 await 等待完成；同步用例照常。
func run_async() -> void:
	_results.clear()
	for t in _tests:
		_start(t["name"])
		var fn: Callable = t["fn"]
		if fn.is_valid():
			if t["async"]:
				await fn.call()
			else:
				fn.call()
		_finish()


# ─────────────────────────────── 断言（均计入断言计数）────────────────────────────────

func assert_true(cond: bool, msg: String = "") -> void:
	_count_assert()
	if not cond:
		_fail("assert_true 失败: %s" % msg)


func assert_false(cond: bool, msg: String = "") -> void:
	_count_assert()
	if cond:
		_fail("assert_false 失败: %s" % msg)


func assert_equal(a, b, msg: String = "") -> void:
	_count_assert()
	# 类型不同直接判不等（避免 int/String 直接比较触发 SCRIPT ERROR 污染日志）；
	# 例外：String 与 StringName 在 GDScript 中语义相等
	var mismatch: bool = false
	if typeof(a) != typeof(b):
		if (a is String and b is StringName) or (a is StringName and b is String):
			mismatch = a != b
		else:
			mismatch = true
	else:
		mismatch = a != b
	if mismatch:
		_fail("assert_equal 失败: %s vs %s (%s)" % [str(a), str(b), msg])


func assert_not_equal(a, b, msg: String = "") -> void:
	_count_assert()
	var same_value: bool = false
	if typeof(a) != typeof(b):
		if (a is String and b is StringName) or (a is StringName and b is String):
			same_value = a == b
	else:
		same_value = a == b
	if same_value:
		_fail("assert_not_equal 失败: %s == %s (%s)" % [str(a), str(b), msg])


func assert_lt(a: float, b: float, msg: String = "") -> void:
	_count_assert()
	if not a < b:
		_fail("assert_lt 失败: %s >= %s (%s)" % [str(a), str(b), msg])


func assert_gt(a: float, b: float, msg: String = "") -> void:
	_count_assert()
	if not a > b:
		_fail("assert_gt 失败: %s <= %s (%s)" % [str(a), str(b), msg])


func assert_approx(a: float, b: float, epsilon: float = 0.001, msg: String = "") -> void:
	_count_assert()
	if absf(a - b) > epsilon:
		_fail("assert_approx 失败: %s vs %s (ε=%s) (%s)" % [str(a), str(b), str(epsilon), msg])


func assert_null(v, msg: String = "") -> void:
	_count_assert()
	if v != null:
		_fail("assert_null 失败: 实际非空 (%s)" % msg)


func assert_not_null(v, msg: String = "") -> void:
	_count_assert()
	if v == null:
		_fail("assert_not_null 失败: 实际为空 (%s)" % msg)


# ─────────────────────────────── 结果汇总 ────────────────────────────────

func summary() -> String:
	var passed: int = 0
	var total: int = _results.size()
	var total_asserts: int = 0
	for r in _results:
		if r["passed"]:
			passed += 1
		total_asserts += r["asserts"]
	var lines: Array = ["", "=== 测试汇总: %d / %d 通过（断言 %d 次）===" % [passed, total, total_asserts]]
	for r in _results:
		var prefix: String = "[OK]" if r["passed"] else "[FAIL]"
		lines.append("%s  %s" % [prefix, r["name"]])
		if not r["passed"]:
			for m in r["messages"]:
				lines.append("        %s" % m)
	return "\n".join(lines)


func all_passed() -> bool:
	for r in _results:
		if not r["passed"]:
			return false
	return true


func get_results() -> Array:
	return _results


# ─────────────────────────────── 内部 ────────────────────────────────

func _start(name: String) -> void:
	_current_test_name = name
	_current_failed = false
	_current_messages = []
	_current_assertions = 0


func _finish() -> void:
	# 零断言守卫：用例跑完 0 次断言，判失败（防静默通过）
	if _current_assertions == 0:
		_current_failed = true
		_current_messages.append("零断言：用例未执行任何断言（疑似静默通过）")
	_results.append({
		"name": _current_test_name,
		"passed": not _current_failed,
		"messages": _current_messages.duplicate(),
		"asserts": _current_assertions,
	})


func _count_assert() -> void:
	_current_assertions += 1


func _fail(msg: String) -> void:
	_current_failed = true
	_current_messages.append(msg)


# ─────────────────────────────── 异步测试支持（旧接口，保留兼容）────────────────────────────────

## 标记一个测试开始（手动管理异步用例生命周期）。
func begin_test(name: String) -> void:
	_start(name)


## 标记当前测试结束，记录结果。需与 begin_test 配对使用。
func end_test() -> void:
	_finish()
