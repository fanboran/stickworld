extends Control
class_name MapHUD
## 战略图底部 HUD：缩放指示条（轨道+滑块+数值）+ 显示模式切换按钮（L1 <-> 城市）
## 通用组件：L3 / L2 场景共用（Content 下有 XxxMapRenderer 带 toggle_display_mode 即兼容）。
## 由各控制器控制显隐；文字/按钮全部画在控件（44px 高）内，避免被裁。

var _camera: Node = null
var _renderer: Node = null

const MIN_ZOOM := 0.02
const MAX_ZOOM := 3.0
const TRACK_COLOR := Color(0.18, 0.18, 0.18, 0.8)
const FILL_COLOR := Color(0.42, 0.42, 0.45, 0.9)
const THUMB_COLOR := Color(1.0, 0.9, 0.3, 0.98)
const TEXT_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const TRACK_H := 6.0
const THUMB_W := 14.0
const THUMB_H := 18.0

## 模式按钮（右下角）
const BTN_W := 120.0
const BTN_H := 26.0
const BTN_COLOR := Color(0.25, 0.28, 0.33, 0.92)
const BTN_HOVER := Color(0.34, 0.38, 0.45, 0.95)
const BTN_TEXT := Color(1.0, 1.0, 1.0, 0.98)

var _btn_hovered: bool = false


func _ready() -> void:
	var layer := get_parent()
	if layer != null:
		var content := layer.get_node_or_null("Content")
		if content != null:
			_camera = content.get_node_or_null("MapCamera")
			# 查找带 toggle_display_mode 的渲染器（L3MapRenderer / L2MapRenderer）
			for ch in content.get_children():
				if ch.has_method("toggle_display_mode"):
					_renderer = ch
					break
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -46.0
	offset_bottom = 0.0
	# 按钮接收点击，其余区域事件继续向下传（不挡地图点击下钻）
	mouse_filter = Control.MOUSE_FILTER_PASS


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var local := (event as InputEventMouseMotion).position if event is InputEventMouseMotion \
			else (event as InputEventMouseButton).position
		var prev := _btn_hovered
		_btn_hovered = _btn_rect().has_point(local)
		if _btn_hovered != prev:
			queue_redraw()
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT and _btn_hovered:
			if _renderer != null and _renderer.has_method("toggle_display_mode"):
				_renderer.toggle_display_mode()
				queue_redraw()
			accept_event()


func _btn_rect() -> Rect2:
	return Rect2(size.x - BTN_W - 14.0, 10.0, BTN_W, BTN_H)


func _draw() -> void:
	var track_w := minf(size.x * 0.42, 420.0)
	var x0 := (size.x - track_w) * 0.5
	var y := 24.0   # 轨道中心（控件内）
	# 轨道 + 已缩放范围
	draw_rect(Rect2(x0, y - TRACK_H * 0.5, track_w, TRACK_H), TRACK_COLOR)
	var zoom: float = _camera.get_zoom() if _camera != null and _camera.has_method("get_zoom") else 1.0
	var t := clampf((zoom - MIN_ZOOM) / (MAX_ZOOM - MIN_ZOOM), 0.0, 1.0)
	draw_rect(Rect2(x0, y - TRACK_H * 0.5, track_w * t, TRACK_H), FILL_COLOR)
	draw_rect(Rect2(x0 + t * (track_w - THUMB_W), y - THUMB_H * 0.5, THUMB_W, THUMB_H), THUMB_COLOR)
	# 数值文字（放轨道上方，控件内）
	draw_string(ThemeDB.fallback_font, Vector2(x0, y - 8.0), "缩放 %.2fx" % zoom,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT_COLOR)
	draw_string(ThemeDB.fallback_font, Vector2(x0 + track_w - 26.0, y - 8.0), "%.1fx" % MAX_ZOOM,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT_COLOR)
	# 模式切换按钮
	var r := _btn_rect()
	draw_rect(r, BTN_HOVER if _btn_hovered else BTN_COLOR)
	var mode_text: String = "模式:L1"
	if _renderer != null and _renderer.has_method("get_mode_name"):
		mode_text = "模式:" + _renderer.get_mode_name()
	draw_string(ThemeDB.fallback_font, r.position + Vector2(12.0, 19.0), mode_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, BTN_TEXT)