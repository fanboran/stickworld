class_name ChunkTrigger
extends Area2D
## 地图出口触发器 -- 玩家接近地图边缘时触发地图切换。
##
## 详见 docs/技术/架构/场景与战斗架构.md §3.2（Chunk 末端出口触发器）。
## 放置在地图的 ChunkTriggers 节点下，配置 target_map_id 和 entry_side。
## 当玩家（附身实体）进入触发区域时，通过 GameRoot 调用 SceneLoader.travel_to_map。

# WorldAPI 是全局 class_name，无需 preload

## 出口方向（决定触发器放置位置语义）
@export var exit_side: int = WorldAPI.EntrySide.RIGHT
## 目标地图 ID（为空时使用 SceneLoader 的出口配置）
@export var target_map_id: String = ""
## 进入目标地图的方向
@export var target_entry_side: int = WorldAPI.EntrySide.LEFT
## 触发器宽度（像素）
@export var trigger_width: float = 64.0

## 冷却标志（防止同一帧多次触发）
var _triggered: bool = false


func _ready() -> void:
	# 确保 CollisionShape2D 存在
	if get_child_count() == 0 or not get_child(0) is CollisionShape2D:
		push_warning("[ChunkTrigger] 缺少 CollisionShape2D: %s" % name)
	# 监听 body 进入
	body_entered.connect(_on_body_entered)
	# 设定 collision layer/mask（layer=0 不参与碰撞，mask=1 检测 CharacterBody2D）
	monitoring = true
	monitorable = false


## 玩家进入触发区域
func _on_body_entered(body: Node) -> void:
	if _triggered:
		return
	# 只响应被附身的实体（玩家控制的角色）
	if not body is CharacterBody2D:
		return
	if not body.has_method("is_possessed") or not body.is_possessed():
		return
	_triggered = true
	# 通过 GameRoot 发起地图切换
	var game_root := _find_game_root()
	if game_root == null:
		push_warning("[ChunkTrigger] 未找到 GameRoot，无法切换地图")
		return
	if target_map_id.is_empty():
		# 使用 SceneLoader 的出口配置
		var sl: Node = game_root.scene_loader
		if sl == null:
			return
		var exit_info: Dictionary = sl.get_map_exit(sl.current_map_id, exit_side)
		if exit_info.is_empty():
			push_warning("[ChunkTrigger] 无出口配置: map=%s side=%d" % [sl.current_map_id, exit_side])
			return
		game_root.request_map_travel(exit_info["target"], exit_info["entry"])
	else:
		game_root.request_map_travel(target_map_id, target_entry_side)


## 向上查找 GameRoot 节点
func _find_game_root() -> Node:
	var p: Node = get_parent()
	while p != null:
		if p is GameRoot:
			return p
		p = p.get_parent()
	return null


## 重置冷却（新地图加载后调用）
func reset() -> void:
	_triggered = false
