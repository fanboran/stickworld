extends Node
## 守城战视觉快照（dev 层）——真渲染全流程验证：
##   ① 村A城内：左右城墙门段+泥巴硬化地板+引路（出触发线弹头顶选项框）
##   ② 模拟点"开守城战"→过场→城郊战场：FIELD 巨墙+巡墙弓手+泥路+稀树+波次敌军
## 用法（不要 --headless）：
##   godot --path stick-world res://tests/dev/snapshot_siege.tscn -- --out F:/tmp/siege.png

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const SiegeFieldScript := preload("res://modules/world/scripts/map/siege_field.gd")

var _game_root: Node = null


func _ready() -> void:
	var out := "res://tests/dev/snapshot_siege_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(2.2).timeout
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(10.0)
	await get_tree().create_timer(1.0).timeout
	# ① 城内：传送到右墙前（引路尽头），看墙+选项框触发
	var map: Node2D = _game_root.get_current_map()
	var player: Node2D = _find_player(map)
	var cam_rig: Node = _game_root.get("camera_rig")
	if player != null:
		player.global_position = Vector2(1650.0, player.global_position.y)
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()
	await get_tree().create_timer(0.8).timeout
	var img0 := get_viewport().get_texture().get_image()
	img0.save_png(out.replace(".png", "_town.png"))
	print("[SNAPSHOT] saved town: ", out.replace(".png", "_town.png"))
	# ② 开守城战（模拟选项）→ 战场
	SiegeFieldScript.pending_siege_mode = true
	var loader: Node = _game_root.get("scene_loader")
	loader.travel_to_map("siege_battlefield", WorldAPI.TravelMode.TELEPORT,
			WorldAPI.EntrySide.LEFT)
	await get_tree().create_timer(3.5).timeout
	TimeManager.resume()
	# 等首波 + 巡墙跑起来
	await get_tree().create_timer(6.0).timeout
	TimeManager.resume()
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved field: ", out)
	# 波次推进一张
	for i in 3:
		await get_tree().create_timer(9.0).timeout
		TimeManager.resume()
	var out2 := out.replace(".png", "_battle.png")
	var img2 := get_viewport().get_texture().get_image()
	img2.save_png(out2)
	print("[SNAPSHOT] saved battle: ", out2)
	var fmap: Node2D = _game_root.get_current_map()
	var director: Node = fmap.get_node_or_null("SiegeDirector") if fmap != null else null
	if director != null:
		print("[SNAPSHOT] 波数: ", director.get_wave_num())
	_diag(fmap)
	get_tree().quit(0)


func _find_player(map: Node2D) -> Node2D:
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


func _diag(map: Node2D) -> void:
	if map == null:
		return
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return
	var n := 0
	for u in host.get_children():
		if not is_instance_valid(u):
			continue
		n += 1
		if n <= 16:
			print("[DIAG] unit pos=", u.global_position,
					" dead=", u.has_method("is_dead") and u.is_dead(),
					" atk=", u.has_meta("siege_attacker"))
	print("[DIAG] 实体总数: ", n)
	var gr := get_tree().root.get_node_or_null("GameRoot")
	var api: Node = gr.get("_combat_api") if gr != null else null
	if api != null and api.has_method("get_active_battles"):
		for b in api.get_active_battles():
			print("[DIAG] battle state=", b.get_state(), " units=", b.get_all_units().size(),
					" alive_a=", b.get_alive_count(1), " alive_d=", b.get_alive_count(2))
