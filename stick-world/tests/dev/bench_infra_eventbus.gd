extends Node
## 基础设施基准②：EventBus 吞吐（dev 层，headless）。
##
## 50 个订阅者 × 1 万次 emit（挑真实高频信号：ui_notification / selection_changed /
## heal_cast——三者生产端均为高频事件，无暂停类副作用）。
## 分项：零订阅者 emit / 50 订阅者 emit / 50 订阅者+轻量消费体（模拟 UI 刷新）。
## 顺带验证订阅方调用链是否有 O(n) 重活：轻量消费体按真实订阅方
## （resource_bar._on_resource_changed / demo_quest）的行为建模。
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_eventbus.tscn

const N_SUBSCRIBERS := 50
const N_EMITS := 10000

## 轻量消费体：模拟真实 UI 订阅方（一次字符串格式化 + 小字典写）
class _UiLikeConsumer:
	var _counter: int = 0
	var _last_title: String = ""

	func on_notify(title: String, body: String, level: String) -> void:
		_last_title = "%s/%s/%s" % [title, body, level]
		_counter += 1

	func on_selection(unit_ids: Array) -> void:
		_counter += unit_ids.size()


func _ready() -> void:
	_bench_emit_no_subscriber()
	_bench_emit_with_subscribers()
	print("BENCH eventbus DONE")
	get_tree().quit(0)


## ① 零订阅者（单播成本基线；真实项目里大量信号处于此态）
func _bench_emit_no_subscriber() -> void:
	# 热身（首次触发信号元数据初始化）
	EventBus.ui_notification.emit("warmup", "b", "info")
	var t0 := Time.get_ticks_usec()
	for i in N_EMITS:
		EventBus.ui_notification.emit("通知%d" % i, "正文", "info")
	var t := Time.get_ticks_usec() - t0
	print("BENCH eventbus 零订阅者 emit x%d: %d us（单次 %.2f us）" % [N_EMITS, t, float(t) / N_EMITS])


## ② 50 订阅者 × 1 万次
func _bench_emit_with_subscribers() -> void:
	var consumers: Array = []
	for i in N_SUBSCRIBERS:
		var c := _UiLikeConsumer.new()
		consumers.append(c)
		EventBus.ui_notification.connect(c.on_notify)
		EventBus.selection_changed.connect(c.on_selection)
	EventBus.ui_notification.emit("warmup2", "b", "info")
	var t0 := Time.get_ticks_usec()
	for i in N_EMITS:
		EventBus.ui_notification.emit("通知%d" % i, "正文", "info")
	var t_notify := Time.get_ticks_usec() - t0
	var ids: Array = [1, 2, 3, 4, 5]
	t0 = Time.get_ticks_usec()
	for i in N_EMITS:
		EventBus.selection_changed.emit(ids)
	var t_sel := Time.get_ticks_usec() - t0
	for c in consumers:
		EventBus.ui_notification.disconnect(c.on_notify)
		EventBus.selection_changed.disconnect(c.on_selection)
	print("BENCH eventbus 50订阅者 ui_notification x%d: %d us（单次 %.2f us）" % [N_EMITS, t_notify, float(t_notify) / N_EMITS])
	print("BENCH eventbus 50订阅者 selection_changed x%d: %d us（单次 %.2f us）" % [N_EMITS, t_sel, float(t_sel) / N_EMITS])
