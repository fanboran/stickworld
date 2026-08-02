class_name Hitbox
extends Area2D
## 受击判定区域 -- 标记实体为可受击目标，提供附近敌我查询。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1（Hitbox）。
## P0 阶段：Area2D + RectangleShape2D，用于"谁在我攻击范围内"的查询。
## 命中判定本身由 WeaponMount 按距离 + 概率完成，不依赖物理碰撞。
##
## 碰撞层约定（bit）：
##   bit 0 (1)  = 地形/障碍
##   bit 1 (2)  = 角色本体（StickmanEntity.collision_layer）
##   bit 2 (4)  = Hitbox 层（本节点）
##   bit 3 (8)  = 武器/攻击检测层
##
## 默认 Hitbox:  collision_layer=4, collision_mask=0（不主动检测，被武器层查询）

# ─────────────────────────────── 运行时 ────────────────────────────────

func _ready() -> void:
	# Hitbox 默认不主动监测碰撞，仅作为被查询目标
	monitoring = false
	monitorable = true


## 获取拥有此 Hitbox 的 StickmanEntity（父节点）。
func get_owner_entity() -> CharacterBody2D:
	var p: Node = get_parent()
	if p is CharacterBody2D:
		return p as CharacterBody2D
	return null


## 获取此 Hitbox 的世界中心位置。
func get_center() -> Vector2:
	return global_position
