extends Node
## 守城战视觉快照（dev 层）——真渲染进 siege_battlefield，验证城墙/城门/硬地皮
## 泥土路衔接/弓箭手上墙/右端波次刷敌。
##
## 用法（不要 --headless，需要真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_siege.tscn -- --out F:/tmp/siege.png

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	var out := "res://tests/dev/snapshot_siege_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	# 等初始村加载完成
	await get_tree().create_timer(1.8).timeout
	var loader: Node = _game_root.get("scene_loader")
	if loader == null:
		push_error("[snapshot_siege] scene_loader 缺失")
		get_tree().quit(1)
		return
	loader.travel_to_map("siege_battlefield", WorldAPI.TravelMode.TELEPORT,
			WorldAPI.EntrySide.LEFT)
	# 等地图加载 + 布防 + 首波敌军（first_wave_delay=4s，战斗启动即全局自动暂停）
	await get_tree().create_timer(7.0).timeout
	TimeManager.resume()
	# 切白昼（守城战场默认白天观感）
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(10.0)
	await get_tree().create_timer(1.2).timeout
	# 传送到城墙前看城门+弓箭手+路带衔接
	var map: Node2D = _game_root.get_current_map()
	var player: Node2D = _find_player(map)
	if player != null:
		player.global_position = Vector2(4750.0, player.global_position.y)
		var cam_rig: Node = _game_root.get("camera_rig")
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()
	await get_tree().create_timer(0.8).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved: ", out)
	# 波次推进观察窗：覆盖第 2/3 波（wave_interval=22s），期间保持时间流速
	for i in 5:
		await get_tree().create_timer(9.0).timeout
		TimeManager.resume()
	var out2 := out.replace(".png", "_battle.png")
	var img2 := get_viewport().get_texture().get_image()
	img2.save_png(out2)
	print("[SNAPSHOT] saved: ", out2)
	var director: Node = _find_director()
	if director != null:
		print("[SNAPSHOT] 波数: ", director.get_wave_num())
	_diag(map)
	get_tree().quit(0)


func _diag(map: Node2D) -> void:
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return
	var n := 0
	for u in host.get_children():
		if not is_instance_valid(u):
			continue
		n += 1
		if n <= 14:
			print("[DIAG] unit ", u.get_class(), " pos=", u.global_position,
					" dead=", u.has_method("is_dead") and u.is_dead(),
					" wt=", u.get("weapon_mount") != null and u.weapon_mount.get("weapon_type"))
	print("[DIAG] 实体总数: ", n)
	var gr := get_tree().root.get_node_or_null("GameRoot")
	var api: Node = gr.get("_combat_api") if gr != null else null
	print("[DIAG] api=", api, " gr=", gr)
	if api != null and api.has_method("get_active_battles"):
		print("[DIAG] battles=", api.get_active_battles())
		for b in api.get_active_battles():
			print("[DIAG] battle=", b, " state=", b.get_state(), " units=", b.get_all_units().size(),
					" alive_a=", b.get_alive_count(1), " alive_d=", b.get_alive_count(2))


func _find_player(map: Node2D) -> Node2D:
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


func _find_director() -> Node:
	var map: Node2D = _game_root.get_current_map()
	return map.get_node_or_null("SiegeDirector") if map != null else null
