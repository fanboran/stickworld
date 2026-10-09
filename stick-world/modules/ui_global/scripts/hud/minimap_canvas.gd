class_name MinimapCanvas
extends Control
## 本地地图放大版的绘制区（MinimapWindow 的内容主体）——单独成文件而非内类，
## 避免与 MinimapWindow 互相引用的类内环。
##
## 左 = 地图本体（与顶部小地图同一投影核 MinimapPainter）；右 = 类型图例。
## 交互：左键点击地图 → 相机跳转到该处（与小地图同 RTS 语义）。

var window: MinimapWindow = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _draw() -> void:
	if window == null:
		return
	var map_rect := map_rect()
	var map: Node2D = window.current_map()
	var snap: Dictionary = MinimapPainter.build_snapshot(map, window.map_info())
	var points: Array = MinimapPainter.collect_points(map)
	MinimapPainter.draw(self, map_rect, snap, points, {
		"color_mode": window.color_mode(),
		"viewport_world": window.viewport_world(),
	})
	# 图例只在"类型着色的平面图"下画：照片底图是实际颜色、色块与图例对不上
	if window.is_type_mode() and not window.has_photo_base():
		MinimapPainter.draw_legend(self,
				Vector2(map_rect.end.x + 12.0, map_rect.position.y + 4.0),
				get_theme_default_font(), 12)


## 地图绘制区（左对齐；宽 × 画布总高由 MinimapWindow 按等比例尺算出）
func map_rect() -> Rect2:
	if window == null:
		return Rect2(Vector2.ZERO, Vector2(900.0, 300.0))
	return Rect2(Vector2.ZERO, Vector2(window.map_px_w(), window.total_h()))


func _gui_input(event: InputEvent) -> void:
	if window == null:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var r := map_rect()
		if r.has_point(event.position):
			window.jump_camera_at(event.position.x, r)
