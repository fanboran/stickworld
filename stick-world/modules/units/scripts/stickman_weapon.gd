class_name StickmanWeapon
extends RefCounted
## 火柴人武器挂载系统
## GripPoint 对齐，支持双持（右手 + 左手）

const Skeleton := preload("res://modules/units/scripts/stickman_skeleton.gd")

const DEFAULT_WEAPON_PATH := "res://modules/units/scenes/components/weapon_sword_placeholder.tscn"


# ============================================================
#  武器挂载
# ============================================================

## 挂载武器到手部骨骼
## scene: 武器 PackedScene（null 时右手自动加载占位剑）
## bone_id: 挂载骨骼 ID（WEAPON_ATTACH_R 或 WEAPON_ATTACH_L）
## bones: 骨骼字典
## 返回: 武器实例（Node2D），或 null
static func attach(scene: PackedScene, bone_id: int, bones: Dictionary) -> Node2D:
	if bone_id == Skeleton.WEAPON_ATTACH_R and scene == null:
		if ResourceLoader.exists(DEFAULT_WEAPON_PATH):
			scene = load(DEFAULT_WEAPON_PATH)
	if scene == null:
		return null

	var hand := bones.get(bone_id, null) as Node2D
	if hand == null:
		return null

	# 确保 HandMarker 存在
	var marker := hand.get_node_or_null("HandMarker") as Marker2D
	if marker == null:
		marker = Marker2D.new()
		marker.name = "HandMarker"
		hand.add_child(marker)

	# 实例化武器
	var instance := scene.instantiate() as Node2D
	var slot_name := "weapon_r" if bone_id == Skeleton.WEAPON_ATTACH_R else "weapon_l"
	instance.name = slot_name
	hand.add_child(instance)

	# GripPoint 对齐
	var grip := instance.get_node_or_null("GripPoint") as Marker2D
	if grip:
		instance.position = marker.position - grip.position
		instance.rotation = marker.rotation - grip.rotation

	# 渲染层级：武器在身体之上
	instance.z_index = 1
	instance.z_as_relative = false
	return instance


## 卸载武器
static func detach(weapon: Node2D) -> void:
	if is_instance_valid(weapon):
		weapon.queue_free()