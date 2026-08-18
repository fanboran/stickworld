extends Control
class_name L3ZoomIndicator
## L3 大世界缩放指示条 —— 底部显示当前缩放档位（滑块 + 数值）
## 由 L3MapController 控制显隐（open 显示 / close 隐藏）

var _camera: Node = null

const MIN_ZOOM := 0.02
const MAX_ZOOM := 3.0
const TRACK_COLOR := Color(0.18, 0.18, 0.18, 0.8)
const FILL_COLOR := Color(0.42, 0.42, 0.45, 0.9)
const THUMB_COLOR := Color(1.0, 0.9, 0.3, 0.98)
const TEXT_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const TRACK_H := 6.0
const THUMB_W := 14.0
const THUMB_H := 18.0


func _ready() -> void:
	# CanvasLayer(StrategicMapL3) -> Content -> MapCamera
	var layer := get_parent()
	if layer != null:
		var content := layer.get_node_or_null("Content")
		if content != null:
			_camera = content.get_node_or_null("MapCamera")
	# 底部整宽 44px 条
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -44.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	if _camera == null or not _camera.has_method("get_zoom"):
		return
	var zoom: float = _camera.get_zoom()
	var track_w := minf(size.x * 0.5, 420.0)
	var x0 := (size.x - track_w) * 0.5
	var y := offset_top + 24.0
	# 轨道
	draw_rect(Rect2(x0, y - TRACK_H * 0.5, track_w, TRACK_H), TRACK_COLOR)
	# 已缩放范围（min -> 当前）
	var t := clampf((zoom - MIN_ZOOM) / (MAX_ZOOM - MIN_ZOOM), 0.0, 1.0)
	draw_rect(Rect2(x0, y - TRACK_H * 0.5, track_w * t, TRACK_H), FILL_COLOR)
	# 滑块（当前缩放档位）
	var tw := maxf(THUMB_W, THUMB_W)
	draw_rect(Rect2(x0 + t * (track_w - tw), y - THUMB_H * 0.5, tw, THUMB_H), THUMB_COLOR)
	# 数值
	draw_string(ThemeDB.fallback_font, Vector2(x0, y + 30.0), "缩放 %.2fx" % zoom,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TEXT_COLOR)
	draw_string(ThemeDB.fallback_font, Vector2(x0 + track_w - 34.0, y + 30.0), "%.1fx" % MAX_ZOOM,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_COLOR)