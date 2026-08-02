class_name TestHelpers
extends RefCounted
## 测试辅助 -- 修补自研 TestRunner 的两个致命缺陷：**挂死** 与 **异步抖动**。
##
## 现状问题（见 P0 重审方案 §三）：
##   - 各 test_stage 用 `for i in N: await get_tree().process_frame` 等待就绪，
##     N 取少了没就绪（抖动/假失败），取少了也永远不会失败——条件不成立时直接进入断言。
##   - 没有超时：条件永不成立时测试无限挂死（test_stage_02/03 现象）。
##
## 本助手提供「等待就绪 + 超时失败」语义，是测试可信化的最小基建。

## 轮询等待 cond() 返回真值，超时返回 false。
## 用法：
##   var ok := await TestHelpers.await_condition(func(): return _map != null, 3.0, "地图加载")
##   _runner.assert_true(ok, "地图应在 3s 内加载")
## 注意：超时返回 false 而非挂死；调用方必须对返回值断言，否则等于零断言静默通过。
static func await_condition(cond: Callable, timeout_sec: float = 3.0, desc: String = "") -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		push_error("[TestHelpers] 无 SceneTree，无法 await")
		return false
	var deadline_ms: float = Time.get_ticks_msec() + timeout_sec * 1000.0
	while Time.get_ticks_msec() < deadline_ms:
		if cond.call():
			return true
		await tree.process_frame
	push_warning("[TestHelpers] 超时(%.2fs): %s" % [timeout_sec, desc])
	return false


## 等待信号 signal_name 被发射，超时返回 false。用于「等待某事件就绪」而非轮询条件。
## 用法：
##   var ok := await TestHelpers.await_signal(scene_loader, "map_loaded", 3.0)
static func await_signal(emitter: Object, signal_name: String, timeout_sec: float = 3.0) -> bool:
	if not emitter.has_signal(signal_name):
		push_warning("[TestHelpers] 对象无信号: %s" % signal_name)
		return false
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	var fired: Array = [false]
	var callable := func():
		fired[0] = true
	emitter.connect(signal_name, callable, CONNECT_ONE_SHOT)
	var deadline_ms: float = Time.get_ticks_msec() + timeout_sec * 1000.0
	while Time.get_ticks_msec() < deadline_ms and not fired[0]:
		await tree.process_frame
	if not fired[0]:
		push_warning("[TestHelpers] 信号超时(%.2fs): %s" % [timeout_sec, signal_name])
		if emitter.is_connected(signal_name, callable):
			emitter.disconnect(signal_name, callable)
	return fired[0]
