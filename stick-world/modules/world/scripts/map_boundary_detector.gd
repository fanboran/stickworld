class_name MapBoundaryDetector
extends Node
## 地图边界检测器 -- 阶段 F §5.7.5
##
## 替代 ChunkTrigger，检测玩家接近地图边界时显示出行提示。
## Tab 键随时打开大世界地图。
## 左边界 = 北方向，右边界 = 南方向。

## 提示距离（20 格 * 32px = 640px）
const PROMPT_DISTANCE: float = 640.0
## 顶边界持续触发时间（秒）
const PUSH_DURATION: float = 3.0

## 出行提示信号（direction: "north"/"south"）
signal boundary_prompt(direction: String, show: bool)
## 请求打开大世界地图
signal open_world_map_requested()

var _map: Node2D = null
var _game_root: Node = null
var _push_timer: float = 0.0
var _is_at_boundary: bool = false


func _ready() -> void:
	# 延迟获取 GameRoot 引用
	call_deferred("_resolve_game_root")


func _resolve_game_root() -> void:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child := root.get_child(i)
		if child.has_method("get_possession_interface"):
			_game_root = child
			break


func set_map(map: Node2D) -> void:
	_map = map


func _physics_process(delta: float) -> void:
	if _map == null or _game_root == null:
		return
	# 获取当前附身实体
	var pi: Node = _game_root.get_possession_interface() if _game_root.has_method("get_possession_interface") else null
	if pi == null or not pi.has_method("get_possessed_entity"):
		return
	var player: Node2D = pi.get_possessed_entity()
	if player == null or not is_instance_valid(player):
		return
	var px: float = player.global_position.x
	var map_left: float = _map.map_left if "map_left" in _map else 0.0
	var map_right: float = _map.map_right if "map_right" in _map else 0.0
	# 检测近边界
	var near_left: bool = (px - map_left) < PROMPT_DISTANCE
	var near_right: bool = (map_right - px) < PROMPT_DISTANCE
	if near_left:
		if not _is_at_boundary:
			_is_at_boundary = true
			boundary_prompt.emit("north", true)
		# 顶边界计时
		if (px - map_left) < 32.0:
			_push_timer += delta
			if _push_timer >= PUSH_DURATION:
				open_world_map_requested.emit()
				_push_timer = 0.0
		else:
			_push_timer = 0.0
	elif near_right:
		if not _is_at_boundary:
			_is_at_boundary = true
			boundary_prompt.emit("south", true)
		if (map_right - px) < 32.0:
			_push_timer += delta
			if _push_timer >= PUSH_DURATION:
				open_world_map_requested.emit()
				_push_timer = 0.0
		else:
			_push_timer = 0.0
	else:
		if _is_at_boundary:
			_is_at_boundary = false
			boundary_prompt.emit("", false)
		_push_timer = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		open_world_map_requested.emit()
		get_viewport().set_input_as_handled()
