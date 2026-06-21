class_name TestRunner
extends RefCounted
## 最小测试运行器。
##
## 使用：
##   var runner := TestRunner.new()
##   runner.add_test("my test", func():
##       runner.assert_equal(2 + 2, 4)
##   )
##   runner.run()
##   print(runner.summary())

var _tests: Array = []
var _results: Array = []
var _current_test_name: String = ""
var _current_failed: bool = false
var _current_messages: Array = []


func add_test(name: String, fn: Callable) -> void:
	_tests.append({"name": name, "fn": fn})


func run() -> void:
	_results.clear()
	for t in _tests:
		_current_test_name = t["name"]
		_current_failed = false
		_current_messages = []
		var fn: Callable = t["fn"]
		if fn.is_valid():
			fn.call()
		_results.append({
			"name": _current_test_name,
			"passed": not _current_failed,
			"messages": _current_messages.duplicate(),
		})


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		_current_failed = true
		_current_messages.append("assert_true 失败: %s" % msg)


func assert_equal(a, b, msg: String = "") -> void:
	if a != b:
		_current_failed = true
		_current_messages.append("assert_equal 失败: %s vs %s (%s)" % [str(a), str(b), msg])


func assert_not_equal(a, b, msg: String = "") -> void:
	if a == b:
		_current_failed = true
		_current_messages.append("assert_not_equal 失败: %s == %s (%s)" % [str(a), str(b), msg])


func summary() -> String:
	var passed: int = 0
	var total: int = _results.size()
	for r in _results:
		if r["passed"]:
			passed += 1
	var lines: Array = ["", "=== 测试汇总: %d / %d 通过 ===" % [passed, total]]
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
