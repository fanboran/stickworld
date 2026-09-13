extends Node
## probe_rig3.gd —— 诊断 2：判明"手臂 IK 目标落在脚附近"是不是把角色拽坏的原因
##
## 跑法：godot --path stick-world res://tests/dev/proto_hd2d/probe_rig3.tscn

const RIG_SCENE := "res://modules/units/scenes/stickman_test.tscn"

func _ready() -> void:
	await _variant("asis", Vector2(-20, 112), Vector2(24, 115), false)
	await _variant("natural", Vector2(-30, -46), Vector2(34, -50), false)
	await _variant("noarmik", Vector2.ZERO, Vector2.ZERO, true)
	get_tree().quit(0)


func _variant(tag: String, lh: Vector2, rh: Vector2, kill_arm_ik: bool) -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(320, 400)
	sv.transparent_bg = true
	sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var inst: Node = load(RIG_SCENE).instantiate()
	inst.set_script(null)
	sv.add_child(inst)
	(inst as Node2D).position = Vector2(150, 300)
	var rig: Node2D = inst.get_node("OutlineGroup/StickmanRig") as Node2D
	var markers: Node2D = inst.get_node("OutlineGroup/Node2D") as Node2D
	if kill_arm_ik:
		var stack: SkeletonModificationStack2D = rig.get_modification_stack()
		var dead: Array = []
		for i in range(stack.modification_count):
			var mod := stack.get_modification(i) as SkeletonModification2DTwoBoneIK
			if mod != null and str(mod.target_nodepath).ends_with("hand"):
				dead.append(i)
		for i in range(dead.size() - 1, -1, -1):
			stack.delete_modification(dead[i])
		print("[p3] %-8s 删除手部 IK 修改器 %d 条" % [tag, dead.size()])
	else:
		(markers.get_node("outhand") as Marker2D).position = lh
		(markers.get_node("innerhand") as Marker2D).position = rh
	rig.play("idle")
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	var minx := 9999
	var miny := 9999
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.02:
				minx = mini(minx, x)
				miny = mini(miny, y)
				maxx = maxi(maxx, x)
				maxy = maxi(maxy, y)
	var p := ProjectSettings.globalize_path("res://") + "temp/proto_hd2d/"
	var rx := maxi(minx - 8, 0)
	var ry := maxi(miny - 8, 0)
	var crop := img.get_region(Rect2i(rx, ry,
		mini(maxx - minx + 17, img.get_width() - rx),
		mini(maxy - miny + 17, img.get_height() - ry)))
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(p + "_probe3_%s.png" % tag)
	print("[p3] %-8s bbox=(%d,%d)-(%d,%d) w=%d h=%d  -> 相对原点 x[%d,%d] y[%d,%d]" % [
		tag, minx, miny, maxx, maxy, maxx - minx + 1, maxy - miny + 1,
		minx - 150, maxx - 150, miny - 300, maxy - 300])
	sv.queue_free()
