extends Node
## 批次 D 排障探针：场景内（stickman_test.tscn）动画是否真正应用到骨骼。
## 在 relax 同款条件下 freeze 到 idle@t，dump 关键骨 global_rotation 与
## AnimationPlayer 状态，对照 Python 基准：
##   minerhead1: setup=-47.3° / Stand1@1.33=-22.2°
##   minerarm1:  setup=110.3° / Stand1@1.33=124.5°
##   minerleg2:  setup= 82.8° / Stand1@1.33= 63.6°
## 运行：godot --path stick-world res://tests/dev/diag_pose_probe.tscn

const _RigScene: PackedScene = preload("res://modules/units/scenes/stickman_test.tscn")
const _OverlayScript := preload("res://modules/units/scripts/rig/procedural_overlay.gd")

const DUMP_BONES: Array = ["minerhead1", "minerarm1", "minerarm3", "minerleg2", "pickaxe1"]


func _ready() -> void:
	_OverlayScript.ENABLED = false
	var rig_root: Node2D = _RigScene.instantiate()
	rig_root.set_script(null)
	rig_root.scale = Vector2(0.3468, 0.3468)
	rig_root.position = Vector2(960.0, 735.0)
	add_child(rig_root)
	var rig: Skeleton2D = rig_root.find_child("StickmanRig", true, false) as Skeleton2D
	var at: AnimationTree = rig.find_child("AnimationTree", true, false) as AnimationTree
	if at != null:
		at.active = false
	for f in 2:
		await get_tree().process_frame

	var ap := rig.find_child("AnimationPlayer", true, false) as AnimationPlayer
	print("has_animation(idle)=", ap.has_animation("idle"),
			"  anims=", ap.get_animation_list().size())
	print("track 数 idle=", ap.get_animation("idle").get_track_count())

	# 0) 初始姿态（未播任何动画）
	ap.stop()
	for f in 3:
		await get_tree().process_frame
	print("\n-- 未播动画（应≈setup 基准）--")
	_dump(rig)

	# 1) 播 idle 冻结 t=1.33
	ap.speed_scale = 0.0
	ap.play("idle")
	ap.seek(1.33, true)
	for f in 3:
		await get_tree().process_frame
	print("\n-- idle @1.33（Stand1 基准: head=-22.2 arm1=124.5 leg2=63.6）--")
	print("current=%s pos=%.3f" % [ap.current_animation, ap.current_animation_position])
	_dump(rig)

	# 2) seek(0)
	ap.seek(0.0, true)
	for f in 3:
		await get_tree().process_frame
	print("\n-- idle @0（Stand1 基准: head=-16.9 arm1=122.7 leg2=63.6）--")
	_dump(rig)

	get_tree().quit(0)


func _dump(rig: Skeleton2D) -> void:
	var bones: Dictionary = rig.get("_bones") if "_bones" in rig else {}
	for bn in DUMP_BONES:
		var b: Bone2D = bones.get(bn) as Bone2D
		if b == null:
			print("  %s 缺失" % bn)
			continue
		print("  %-12s grot=%8.2f°  gpos=(%8.2f, %8.2f)" % [
				bn, rad_to_deg(b.global_rotation), b.global_position.x, b.global_position.y])
