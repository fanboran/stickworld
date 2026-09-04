class_name MapTransitionOverlay
extends CanvasLayer
## 地图切换转场遮罩（Demo P3）—— travel_started 渐黑 → travel_completed 渐明。
##
## 零侵入设计：只监听 EventBus 的旅行信号，不改 SceneLoader 的同步加载流程。
## layer = 1.5（在 UIRoot 之上）：切换瞬间整屏压暗，读图感更"成品"。

var _rect: ColorRect = null


func _ready() -> void:
	layer = 1.5
	_rect = ColorRect.new()
	_rect.name = "TransitionRect"
	_rect.color = Color(0.05, 0.03, 0.02, 0.0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	if EventBus != null:
		if EventBus.has_signal("travel_started"):
			EventBus.travel_started.connect(_on_travel_started)
		if EventBus.has_signal("travel_completed"):
			EventBus.travel_completed.connect(_on_travel_completed)


func _on_travel_started(_from_id: String, _to_id: String, _mode: int) -> void:
	if _rect == null:
		return
	var tw := _rect.create_tween()
	tw.tween_property(_rect, "color:a", 1.0, 0.15)


func _on_travel_completed(_to_id: String) -> void:
	if _rect == null:
		return
	var tw := _rect.create_tween()
	tw.tween_interval(0.08)
	tw.tween_property(_rect, "color:a", 0.0, 0.45).set_ease(Tween.EASE_OUT)
