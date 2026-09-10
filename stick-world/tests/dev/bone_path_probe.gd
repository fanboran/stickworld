extends SceneTree
## 临时探针：Skeleton2D/Bone2D 的动画轨道路径是否支持"扁平骨名"？
## 结论决定批次 B 的骨骼树构建方式（扁平 vs 嵌套）与导入器 track path 口径。
## 用完即删。

func _initialize() -> void:
	print("=== bone path probe ===")

	for mode in ["flat", "full"]:
		var rig := Node2D.new()
		rig.name = "Rig_" + mode
		get_root().add_child(rig)
		var sk := Skeleton2D.new()
		sk.name = "Skel"
		rig.add_child(sk)
		var b1 := Bone2D.new()
		b1.name = "parent_bone"
		sk.add_child(b1)
		var b2 := Bone2D.new()
		b2.name = "child_bone"
		b1.add_child(b2)

		var ap := AnimationPlayer.new()
		ap.name = "AP"
		sk.add_child(ap)

		var anim := Animation.new()
		anim.length = 1.0
		anim.add_track(Animation.TYPE_VALUE)
		var path_str := "child_bone:rotation" if mode == "flat" else "parent_bone/child_bone:rotation"
		anim.track_set_path(0, NodePath(path_str))
		anim.track_insert_key(0, 0.0, 0.0)
		anim.track_insert_key(0, 1.0, 1.0)
		var lib := AnimationLibrary.new()
		lib.add_animation("t", anim)
		ap.add_animation_library("", lib)
		ap.root_node = NodePath("..")
		ap.play("t")
		ap.seek(1.0, true)
		print("mode=%s path=%s -> child rotation=%.4f (expect 1.0 if resolved)" % [
			mode, path_str, b2.rotation])

	quit()
