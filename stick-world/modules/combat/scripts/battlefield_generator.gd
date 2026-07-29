class_name BattlefieldGenerator
extends RefCounted
## 遭遇战战场生成器 -- 阶段 F §5.7.6
##
## 生成空旷战场配置：
##   - ground_ratio = 0.6（大垂直跨度，方便排兵布阵）
##   - 两端临时掩体（CoverMarker）
##   - 我方 spawn 在行军方向侧
##   - 敌方 spawn 在对侧
##   - 撤退点在我方 spawn 侧

## 行军方向枚举
enum MarchDirection {
	NORTH_TO_SOUTH,  ## 从北往南走，我方在左侧（北面）
	SOUTH_TO_NORTH,  ## 从南往北走，我方在右侧（南面）
}

## 生成遭遇战战场配置。
## 返回 {attacker_spawn, defender_spawn, retreat_point, cover_positions}
static func generate_battlefield(map: Node2D, march_direction: int) -> Dictionary:
	if map == null:
		return {}
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 4096.0
	var ground_y: float = map.ground_y if "ground_y" in map else 432.0
	var ground_bottom: float = map.ground_bottom if "ground_bottom" in map else 1080.0
	var mid_x: float = (map_left + map_right) * 0.5
	var mid_y: float = (ground_y + ground_bottom) * 0.5
	# spawn 位置：我方在行军方向侧，敌方在对侧
	var attacker_x: float
	var defender_x: float
	match march_direction:
		MarchDirection.NORTH_TO_SOUTH:
			# 从北往南走 -> 我方在左侧（北面=左）
			attacker_x = map_left + (map_right - map_left) * 0.15
			defender_x = map_right - (map_right - map_left) * 0.15
		MarchDirection.SOUTH_TO_NORTH:
			# 从南往北走 -> 我方在右侧（南面=右）
			attacker_x = map_right - (map_right - map_left) * 0.15
			defender_x = map_left + (map_right - map_left) * 0.15
		_:
			attacker_x = map_right - (map_right - map_left) * 0.15
			defender_x = map_left + (map_right - map_left) * 0.15
	# 撤退点在我方 spawn 侧
	var retreat_x: float = attacker_x
	# 掩体位置（两端各 2 个）
	var cover_positions: Array = [
		Vector2(attacker_x, mid_y - 50),
		Vector2(attacker_x + 100, mid_y + 50),
		Vector2(defender_x, mid_y - 50),
		Vector2(defender_x - 100, mid_y + 50),
	]
	return {
		"attacker_spawn": Vector2(attacker_x, mid_y),
		"defender_spawn": Vector2(defender_x, mid_y),
		"retreat_point": Vector2(retreat_x, mid_y),
		"cover_positions": cover_positions,
	}
