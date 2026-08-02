class_name CoverSystem
extends RefCounted
## 掩体查询系统 -- 扫描地图上的 CoverMarker，提供掩体位置查询。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2（cover_system）、§4.3（CoverMarker）。
## CoverMarker 是地图场景中的 Node2D 节点，加入 group "cover_marker"。
## 建筑的 CoverMarker 子节点（§4.3）也会被扫描到（只要加入 group）。
##
## P0：掩体是简单的位置点，无方向性。单位在掩体半径内视为"受掩护"。
## 掩体效果：在掩体中的单位受攻击时命中率降低（由 behavior_attack 检查）。

# ─────────────────────────────── 常量 ────────────────────────────────
## CoverMarker 节点所在的 group 名
const COVER_GROUP := "cover_marker"
## 在此半径内视为"在掩体中"（像素）
const COVER_RADIUS: float = 40.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所有掩体位置（世界坐标）
var _cover_points: Array[Vector2] = []


## 初始化：扫描地图上所有 CoverMarker 节点。
func setup(map: Node2D) -> void:
	_cover_points.clear()
	if map == null:
		return
	# 从整棵场景树扫描 group（map 已在树内）
	for n in map.get_tree().get_nodes_in_group(COVER_GROUP):
		if n is Node2D and (n as Node2D).is_inside_tree():
			_cover_points.append((n as Node2D).global_position)


## 获取所有掩体位置（供调试/测试）
func get_cover_points() -> Array[Vector2]:
	return _cover_points


## 是否存在掩体
func has_covers() -> bool:
	return not _cover_points.is_empty()


## 找最佳掩体位置（优先选离自己近、离敌人远的）。
## 若无掩体，返回 pos 本身。
func find_best_cover(pos: Vector2, enemy_pos: Vector2) -> Vector2:
	if _cover_points.is_empty():
		return pos
	var best: Vector2 = pos
	var best_score: float = -INF
	for cp in _cover_points:
		var d_to_self: float = pos.distance_to(cp)
		var d_to_enemy: float = enemy_pos.distance_to(cp)
		# 分数 = 离敌人远 - 离自己近×0.5（偏好近且远离敌人的掩体）
		var score: float = d_to_enemy - d_to_self * 0.5
		if score > best_score:
			best_score = score
			best = cp
	return best


## 找最近的掩体位置。
func find_nearest_cover(pos: Vector2) -> Vector2:
	if _cover_points.is_empty():
		return pos
	var best: Vector2 = pos
	var best_dist: float = INF
	for cp in _cover_points:
		var d: float = pos.distance_to(cp)
		if d < best_dist:
			best_dist = d
			best = cp
	return best


## 某位置是否在掩体范围内。
func is_in_cover(pos: Vector2) -> bool:
	for cp in _cover_points:
		if pos.distance_to(cp) <= COVER_RADIUS:
			return true
	return false
