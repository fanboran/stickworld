class_name StickProf
## 帧成本微计时器（STICK_PROF=1 启用）：聚合级命名累计（usec），report 打印并清窗。
##
## 埋点纪律：只包大段（整函数 / 整循环），绝不逐行逐调用包——计时器自身
## 开销（2 次静态调用 ~1μs）才不会淹没被测对象。消费方 = arena_renderperf
## （--renderperf 跑批报告周期性调 report()，窗口自清）。
## 未启用时 t0() 恒返 0、t1() 直接跳过：全链路零字典访问，开销可忽略。

static var _enabled := -1   # -1=未初始化（惰性读环境变量一次）
static var _acc := {}       # name -> 累计 usec
static var _hits := {}      # name -> 包段次数


static func _on() -> bool:
	if _enabled < 0:
		_enabled = 1 if OS.get_environment("STICK_PROF") == "1" else 0
	return _enabled == 1


## 包段起点（未启用返回 0，t1 据此跳过）
static func t0() -> int:
	if _on():
		return Time.get_ticks_usec()
	return 0


## 包段终点：累计进 name
static func t1(name: String, t0_usec: int) -> void:
	if t0_usec > 0:
		_acc[name] = float(_acc.get(name, 0.0)) + float(Time.get_ticks_usec() - t0_usec)
		_hits[name] = int(_hits.get(name, 0)) + 1


## 打印本窗口（降序）并清零——首窗含启动/烘焙噪声，读数以后续窗口为准
static func report(prefix: String) -> void:
	if not _on() or _acc.is_empty():
		return
	var names := _acc.keys()
	names.sort_custom(func(a, b): return float(_acc[a]) > float(_acc[b]))
	for n in names:
		print("[StickProf] %s %-14s %7.1f ms/窗  %6d 段" % [
				prefix, n, float(_acc[n]) / 1000.0, _hits[n]])
	_acc.clear()
	_hits.clear()
