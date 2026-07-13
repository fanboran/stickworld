class_name ExploreHandler
extends Node
## EXPLORE 模式输入处理器。
##
## 详见 docs/技术/架构/场景与战斗架构.md §二.2、§7.5。
## 激活时：找到当前地图的玩家 StickmanEntity（或默认第一个），设置 possessed=true。
## 停用时：设置 possessed=false。
##
## 实际 WASD 输入由 StickmanEntity._physics_process 读取（P0 简化），
## 后续阶段可重构为 handler 显式下发 move_command。

# PlayerControlAPI 是全局 class_name，无需 preload

## 当前附身的实体
var _possessed_entity: Node2D = null
## GameRoot 引用（用于查找当前地图）
var _game_root: Node = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 延迟一帧获取 GameRoot
	call_deferred("_resolve_game_root")


func _resolve_game_root() -> void:
	var p := get_parent()
	# 向上查找 GameRoot（持有 map 查询能力）
	while p != null:
		if p.has_method("get_current_map"):
			_game_root = p
			return
		p = p.get_parent()


# ─────────────────────────────── 模式回调 ────────────────────────────────

func _on_mode_activated(_mode: int) -> void:
	_possess_player_entity()


func _on_mode_deactivated(_mode: int) -> void:
	_release_possession()


# ─────────────────────────────── 附身逻辑 ────────────────────────────────

func _possess_player_entity() -> void:
	var entity := _find_player_entity()
	if entity == null:
		push_warning("[ExploreHandler] 未找到可附身实体")
		return
	if entity.has_method("set_possessed"):
		entity.set_possessed(true)
	_possessed_entity = entity


func _release_possession() -> void:
	if _possessed_entity == null or not is_instance_valid(_possessed_entity):
		_possessed_entity = null
		return
	if _possessed_entity.has_method("set_possessed"):
		_possessed_entity.set_possessed(false)
	_possessed_entity = null


func _find_player_entity() -> Node2D:
	if _game_root == null:
		_resolve_game_root()
	if _game_root == null:
		return null
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		return null
	# 优先找已标记 possessed 的
	if map.has_method("get_possessed_entity"):
		var p: Node2D = map.get_possessed_entity()
		if p != null:
			return p
	# 否则取第一个 StickmanEntity
	if map.has_method("get_entities"):
		for e in map.get_entities():
			if e is CharacterBody2D and e.has_method("set_possessed"):
				return e
	return null


# ─────────────────────────────── 公共 API ────────────────────────────────

func get_possessed_entity() -> Node2D:
	return _possessed_entity
