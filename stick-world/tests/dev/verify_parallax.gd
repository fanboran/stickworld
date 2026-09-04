extends Node
## 视差功能验证（dev 层）——相机平移前后截两帧，断言各层产生不同速率的位移。
## 用法：godot --path . res://tests/dev/verify_parallax.tscn -- --out F:/tmp/para

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	var out_dir := "F:/tmp"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out_dir = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(2.0).timeout

	var sky: Node2D = null
	var m: Node2D = _game_root.get_current_map()
	if m != null:
		sky = m.get_node_or_null("SkyDecor")
	if sky == null:
		print("[FAIL] SkyDecor 未找到")
		get_tree().quit(1)
		return

	var cam: Camera2D = _game_root.get_node_or_null("CameraRig")
	if cam == null:
		print("[FAIL] CameraRig 未找到")
		get_tree().quit(1)
		return

	# 记录山层当前位置（factor 0.55）与云（0.55 漂移另有）
	var mountains: Sprite2D = null
	for c in sky.get_children():
		if c is Sprite2D and c.texture != null and c.texture.resource_path.contains("mountains"):
			mountains = c
			break
	if mountains == null:
		print("[FAIL] 山层未找到")
		get_tree().quit(1)
		return
	var mx0: float = mountains.position.x
	var cx0: float = cam.global_position.x

	# 相机大幅平移：传送玩家（CameraRig 跟随玩家，直接挪相机会被拉回）
	var m2: Node2D = _game_root.get_current_map()
	var ents: Array = m2.get_entities() if m2 != null and m2.has_method("get_entities") else []
	for e in ents:
		if e != null and is_instance_valid(e) and e.has_method("is_possessed") and e.is_possessed():
			e.global_position.x += 1200.0
			break
	await get_tree().create_timer(1.2).timeout
	var mx1: float = mountains.position.x
	var cx1: float = cam.global_position.x
	var moved: float = mx1 - mx0
	var cam_moved: float = cx1 - cx0
	var expect: float = cam_moved * (1.0 - 0.55)
	print("[PARALLAX] cam_moved=%.0f mountains_moved=%.0f expect=%.0f" % [cam_moved, moved, expect])
	if absf(moved - expect) < 30.0 and moved > 50.0:
		print("[OK] 视差生效（山层按 55%% 因子跟随）")
		get_tree().quit(0)
	else:
		print("[FAIL] 视差不符")
		get_tree().quit(1)
