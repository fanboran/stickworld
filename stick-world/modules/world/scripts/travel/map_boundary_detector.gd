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
## 请求打开大世界地图。full_map：true = 边界自动触发（直接开 L1 大图，原语义）；
## false = 玩家按 Tab（走三态循环，由 SystemSetup 分发）
signal open_world_map_requested(full_map: bool)

var _map: Node2D = null
var _game_root: Node = null
var _push_timer: float = 0.0
var _is_at_boundary: bool = false


func _ready() -> void:
	pass


## 装配注入（SystemSetup 调用）：替代遍历根节点反查 game_root（2026-08 收敛）
func setup(game_root: Node) -> void:
	_game_root = game_root


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
				open_world_map_requested.emit(true)
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
				open_world_map_requested.emit(true)
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
		open_world_map_requested.emit(false)
		get_viewport().set_input_as_handled()
