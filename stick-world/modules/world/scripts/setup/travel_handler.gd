extends Node
## GameRoot 旅行子系统 —— 玩家实体查找、室内退出检查。
##
## 职责：
## - 订阅 EventBus.interior_exited
## - 玩家实体查找（供 GameRoot.get_player_entity 转发）
## - INDOOR 模式退出检查（玩家离开所有建筑后切回 EXPLORE）
## （2026-09-16 旧 2D 图清退：mega_interior 大建筑传送链随该图删除，
##   室内玩法由建筑管线 v3 内景承担）
##
## 由 GameRoot._ready 挂载为 TravelHandler 子节点并调用 setup(root)。

var _root: GameRoot


func setup(root: GameRoot) -> void:
	_root = root
	if not EventBus:
		return
	if EventBus.has_signal("interior_exited"):
		EventBus.interior_exited.connect(_on_interior_exited)


# ─────────────────────────────── 玩家实体查找 ────────────────────────────────

## 查找当前玩家实体（供 GameRoot.get_player_entity 转发）
func find_player_entity() -> Node2D:
	# 装配早期（system_setup 期间 HUD 面板 setup）_root 可能尚未注入，返回空而非报错
	if _root == null:
		return null
	var map: Node2D = _root.get_current_map()
	if map == null:
		return null
	for e in map.get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


# ─────────────────────────────── 室内退出检查 ────────────────────────────────

## 某个建筑的 InteractionZone 离开 -> 检查是否所有建筑都不含玩家
func _on_interior_exited(_building_id: int) -> void:
	_check_indoor_exit()


## 遍历当前地图所有 Building，无玩家在内则退出 INDOOR 模式
func _check_indoor_exit() -> void:
	if _root.input_dispatcher == null or not _root.input_dispatcher.has_method("get_mode"):
		return
	if _root.input_dispatcher.get_mode() != PlayerControlAPI.Mode.INDOOR:
		return
	var map: Node2D = _root.get_current_map()
	if map == null:
		return
	if not _has_any_player_in_building(map):
		if _root.input_dispatcher.has_method("exit_to_explore"):
			_root.input_dispatcher.exit_to_explore()


## 递归遍历节点树，检查是否有 Building 内含玩家
func _has_any_player_in_building(node: Node) -> bool:
	if node is Building and node.has_method("is_player_inside_interaction_zone"):
		if node.is_player_inside_interaction_zone():
			return true
	for child in node.get_children():
		if _has_any_player_in_building(child):
			return true
	return false
