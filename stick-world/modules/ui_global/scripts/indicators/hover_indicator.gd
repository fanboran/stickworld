extends Control
## 鼠标悬停指示器 -- 4 角直角呼吸方框（游玩 UI，非调试）。
##
## 鼠标悬停在 NPC/玩家上时显示 4 角方框，方框大小匹配 Range 节点范围。
## 轻微向外呼吸放大（基准大小即最小范围，不向内收缩）。
##
## 依赖由 SystemSetup 装配时 setup() 注入，不自行查找。

const FRAME_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)
const BREATH_AMP: float = 3.0
const BREATH_SPEED: float = 3.0
const CORNER_LEN: float = 10.0
const CORNER_WIDTH: float = 2.0

var _hovered_entity: Node2D = null
var _hovered_range: CollisionShape2D = null
## 悬停扫描节流：全实体命中扫描 10Hz 足够（悬停框呼吸仍逐帧重绘）
var _scan_acc: float = 0.0
var _breath_time: float = 0.0

var _camera_rig: Node = null
var _game_root: Node = null


func setup(camera_rig: Node, game_root: Node) -> void:
	_camera_rig = camera_rig
	_game_root = game_root


func _ready() -> void:
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_breath_time += delta
	size = get_viewport_rect().size
	# 模态/暂停时（时间冻结）不显示悬停反馈，避免反馈漏过遮罩层；
	# 仅在「原悬停框还在屏上」时补一次清屏重绘，暂停期不再每帧重绘
	if TimeManager and TimeManager.is_paused():
		if _hovered_entity != null:
			_hovered_entity = null
			_hovered_range = null
			queue_redraw()
		return
	# 仅悬停中（呼吸动画需逐帧）或目标刚变化（清旧框/画新框）时重绘；
	# 全实体扫描降到 10Hz——无悬停的绝大多数帧零重绘、扫描也按节拍走
	var prev: Node2D = _hovered_entity
	_scan_acc += delta
	if _scan_acc >= 0.1:
		_scan_acc = 0.0
		_update_hovered()
	if _hovered_entity != null or prev != null:
		queue_redraw()


func _draw() -> void:
	if _hovered_entity == null or not is_instance_valid(_hovered_entity):
		return
	if _hovered_range == null or not is_instance_valid(_hovered_range):
		return
	var camera: Camera2D = _camera_rig as Camera2D
	if camera == null:
		return
	var cam_pos: Vector2 = camera.global_position
	var zoom: float = camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0
	var vp_size: Vector2 = get_viewport_rect().size
	# 方框位置和大小基于 Range 节点
	var range_pos: Vector2 = _hovered_range.global_position
	var screen_pos: Vector2 = (range_pos - cam_pos) * zoom + vp_size * 0.5
	var rs: RectangleShape2D = _hovered_range.shape as RectangleShape2D
	if rs == null:
		return
	# 呼吸只往外扩：将 sin 映射到 [0,1]，基准大小即最小范围
	var breath: float = (sin(_breath_time * BREATH_SPEED) * 0.5 + 0.5) * BREATH_AMP
	var hw: float = rs.size.x * 0.5 * zoom + breath
	var hh: float = rs.size.y * 0.5 * zoom + breath
	var cl: float = CORNER_LEN * zoom
	# 4 角直角方框
	_draw_corner(screen_pos + Vector2(-hw, -hh), Vector2(cl, 0), Vector2(0, cl))
	_draw_corner(screen_pos + Vector2(hw, -hh), Vector2(-cl, 0), Vector2(0, cl))
	_draw_corner(screen_pos + Vector2(-hw, hh), Vector2(cl, 0), Vector2(0, -cl))
	_draw_corner(screen_pos + Vector2(hw, hh), Vector2(-cl, 0), Vector2(0, -cl))


func _draw_corner(origin: Vector2, h_dir: Vector2, v_dir: Vector2) -> void:
	draw_polyline(PackedVector2Array([origin, origin + h_dir]), FRAME_COLOR, CORNER_WIDTH, true)
	draw_polyline(PackedVector2Array([origin, origin + v_dir]), FRAME_COLOR, CORNER_WIDTH, true)


func _update_hovered() -> void:
	var camera: Camera2D = _camera_rig as Camera2D
	if camera == null:
		_hovered_entity = null
		_hovered_range = null
		return
	var zoom: float = camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0
	var vp_size: Vector2 = get_viewport_rect().size
	var cam_pos: Vector2 = camera.global_position
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var mouse_world: Vector2 = (mouse_screen - vp_size * 0.5) / zoom + cam_pos
	if _game_root == null or not _game_root.has_method("get_current_map"):
		_hovered_entity = null
		_hovered_range = null
		return
	var map: Node2D = _game_root.get_current_map()
	if map == null or not map.has_method("get_entities"):
		_hovered_entity = null
		_hovered_range = null
		return
	var closest: Node2D = null
	var closest_range: CollisionShape2D = null
	var closest_dist: float = 999999.0
	for entity in map.get_entities():
		if not entity is CharacterBody2D:
			continue
		var e: CharacterBody2D = entity as CharacterBody2D
		# 用 Range 节点检测悬停（比 Collider 大，更容易触发）
		var rng: CollisionShape2D = e.get_node_or_null("Range") as CollisionShape2D
		if rng == null or not (rng.shape is RectangleShape2D):
			continue
		var rs: RectangleShape2D = rng.shape as RectangleShape2D
		var diff: Vector2 = mouse_world - rng.global_position
		if absf(diff.x) <= rs.size.x * 0.5 and absf(diff.y) <= rs.size.y * 0.5:
			var d: float = diff.length()
			if d < closest_dist:
				closest_dist = d
				closest = e
				closest_range = rng
	_hovered_entity = closest
	_hovered_range = closest_range
