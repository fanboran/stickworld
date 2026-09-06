extends Control
class_name TravelDialog
## 旅行方式选择弹窗（P6/E3，总体设计 §5.10 交互流）—— 双击聚落后弹出：
## [走过去 | 快速旅行 | 取消]。
##
## 挂 strategic_map.tscn 的 CanvasLayer 直下（战略图层号 100 高于 UIRoot 的 1，
## 不能走 UIModalStack/SystemOverlay——会被地图盖住），自管理遮罩与显隐；
## ESC 由战略图控制器 handle_escape 分流（弹窗开 → 先关弹窗）。
##
## 按状态（api.get_travel_status 的 code）适配：
##   OK          [走过去] [快速旅行✦] —— 快速旅行亮色可用
##   UNVISITED   [走过去✦] [快速旅行(置灰+原因)] —— 走过去解锁到访（连通性由
##               api.get_walk_status 复核，不连通同样置灰）
##   UNREACHABLE/BLOCKED/NO_SCENE [走过去(置灰+原因)] [快速旅行(置灰+原因)]
##   BATTLE      仅 [取消] + 警示行（战斗中禁止一切旅行）
## 走过去 = api.walk_to 步行道路场景流程（F6）；NO_SCENE / SELF 不开本弹窗
## （控制器前置分流）。

## 玩家确认旅行方式：mode = WorldAPI.TravelMode.WALK / FAST_TRAVEL
signal travel_confirmed(settlement_id: String, mode: int)

## 全屏遮罩（压暗地图 + 消费鼠标防点穿）
var _dim: Control = null
## 居中窗口
var _window: PanelContainer = null
var _title_label: Label = null
var _status_label: Label = null
var _walk_btn: Button = null
var _fast_btn: Button = null
## 当前弹窗目标（空 = 关闭态）
var _settlement_id: String = ""
## 步行状态复核钩子（装配注入：func(settlement_id) -> Dictionary {ok, reason}；
## 弹窗不直接依赖 api 实例——控制器连接时绑定）
var walk_status_fn: Callable = Callable()


func _ready() -> void:
	theme = StickTheme.create()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_widgets()
	visible = false


func _build_widgets() -> void:
	# 根铺满视口（anchor FULL_RECT + 双向 grow，否则内部遮罩塌缩 0 尺寸）
	set_anchors_preset(Control.PRESET_FULL_RECT)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0, 0, 0, 0.45)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP  # 消费点击，防穿透点到地图
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	_window = PanelContainer.new()
	_window.add_theme_stylebox_override("panel", StickStyle.window_panel())
	_window.custom_minimum_size = Vector2(400, 0)
	_dim.add_child(_window)
	# 居中（anchor 归零 + resized 重算，Godot 的 position setter 配 anchor 会失效）
	_window.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_window.resized.connect(func():
		if is_instance_valid(_window) and is_instance_valid(_dim):
			_window.position = (_dim.size - _window.size) * 0.5
	)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_window.add_child(box)
	_title_label = StickKit.label(box, "", StickKit.LabelKind.SECTION)
	_status_label = StickKit.label(box, "", StickKit.LabelKind.BODY)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var btn_row := StickKit.row(box, 8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	_cancel_button(btn_row)
	_walk_btn = StickKit.button(btn_row, "走过去", _on_walk_pressed)
	_fast_btn = StickKit.button(btn_row, "快速旅行", _on_fast_pressed, StickKit.ButtonKind.ACCENT)


func _cancel_button(parent: Control) -> void:
	StickKit.button(parent, "取消", close)


## 打开弹窗（status = api.get_travel_status 结果；只对有 map_id 的聚落调用）
func open_for(settlement_id: String, settlement_name: String, status: Dictionary) -> void:
	_settlement_id = settlement_id
	var code: String = str(status.get("code", ""))
	_title_label.text = "%s · 旅行" % (settlement_name if not settlement_name.is_empty() else settlement_id)
	# 走过去：路网连通即可（不要求已到访）；连通性走 walk_status_fn 复核
	var walk := {"ok": code == "OK", "reason": ""}
	if code != "OK" and walk_status_fn.is_valid():
		walk = walk_status_fn.call(settlement_id)
	_walk_btn.disabled = not bool(walk.get("ok", false))
	_walk_btn.tooltip_text = "" if bool(walk.get("ok", false)) else str(walk.get("reason", "不可步行到达"))
	if code == "OK":
		var hops: int = int(status.get("hops", 0))
		var length_px: float = float(status.get("length_px", 0.0))
		var via := "直达（相邻）" if hops <= 0 else "途经 %d 站" % hops
		_status_label.text = "快速旅行可用 · 路网距离 %.0f · %s\n（调试期免费即时）" % [length_px, via]
		_status_label.modulate = StickTokens.SUCCESS
		_fast_btn.disabled = false
		_fast_btn.tooltip_text = ""
	else:
		var reason: String = str(status.get("reason", "不可用"))
		var hint := "（可先「走过去」亲自到达，解锁此城）" if code == "UNVISITED" else "（步行亦不可达：%s）" % _walk_btn.tooltip_text
		_status_label.text = "快速旅行不可用：%s\n%s" % [reason, hint]
		_status_label.modulate = StickTokens.WARN
		_fast_btn.disabled = true
		_fast_btn.tooltip_text = reason
	visible = true


func close() -> void:
	_settlement_id = ""
	visible = false


func is_open() -> bool:
	return visible and not _settlement_id.is_empty()


## 当前弹窗目标聚落
func get_target_settlement() -> String:
	return _settlement_id


func _on_walk_pressed() -> void:
	var sid := _settlement_id
	close()
	if not sid.is_empty():
		travel_confirmed.emit(sid, WorldAPI.TravelMode.WALK)


func _on_fast_pressed() -> void:
	var sid := _settlement_id
	close()
	if not sid.is_empty():
		travel_confirmed.emit(sid, WorldAPI.TravelMode.FAST_TRAVEL)
