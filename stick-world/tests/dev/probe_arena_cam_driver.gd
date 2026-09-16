extends Node
## 探针：读 HD-2D 战场 3D 相机实况 + 反投影地平线（绿草地皮远端 z=0）到屏幕。
## 用于校准 set_cam_zoom 战场构图契约（地面占屏 2/3 的地平线落位）。

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"


func run() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)
	await _frames(420)   # 等开战（boot+切图+刷兵）
	var arena: Node = get_tree().current_scene
	var game_root: Node = arena.get("_game_root")
	var map: Node2D = game_root.get_current_map()
	var hd: Node = map.get("_hd")
	var cam: Camera3D = hd.get("_cam")
	print("[Probe] map=", map.scene_file_path, " hd=", hd.get_class())
	print("[Probe] cam.pos=", cam.position, " size=", cam.size,
			" proj=", cam.projection, " keep=", cam.keep_aspect)
	print("[Probe] cam.rot_deg=", cam.rotation_degrees)
	var vp: Vector2 = cam.get_viewport().get_visible_rect().size
	print("[Probe] viewport=", vp)
	# 反投影绿草地皮远端（z=0）/ 行走前界（z=24）/ 屏幕底沿候选点
	for z in [0.0, 8.0, 16.0, 24.0, 32.0, 48.0, 64.0, 80.0]:
		var sp: Vector2 = cam.unproject_position(Vector3(0.0, 0.0, z))
		print("[Probe] ground z=", z, " -> screen y=", sp.y)
	# 2D 侧行走带中点（观察场刷兵线）反投影参考
	print("[Probe] effective_zoom=", game_root.get("camera_rig").get_effective_zoom(),
			" user_zoom=", game_root.get("camera_rig").get_user_zoom())
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
