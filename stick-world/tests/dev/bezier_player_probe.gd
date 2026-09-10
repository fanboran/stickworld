extends SceneTree
## bezier track 二段验证：AnimationPlayer 播放时是否把 bezier 轨道实际 apply 到节点属性。
## 同时验证 LOOP_LINEAR 的 .tres 序列化字段（walk 类循环动画需要）。
## 用法：godot --headless --path stick-world --script res://tests/dev/bezier_player_probe.gd

const X1 := 0.339
const Y1 := 0.06
const X2 := 0.712
const Y2 := 0.48


func _cubic(a: float, b: float, c: float, d: float, u: float) -> float:
	var iu := 1.0 - u
	return iu * iu * iu * a + 3.0 * iu * iu * u * b + 3.0 * iu * u * u * c + u * u * u * d


func _spine_bezier(tn: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in 40:
		var mid := (lo + hi) * 0.5
		if _cubic(0.0, X1, X2, 1.0, mid) < tn:
			lo = mid
		else:
			hi = mid
	return _cubic(0.0, Y1, Y2, 1.0, (lo + hi) * 0.5)


func _initialize() -> void:
	var root_node := Node2D.new()
	root.name = "ProbeRoot"
	root.add_child(root_node)
	var hip := Node2D.new()
	hip.name = "hip"
	root_node.add_child(hip)

	var anim := Animation.new()
	anim.length = 1.0
	var track := anim.add_track(Animation.TYPE_BEZIER)
	anim.track_set_path(track, NodePath("hip:rotation"))
	var dv := 1.5707963
	anim.bezier_track_insert_key(track, 0.0, 0.0, Vector2.ZERO, Vector2(X1, Y1 * dv))
	anim.bezier_track_insert_key(track, 1.0, dv, Vector2(X2 - 1.0, (Y2 - 1.0) * dv), Vector2.ZERO)

	var lib := AnimationLibrary.new()
	lib.add_animation("probe", anim)
	var player := AnimationPlayer.new()
	root_node.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", lib)

	var max_err := 0.0
	for t in [0.1, 0.3, 0.5, 0.7, 0.9]:
		player.play("probe")
		player.seek(t, true)
		var got: float = hip.rotation
		var want: float = -dv * _spine_bezier(t)  # Godot rotation = -Spine 角
		max_err = maxf(max_err, absf(got - want))
		print("t=%.1f applied=%.7f want=%.7f err=%.9f" % [t, got, want, absf(got - want)])
	print("AnimationPlayer apply max_err=%.9f %s" % [max_err, "PASS" if max_err < 1e-4 else "FAIL"])

	# LOOP_LINEAR 序列化字段
	anim.loop_mode = Animation.LOOP_LINEAR
	var path := "res://.tmp_loop_probe.tres"
	ResourceSaver.save(anim, path)
	var f := FileAccess.open(path, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	print("=== loop tres 头 ===")
	for line in txt.split("\n"):
		if "loop" in line or "length" in line:
			print(line)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit(0)
