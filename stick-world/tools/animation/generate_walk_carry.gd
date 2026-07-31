@tool
extends EditorScript
## 生成 walk_carry.tres：合并 walk.tres 的腿部/身躯轨道 + 搬运手部姿势。
##
## 运行方式：在 Godot 编辑器中「文件 > 运行」执行此脚本。
##
## 搬运手部姿势取自 stickman_test.tscn 的 walk_carry 草稿：
##   outhand = Vector2(55, 3), innerhand = Vector2(73, -17)
## 修改 walk.tres 后重新运行此脚本即可同步搬运动画（腿走+手搬）。

const WALK_PATH := "res://modules/units/animations/walk.tres"
const CARRY_PATH := "res://modules/units/animations/walk_carry.tres"

# 搬运手部姿势（单帧常量，双手抬到身前持物）
const CARRY_OUTHAND := Vector2(55, 3)
const CARRY_INNERHAND := Vector2(73, -17)


func _run() -> void:
	generate()


static func generate() -> void:
	var walk := load(WALK_PATH) as Animation
	if walk == null:
		push_error("[generate_walk_carry] 无法加载 walk.tres")
		return
	var carry := Animation.new()
	carry.loop_mode = Animation.LOOP_LINEAR
	carry.step = walk.step
	# 复制所有轨道：非手部原样复制，手部替换为搬运姿势单帧
	var track_count := walk.get_track_count()
	for i in track_count:
		var path: NodePath = walk.track_get_path(i)
		var path_str := str(path)
		if path_str == "../Node2D/outhand:position":
			_add_single_key_track(carry, path, CARRY_OUTHAND)
		elif path_str == "../Node2D/innerhand:position":
			_add_single_key_track(carry, path, CARRY_INNERHAND)
		else:
			carry.add_track(walk.track_get_type(i))
			var new_idx := carry.get_track_count() - 1
			carry.track_set_path(new_idx, path)
			carry.track_set_interpolation_type(new_idx, walk.track_get_interpolation_type(i))
			carry.track_set_loop_wrap(new_idx, true)
			var times: PackedFloat32Array = walk.track_get_key_times(i)
			var transitions: PackedFloat32Array = walk.track_get_key_transitions(i)
			var values: Array = walk.track_get_key_values(i)
			for k in times.size():
				carry.track_insert_key(new_idx, times[k], values[k], transitions[k])
	var err := ResourceSaver.save(carry, CARRY_PATH)
	if err == OK:
		print("[generate_walk_carry] 已生成 %s（%d 轨道）" % [CARRY_PATH, carry.get_track_count()])
	else:
		push_error("[generate_walk_carry] 保存失败: %d" % err)


static func _add_single_key_track(anim: Animation, path: NodePath, value: Variant) -> void:
	anim.add_track(Animation.TYPE_VALUE)
	var idx := anim.get_track_count() - 1
	anim.track_set_path(idx, path)
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR)
	anim.track_set_loop_wrap(idx, true)
	anim.track_insert_key(idx, 0.0, value, 1.0)
