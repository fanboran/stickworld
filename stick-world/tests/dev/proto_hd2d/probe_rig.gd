extends Node
## probe_rig.gd —— 量 StickmanRig 在 SubViewport 里的真实像素包围盒（一次性探针）
##
## 跑法：
##   godot --path stick-world res://tests/dev/proto_hd2d/probe_rig.tscn

const RIG_SCENE := "res://modules/units/scenes/stickman_test.tscn"

func _ready() -> void:
	for anim in ["idle", "walk"]:
		await _probe(anim)
	get_tree().quit(0)


func _probe(anim: String) -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(512, 512)
	sv.transparent_bg = true
	sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(sv)
	var inst: Node = load(RIG_SCENE).instantiate()
	inst.set_script(null)
	sv.add_child(inst)
	# 关键：**整棵实例根节点一起挪**。IK 目标 Marker2D 是 rig 的兄弟节点
	# （OutlineGroup/Node2D），原脚本每帧把它们的 transform 同步成 rig 的。
	# 只挪 rig（不挪兄弟）会让 IK 目标留在原点、肢体朝目标塌折成一个墨团；
	# 挪根节点则 OutlineGroup 里的 rig 与目标同步平移，IK 契约保持成立。
	(inst as Node2D).position = Vector2(256, 300)
	var rig: Node2D = inst.get_node("OutlineGroup/StickmanRig") as Node2D
	rig.scale = Vector2(1.0, 1.0)
	if not rig.has_method("play"):
		print("[probe] rig 无 play()")
	else:
		rig.play(anim)
	# 等几帧让动画/IK 稳定
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	var minx := 9999
	var miny := 9999
	var maxx := -1
	var maxy := -1
	var count := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.02:
				minx = mini(minx, x); miny = mini(miny, y)
				maxx = maxi(maxx, x); maxy = maxi(maxy, y)
				count += 1
	print("[probe] %-5s rig.pos=(256,300) scale=1  alpha bbox=(%d,%d)-(%d,%d)  w=%d h=%d px=%d" % [
		anim, minx, miny, maxx, maxy, maxx - minx + 1, maxy - miny + 1, count])
	var p := ProjectSettings.globalize_path("res://") + "temp/proto_hd2d/"
	img.save_png(p + "_probe_rig_%s.png" % anim)
	sv.queue_free()
