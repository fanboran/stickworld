extends Node
## 职业着装视觉快照（dev 层，不进 CI）——批次 1"职业可见"验收用。
##
## 用法（不要 --headless，真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_professions.tscn -- --out F:/tmp/professions.png
##
## 内容：村庄加载后，真实 NPC（initial_content 轮转分配：铁匠+伐木工）已在
## 仓库右侧站位；补 spawn 一个矿工（轮转 index=2）凑齐三职业，玩家传送至
## NPC 区中央，相机跟随截图。stdout 打印每个 NPC 的职业 id 与身体色作程序化证据。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	var out := "res://tests/dev/professions_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(3.0).timeout

	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[SNAPSHOT] 地图未加载")
		get_tree().quit(1)
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5

	# 补 spawn 一个矿工（轮转 index=2；真实 NPC_COUNT=2 只分到铁匠+伐木工），
	# 摆在两个真实 NPC（X=1050/1250）中间，凑齐三职业同框
	var miner: Node2D = map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(1150.0, spawn_y))
	if miner != null:
		miner.global_position.y = spawn_y - miner.foot_offset
		miner.set_possessed(false)
		TownLifeAPI.assign_village_job(miner, 2)

	# 玩家传送到 NPC 区右侧一点（镜头面向三人组），相机跟随
	var player: Node2D = _find_player(map)
	var cam_rig: Variant = _game_root.get("camera_rig")
	if player != null:
		player.global_position = Vector2(1300.0, spawn_y - player.foot_offset)
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()
	await get_tree().create_timer(1.0).timeout

	# 程序化证据：列出玩家附近单位的职业与着装
	_dump_nearby(Vector2(1250.0, spawn_y), 400.0)

	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved: ", out)
	get_tree().quit(0)


func _find_player(map: Node2D) -> Node2D:
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


func _dump_nearby(pos: Vector2, radius: float) -> void:
	var map: Node2D = _game_root.get_current_map()
	if map == null or not map.has_method("query_neighbors"):
		return
	for e in map.query_neighbors(pos, radius):
		if e == null or not is_instance_valid(e) or not e.has_method("get_profession"):
			continue
		print("[PROF] pos=%.0f profession='%s'" % [e.global_position.x, e.get_profession()])
