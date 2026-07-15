@tool
extends Node
## 从 stickman_anims.gd 的动画数据烘焙 .tres 资源文件
##
## 运行方式:
##   godot --headless --path "f:/VSCode/game-2/stick-world" res://tools/baking/bake_anims.tscn

const Skeleton := preload("res://modules/units/scripts/stickman_skeleton.gd")

const OUTPUT_DIR := "res://modules/units/animations/"


func _ready() -> void:
	print("=== 开始烘焙动画 .tres 文件 ===")
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	_bake("idle", _data_idle(), 2.0, Animation.LOOP_LINEAR)
	_bake("walk", _data_walk(), 0.8, Animation.LOOP_LINEAR)
	_bake("attack", _data_attack(), 0.6, Animation.LOOP_NONE)
	_bake("dead", _data_dead(), 1.0, Animation.LOOP_NONE)

	print("=== 烘焙完成 ===")
	get_tree().quit(0)


func _bake(name: String, tracks: Array, length: float, loop_mode: int) -> void:
	var anim := Animation.new()
	anim.loop_mode = loop_mode
	anim.length = length

	for track_data in tracks:
		var bone_id: int = track_data[0]
		var keys: Array = track_data[1]
		if keys.size() < 2:
			continue

		var path := _bone_path(bone_id)
		var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track_idx, path)
		anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)

		var i: int = 0
		while i + 1 < keys.size():
			anim.track_insert_key(track_idx, float(keys[i]), deg_to_rad(float(keys[i + 1])))
			i += 2

	var file_path := OUTPUT_DIR + name + ".tres"
	var err := ResourceSaver.save(anim, file_path)
	if err == OK:
		print("  OK  %s.tres (%d tracks)" % [name, tracks.size()])
	else:
		print("  ERR %s.tres: 保存失败 (err=%d)" % [name, err])


## 从骨骼数据计算 bone 路径（相对于 AnimationPlayer 的 root_node = StickmanRig/Skeleton2D）
static func _bone_path(bone_id: int) -> String:
	var parts: Array[String] = []
	var current: int = bone_id
	while current >= 0:
		parts.push_front(Skeleton.BONE_NAMES.get(current, "bone_%d" % current))
		var data = Skeleton.SKELETON_DATA.get(current, {})
		current = data.get("parent", -1)
	return "/".join(parts) + ":rotation"


# ============================================================
#  动画数据
#  骨骼 ID 映射（腿部位移了一级）：
#  旧3(大腿摆动) -> 16(thigh_outer), 旧4(膝盖弯曲) -> 3(shin_outer)
#  旧11(大腿摆动) -> 17(thigh_inner), 旧12(膝盖弯曲) -> 11(shin_inner)
#  手臂也位移了一级：
#  旧1(大臂摆动) -> 18(upper_arm_outer), 旧14(大臂摆动) -> 19(upper_arm_inner)
#  旧15(小臂弯曲) -> 14(forearm_inner)
#  chest 已移除，旧8(chest) -> 7(upper_torso)
# ============================================================

static func _data_idle() -> Array:
	return [
		[7,  [0.0, 4.0,  1.0, -3.0,  2.0, 0.0]],
		[18, [0.0, 2.0,  1.0, -1.5,  2.0, 0.0]],
		[16, [0.0, 5.0,  1.0, -4.0,  2.0, 0.0]],
		[17, [0.0, -4.0, 1.0, 5.0,   2.0, 0.0]],
		[9,  [0.0, 2.0,  1.0, -1.5,  2.0, 0.0]],
	]


static func _data_walk() -> Array:
	return [
		[9,  [0.0, 35.0,  0.4, -30.0, 0.8, 0.0]],
		[16, [0.0, -25.0, 0.4, 25.0,  0.8, 0.0]],
		[17, [0.0, 25.0,  0.4, -25.0, 0.8, 0.0]],
		[3,  [0.0, -10.0, 0.4, 10.0,  0.8, 0.0]],
		[11, [0.0, 10.0,  0.4, -10.0, 0.8, 0.0]],
		[7,  [0.0, 5.0,   0.4, -5.0,  0.8, 0.0]],
		[18, [0.0, -3.0,  0.4, 3.0,   0.8, 0.0]],
		[19, [0.0, 8.0,   0.4, -8.0,  0.8, 0.0]],
	]


static func _data_attack() -> Array:
	return [
		[19, [0.0, -80.0, 0.15, 100.0, 0.4, 15.0, 0.6, 0.0]],
		[14, [0.0, -40.0, 0.15, 50.0,  0.4, 0.0,  0.6, 0.0]],
		[7,  [0.0, -12.0, 0.15, 15.0,  0.4, 0.0,  0.6, 0.0]],
		[16, [0.0, -10.0, 0.15, 15.0,  0.4, 0.0,  0.6, 0.0]],
	]


static func _data_dead() -> Array:
	return [
		[7,  [0.0, 100.0, 0.5, 95.0,  1.0, 0.0]],
		[16, [0.0, 50.0,  0.5, 55.0,  1.0, 0.0]],
		[17, [0.0, -50.0, 0.5, -55.0, 1.0, 0.0]],
		[9,  [0.0, -15.0, 0.5, -10.0, 1.0, 0.0]],
		[19, [0.0, 30.0,  0.5, 40.0,  1.0, 0.0]],
		[18, [0.0, 40.0,  0.5, 45.0,  1.0, 0.0]],
	]