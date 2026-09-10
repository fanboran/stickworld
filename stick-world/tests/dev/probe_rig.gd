extends Node
## dev 探针：打印单个火柴人各肢体容器的世界坐标与 fill 线段端点（骨架几何实测）。
## 运行： godot --headless --path stick-world res://tests/dev/probe_rig.tscn

const _GalleryScene: PackedScene = preload("res://tests/dev/unit_action_gallery.tscn")


func _ready() -> void:
	var gallery: Node = _GalleryScene.instantiate()
	add_child(gallery)
	for i in 90:
		await get_tree().process_frame
	# 找第一个单位（剑士）
	var entities: Array = []
	for e in gallery.get_children():
		if e.has_method("is_dead"):
			entities.append(e)
		for sub in e.get_children():
			if sub is Node2D and sub.has_method("is_dead"):
				entities.append(sub)
	if entities.is_empty():
		print("[probe] no entity")
		get_tree().quit(1)
		return
	var u: Node2D = entities[0]
	var rig: Node = u.get("rig")
	print("[probe] entity=", u.name, " body_scale=", u.get("body_scale"), " rig.scale=", rig.scale)
	var bones: Dictionary = rig.get("_bones") if "_bones" in rig else {}
	var sprites: Dictionary = rig.get("_sprites") if "_sprites" in rig else {}
	# 骨骼世界位置（批次 B：骨骼字典键 = Spine 骨名）
	for name in bones:
		var b: Node2D = bones[name]
		print("[bone] %-18s global=%v" % [str(name), b.global_position])
	# 肢体容器与 fill 端点
	for name in sprites:
		var c: Node2D = sprites[name]
		var fill: Node = c.get_node_or_null("fill")
		var stroke: Node = c.get_node_or_null("stroke")
		var info := "container global=%v rot=%.2f" % [c.global_position, c.rotation]
		if fill is Line2D:
			var ln := fill as Line2D
			info += " fill_line w=%.1f pts=%s" % [ln.width, str(ln.points)]
		elif fill is Polygon2D:
			info += " fill_poly bounds=%s" % str(_poly_bounds(fill as Polygon2D))
		if stroke != null and stroke.has_meta("open_root_half_len"):
			info += " [OPEN_ROOT half_len=%.1f]" % float(stroke.get_meta("open_root_half_len"))
		print("[limb] %s %s" % [str(name), info])
	get_tree().quit(0)


func _poly_bounds(p: Polygon2D) -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for v in p.polygon:
		mn = mn.min(v)
		mx = mx.max(v)
	return Rect2(mn, mx - mn)
