extends Control
## 主控单位指示器 -- 当前附身实体脚下椭圆（游玩 UI，非调试）。
##
## 始终显示（不依赖 F3）。
## 注意：entity.global_position 是腰部位置，Collider.global_position 才是脚底。
## 椭圆画在碰撞箱位置（脚底），水平比碰撞箱宽一圈，垂直压扁。

const ELLIPSE_COLOR: Color = Color(1.0, 0.95, 0.3, 0.85)
const ELLIPSE_WIDTH: float = 1.0
## 比碰撞箱水平外扩的像素
const EXPAND_X: float = 6.0
## 垂直压扁高度（世界像素）
const FLAT_Y: float = 12.0


func _ready() -> void:
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	var camera: Camera2D = _get_camera()
	if camera == null:
		return
	var player: Node2D = _get_possessed_entity()
	if player == null or not is_instance_valid(player):
		return
	# 获取碰撞箱位置和大小
	var col: CollisionShape2D = player.get_node_or_null("Collider") as CollisionShape2D
	var world_pos: Vector2 = player.global_position
	var col_w: float = 32.0
	if col != null and col.shape is RectangleShape2D:
		world_pos = col.global_position
		col_w = (col.shape as RectangleShape2D).size.x
	# 椭圆半径：水平比碰撞箱宽一圈，垂直压扁
	var rx: float = (col_w * 0.5 + EXPAND_X)
	var ry: float = FLAT_Y
	# 手动计算世界坐标 -> 屏幕坐标
	var cam_pos: Vector2 = camera.global_position
	var zoom: float = camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0
	var vp_size: Vector2 = get_viewport_rect().size
	var screen_pos: Vector2 = (world_pos - cam_pos) * zoom + vp_size * 0.5
	rx *= zoom
	ry *= zoom
	if rx < 6.0:
		rx = 6.0
	if ry < 4.0:
		ry = 4.0
	# 用 draw_polyline 绘制抗锯齿椭圆
	var point_count: int = 48
	var points: PackedVector2Array = PackedVector2Array()
	for i in range(point_count):
		var angle: float = TAU * float(i) / float(point_count)
		points.append(Vector2(screen_pos.x + cos(angle) * rx, screen_pos.y + sin(angle) * ry))
	points.append(points[0])  # 闭合
	draw_polyline(points, ELLIPSE_COLOR, ELLIPSE_WIDTH, true)


func _get_camera() -> Camera2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		var cam: Node = child.get_node_or_null("CameraRig")
		if cam != null and cam is Camera2D:
			return cam as Camera2D
	return null


func _get_possessed_entity() -> Node2D:
	var map: Node2D = _get_current_map()
	if map == null:
		return null
	var entity_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
	if entity_host == null:
		return null
	for entity in entity_host.get_children():
		if entity is CharacterBody2D and entity.has_method("is_possessed") and entity.is_possessed():
			return entity as Node2D
	return null


func _get_current_map() -> Node2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		if child.has_method("get_current_map"):
			var map: Node2D = child.get_current_map() as Node2D
			if map != null and is_instance_valid(map):
				return map
	return null
