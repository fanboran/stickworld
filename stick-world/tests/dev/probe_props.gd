extends Node
## 摆件碰撞对位实测：dump 每个道具卡的视觉落点 z（卡底贴地深度）与碰撞带
## 中心 z（_prop_solids y_c 反解），差值×32 = 画布 px 偏移。

const GAME_ROOT_SCENE: PackedScene = preload("res://modules/world/scenes/game_root.tscn")

func _ready() -> void:
	var game_root: Node = GAME_ROOT_SCENE.instantiate()
	add_child(game_root)
	var map: Node2D = null
	for i in 900:
		await get_tree().process_frame
		if game_root.has_method("get_current_map") and game_root.get_current_map() != null:
			map = game_root.get_current_map()
			if map.has_method("get_entities") and map.get_entities().size() >= 2:
				break
	for i in 30:
		await get_tree().process_frame
	var hd: Node3D = map.get("_hd")
	var solids: Array = hd.get("_prop_solids")
	var root: Node3D = hd.get("_prop_root")
	print("[props] solids=", solids.size(), " nodes=", root.get_child_count())
	var tilt: float = deg_to_rad(26.0)
	var n: int = 0
	for mi: Node3D in root.get_children():
		if n >= 12:
			break
		var mesh := mi as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		var half: float = (mesh.mesh as QuadMesh).size.y * 0.5
		var visual_z: float = mi.position.z + sin(tilt) * half
		# 找同名碰撞带（Prop_x → solids 里 x 距离匹配的最近项）
		var best_d := 1e9
		var best_c_z := 0.0
		for s: Variant in solids:
			var c_x: float = (float(s[0]) + float(s[1])) * 0.5
			var d: float = absf(c_x - mesh.position.x)
			if d < best_d:
				best_d = d
				best_c_z = (float(s[2]) + float(s[3])) * 0.5 - 688.0
				best_c_z /= 32.0
		var best_x: float = 0.0
		for s2: Variant in solids:
			var c_x2: float = (float(s2[0]) + float(s2[1])) * 0.5
			if absf(c_x2 - mesh.position.x) < 1e6 and absf(c_x2 - mesh.position.x) <= best_d + 1e9:
				pass
		print("[props] %s visual_z=%.3f collide_z=%.3f delta_z=%.3f (%.1fpx) x=%.1f y_c_canvas=%.1f" % [
				mi.name, visual_z, best_c_z, best_c_z - visual_z, (best_c_z - visual_z) * 32.0,
				mesh.position.x, 688.0 + best_c_z * 32.0])
		n += 1
	get_tree().quit(0)
