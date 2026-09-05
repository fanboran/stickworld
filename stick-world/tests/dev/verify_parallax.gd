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

	# 记录远山层当前位置（Terraria BackMountains：视差 0.15，modulo 回绕平铺）
	var mountains: Sprite2D = null
	for c in sky.get_children():
		if c is Sprite2D and c.texture != null and c.texture.resource_path.contains("mountain"):
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
	var expect: float = cam_moved * (1.0 - 0.15)
	# modulo 回绕平铺：位移与期望的差是 tile 宽的整数倍（层 sprite 相位在 [0,tile_w) 回绕）
	var tile_w: float = mountains.texture.get_width() * mountains.scale.x
	var drift: float = fmod(moved - expect, tile_w)
	drift = minf(absf(drift), absf(drift - tile_w))
	print("[PARALLAX] cam_moved=%.0f mountains_moved=%.0f expect=%.0f tile_w=%.0f drift=%.1f"
			% [cam_moved, moved, expect, tile_w, drift])
	if not (drift < 30.0 and absf(moved) > 50.0):
		print("[FAIL] 视差不符")
		get_tree().quit(1)
		return
	print("[OK] 视差生效（远山按 Terraria 0.15 视差 + modulo 回绕平铺）")

	# ── 天空生命感（星野/月亮/飞鸟/萤火虫）──
	var stars: Node = sky.get_node_or_null("Stars")
	var birds: Node = sky.get_node_or_null("Birds")
	var flies: Node = m.get_node_or_null("Fireflies")
	if stars == null or birds == null or flies == null:
		print("[FAIL] 星空/飞鸟/萤火虫层未挂载")
		get_tree().quit(1)
		return
	if stars.get_star_count() < 300:
		print("[FAIL] 星星数量不足: %d" % stars.get_star_count())
		get_tree().quit(1)
		return
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env == null:
		print("[FAIL] EnvironmentSystem 未找到")
		get_tree().quit(1)
		return
	# 夜晚 22:00 → 星野淡入（lerp 2/s，1.6s 后应 > 0.7）
	env.set_time_of_day(22.0)
	await get_tree().create_timer(1.6).timeout
	var night: float = stars.get_night_factor()
	print("[STARS] night_factor=%.2f" % night)
	if night < 0.7:
		print("[FAIL] 夜间星野未淡入")
		get_tree().quit(1)
		return
	var flies_night: float = flies.get_night_factor()
	print("[FIREFLIES] night_factor=%.2f" % flies_night)
	if flies_night < 0.7:
		print("[FAIL] 夜间萤火虫未淡入")
		get_tree().quit(1)
		return
	print("[OK] 夜空星野淡入（22:00）+ 萤火虫入野")
	# 正午 12:00 → 飞鸟群确定性生成
	env.set_time_of_day(12.0)
	await get_tree().create_timer(1.0).timeout
	birds.spawn_flock()
	var n_birds: int = birds.get_bird_count()
	print("[BIRDS] flock_size=%d" % n_birds)
	if n_birds < 3 or n_birds > 5:
		print("[FAIL] 飞鸟群数量异常")
		get_tree().quit(1)
		return
	print("[OK] 白昼飞鸟群生成（12:00）")
	# ── 天气雨链：强制降雨 → 强度 ramp + 云层加浓响应 ──
	var weather: Node = m.get_node_or_null("Weather")
	if weather == null:
		print("[FAIL] Weather 未挂载")
		get_tree().quit(1)
		return
	weather.force_rain(true)
	await get_tree().create_timer(2.2).timeout
	var rain_t: float = weather.get_rain_intensity()
	print("[RAIN] intensity=%.2f sky_rainy=%.2f" % [rain_t, sky.get_rainy()])
	if rain_t < 0.2 or sky.get_rainy() < 0.2:
		print("[FAIL] 降雨强度/云响应未达预期")
		get_tree().quit(1)
		return
	weather.force_rain(false)
	print("[OK] 降雨链路（强度 ramp + 云层加浓）")
	# 复原时间后收尾
	env.set_time_of_day(8.0)
	print("[PASS] 视差 + 天空生命感全部验证通过")
	get_tree().quit(0)
