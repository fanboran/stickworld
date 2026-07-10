@tool
extends Node
## 将代码 K 帧数据导出为 .tres 动画资源文件
##
## 运行: godot --headless --path "f:/VSCode/game-2/stick-world" res://tools/export_anims.tres

const OUTPUT_DIR := "res://modules/units/animations/"

func _ready() -> void:
	var abs_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	print("=== 动画导出到 %s ===" % abs_dir)
	_bake_idle()
	_bake_walk()
	_bake_attack()
	_bake_dead()
	
	print("=== 动画导出完成 ===")
	get_tree().quit(0)


func _save(anim: Animation, aname: String) -> void:
	var path := OUTPUT_DIR + aname + ".tres"
	print("  saving: %s" % path)
	var err := ResourceSaver.save(anim, path)
	if err == OK:
		print("  OK  %s  (length=%.1fs)" % [path, anim.length])
	else:
		printerr("  ERR %s  (err=%d)" % [path, err])


func _bake_idle() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.length = 2.0
	_add_rot(anim, 8,  [0.0, 4.0, 1.0, -3.0, 2.0, 0.0])
	_add_rot(anim, 1,  [0.0, 2.0, 1.0, -1.5, 2.0, 0.0])
	_add_rot(anim, 3,  [0.0, 5.0, 1.0, -4.0, 2.0, 0.0])
	_add_rot(anim, 11, [0.0, -4.0, 1.0, 5.0, 2.0, 0.0])
	_add_rot(anim, 9,  [0.0, 2.0, 1.0, -1.5, 2.0, 0.0])
	_save(anim, "idle")


func _bake_walk() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.length = 0.8
	_add_rot(anim, 9,  [0.0, 35.0, 0.4, -30.0, 0.8, 0.0])
	_add_rot(anim, 3,  [0.0, -25.0, 0.4, 25.0, 0.8, 0.0])
	_add_rot(anim, 11, [0.0, 25.0, 0.4, -25.0, 0.8, 0.0])
	_add_rot(anim, 4,  [0.0, -10.0, 0.4, 10.0, 0.8, 0.0])
	_add_rot(anim, 12, [0.0, 10.0, 0.4, -10.0, 0.8, 0.0])
	_add_rot(anim, 8,  [0.0, 5.0, 0.4, -5.0, 0.8, 0.0])
	_add_rot(anim, 1,  [0.0, -3.0, 0.4, 3.0, 0.8, 0.0])
	_add_rot(anim, 14, [0.0, 8.0, 0.4, -8.0, 0.8, 0.0])
	_save(anim, "walk")


func _bake_attack() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_NONE
	anim.length = 0.6
	_add_rot(anim, 14, [0.0, -80.0, 0.15, 100.0, 0.4, 15.0, 0.6, 0.0])
	_add_rot(anim, 15, [0.0, -40.0, 0.15, 50.0, 0.4, 0.0, 0.6, 0.0])
	_add_rot(anim, 8,  [0.0, -12.0, 0.15, 15.0, 0.4, 0.0, 0.6, 0.0])
	_add_rot(anim, 3,  [0.0, -10.0, 0.15, 15.0, 0.4, 0.0, 0.6, 0.0])
	_save(anim, "attack")


func _bake_dead() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_NONE
	anim.length = 1.0
	_add_rot(anim, 8,  [0.0, 100.0, 0.5, 95.0, 1.0, 0.0])
	_add_rot(anim, 3,  [0.0, 50.0, 0.5, 55.0, 1.0, 0.0])
	_add_rot(anim, 11, [0.0, -50.0, 0.5, -55.0, 1.0, 0.0])
	_add_rot(anim, 9,  [0.0, -15.0, 0.5, -10.0, 1.0, 0.0])
	_add_rot(anim, 14, [0.0, 30.0, 0.5, 40.0, 1.0, 0.0])
	_add_rot(anim, 1,  [0.0, 40.0, 0.5, 45.0, 1.0, 0.0])
	_save(anim, "dead")


const SWL = {
	0:  {"parent": -1},
	3:  {"parent": 0},
	4:  {"parent": 3},
	5:  {"parent": 4},
	11: {"parent": 0},
	12: {"parent": 11},
	13: {"parent": 12},
	6:  {"parent": 0},
	7:  {"parent": 6},
	8:  {"parent": 7},
	1:  {"parent": 8},
	2:  {"parent": 1},
	14: {"parent": 8},
	15: {"parent": 14},
	9:  {"parent": 8},
	10: {"parent": 9},
}

func _bone_path(bone_id: int) -> String:
	var parts: PackedStringArray = ["bone_%d" % bone_id]
	var pid: int = SWL[bone_id]["parent"]
	while pid >= 0:
		parts.insert(0, "bone_%d" % pid)
		pid = SWL[pid]["parent"]
	return ".:%s" % "/".join(parts)


func _add_rot(anim: Animation, bone_id: int, keys: Array) -> void:
	if keys.size() < 2:
		return
	var path := "%s:rotation" % _bone_path(bone_id)
	var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track_idx, path)
	anim.track_set_interpolation_type(track_idx, 3)
	var i: int = 0
	while i + 1 < keys.size():
		anim.track_insert_key(track_idx, float(keys[i]), deg_to_rad(float(keys[i + 1])))
		i += 2
