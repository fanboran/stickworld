extends Control
## 主控单位指示器 -- 当前附身实体脚下椭圆（游玩 UI，非调试）。
##
## 始终显示（不依赖 F3）。
## 注意：entity.global_position 是腰部位置，Collider.global_position 才是脚底。
## 椭圆画在碰撞箱位置（脚底），水平比碰撞箱宽一圈，垂直压扁。
##
## 依赖由 SystemSetup 装配时 setup() 注入，不自行查找。

## 白色四角线框（创始人 2026-09-14：黄椭圆改脚下的白色四角框）
const BRACKET_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const BRACKET_WIDTH: float = 2.0
## 比碰撞箱水平外扩的像素
const EXPAND_X: float = 6.0
## 框的半高（碰撞箱位置上下各伸一半）
const BRACKET_HALF_H: float = 16.0
## 角臂长（四角 L 形短线长度）
const BRACKET_ARM: float = 9.0

var _camera_rig: Node = null
var _game_root: Node = null
## 上帧是否有附身实体（用于"消失时补一次清屏"的零重绘判定）
var _last_had_player: bool = false


func setup(camera_rig: Node, game_root: Node) -> void:
	_camera_rig = camera_rig
	_game_root = game_root


func _ready() -> void:
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	# 无附身实体时零重绘；有附身时椭圆逐帧跟随移动，逐帧重绘是必要的；
	# 实体消失的那帧补一次重绘清屏
	var has_player: bool = _get_possessed_entity() != null
	if has_player or _last_had_player:
		queue_redraw()
	_last_had_player = has_player


func _draw() -> void:
	var camera: Camera2D = _camera_rig as Camera2D
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
	# 框半径：水平比碰撞箱宽一圈
	var rx: float = (col_w * 0.5 + EXPAND_X)
	# 手动计算世界坐标 -> 屏幕坐标
	var cam_pos: Vector2 = camera.global_position
	var zoom: float = camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0
	var vp_size: Vector2 = get_viewport_rect().size
	var screen_pos: Vector2 = (world_pos - cam_pos) * zoom + vp_size * 0.5
	rx *= zoom
	var ry: float = BRACKET_HALF_H
	# 白色四角线框：四个角的 L 形短线（不是整框，压低视觉权重）
	for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var corner: Vector2 = screen_pos + Vector2(c.x * rx, c.y * ry)
		draw_line(corner, corner - Vector2(c.x * BRACKET_ARM, 0), BRACKET_COLOR, BRACKET_WIDTH, true)
		draw_line(corner, corner - Vector2(0, c.y * BRACKET_ARM), BRACKET_COLOR, BRACKET_WIDTH, true)


func _get_possessed_entity() -> Node2D:
	if _game_root == null or not _game_root.has_method("get_current_map"):
		return null
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		return null
	if map.has_method("get_possessed_entity"):
		return map.get_possessed_entity()
	return null
