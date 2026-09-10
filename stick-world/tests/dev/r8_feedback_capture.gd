extends Node
## feedback1 创始人验收第一批修复截图（用完即删口径，暂存与 r8_label_capture 同款）：
##   1) L1 地形适配——标注新字号（14/11/11/10 下调后）+ 平滑河流/轮廓
##   2) L1 政治·三岔点放大——去抖动后城界共享边严丝合缝（端点共点、无双线）
##   3) L2 政治默认视角——L8→RGBA8 掉色修复（d3d12 真实后端）
##   4) L3 政治 fit/2x/4x 三档——多缩放档政权色全覆盖（对拍 35 国旧观感）
## 用法：godot --path . res://tests/dev/r8_feedback_capture.tscn（需真实渲染，不能 headless；
## 默认 forward_plus → Windows 下走 d3d12，正好实证 L8 采样异常已修）
## 产物：仓库根 tools/worldgen/output/feedback1_*.png

const OUT_DIR := "../tools/worldgen/output"
const SM_BASE := "res://config/strategic_map"
const WAIT_FRAMES := 600  # 异步解码等待上限（帧）

var _vp_size: Vector2


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	print("DRIVER ", RenderingServer.get_current_rendering_driver_name(),
			" adapter=", RenderingServer.get_video_adapter_name())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + OUT_DIR))
	await _shot_l1()
	await _shot_l2()
	await _shot_l3()
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	print("FEEDBACK1_CAPTURE_DONE")
	get_tree().quit()


func _make_camera(renderer: Node2D, zoom: float, center: Vector2) -> MapCamera:
	var cam := MapCamera.new()
	cam.drag_enabled = false
	cam.zoom_enabled = false
	add_child(cam)
	cam.target = renderer
	renderer.set_camera(cam)
	cam.set_zoom(zoom)
	# screen = offset + map × zoom → 地图点 center 摆到屏幕中心
	cam.set_offset(_vp_size * 0.5 - center * zoom)
	return cam


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "res://%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("SHOT ", shot_name, " ", img.get_size())


## 轮询条件满足或超时（条件 callable 返回 true 即通过）
func _wait_until(cond: Callable) -> void:
	for i in WAIT_FRAMES:
		if cond.call():
			return
		await get_tree().process_frame


func _teardown(nodes: Array) -> void:
	for n in nodes:
		n.queue_free()
	await get_tree().process_frame


## ── L1：l1_002 地形适配（新字号标注）+ 政治模式三岔点放大（严丝合缝）──
func _shot_l1() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	var data := L1WorldData.load_from(
		SM_BASE + "/l1_packs/l1_002/l1_world.json", SM_BASE + "/l1_packs/l1_002")
	var renderer := MapRenderer.new()
	add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)  # 占位，下面按 context 重算
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.TERRAIN)
	var ctx := float(maxi(data.context_size.y, data.size))
	var fit := _vp_size.y * 0.85 / ctx
	cam.set_zoom(fit)
	cam.set_offset(_vp_size * 0.5 - Vector2(ctx, ctx) * fit * 0.5)
	await _wait_until(func(): return renderer._mode_textures.size() > 0 and renderer._blob_ready)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l1_terrain_fit")
	# 政治（矢量政权色填充，无贴图干扰）→ 三岔点放大 zoom 3.0：城界 2px 屏幕宽，
	# 检查共享边单线、三岔端点共点无缝
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	for i in 4:
		await get_tree().process_frame
	var seam := _find_junction(data)
	var z := 3.0
	cam.set_zoom(z)
	cam.set_offset(_vp_size * 0.5 - seam * z)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l1_seam_zoom")
	await _teardown([renderer, cam])


## 找被最多地块共享的顶点（≥3 = 三岔交界）：0.25px 格量化计数
func _find_junction(data: L1WorldData) -> Vector2:
	var seen := {}
	var best := Vector2.INF
	var best_n := 0
	for tile in data.tiles:
		if tile.polygon.size() < 3:
			continue
		for p in tile.polygon:
			var k := "%d,%d" % [roundi(p.x * 4.0), roundi(p.y * 4.0)]
			var d: Dictionary = seen.get(k, {"n": 0, "p": p})
			d["n"] = int(d["n"]) + 1
			seen[k] = d
			if int(d["n"]) > best_n:
				best_n = int(d["n"])
				best = d["p"]
	print("JUNCTION n=", best_n, " at ", best)
	return best if best != Vector2.INF else Vector2.ZERO


## ── L2：region_001 政治默认视角（1.75 适配，控制器口径）──
func _shot_l2() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L2WorldData.load_from(
		SM_BASE + "/l2_packs/region_001/l2_world.json", SM_BASE + "/l2_packs/region_001")
	var renderer := L2MapRenderer.new()
	add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	var ctx := float(maxi(data.context_size.x, data.context_size.y))
	var fit := _vp_size.y * 0.72 / ctx
	cam.set_zoom(fit * 1.75)
	cam.set_offset(_vp_size * 0.5 - Vector2(ctx, ctx) * fit * 1.75 * 0.5)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l2_political")
	await _teardown([renderer, cam])


## ── L3：政治三连拍 fit / 2x / 4x（多缩放档政权色全覆盖验证）──
func _shot_l3() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L3WorldData.load_from(SM_BASE + "/l3_world.json", SM_BASE)
	var renderer := L3MapRenderer.new()
	add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	# 等政权 ID mask 后台解码 + RGBA8 归一 + 纹理就绪（67MB PNG，数秒）
	await _wait_until(func(): return renderer._political_layer != null)
	# 都城星标均值 ≈ 陆地中心（2x 取景用）；首星（4x 取景用）
	var stars: Array = renderer._label_layer._stars
	var mid := Vector2.ONE * float(data.size) * 0.5
	if not stars.is_empty():
		var acc := Vector2.ZERO
		for st in stars:
			acc += st["pos"]
		mid = acc / float(stars.size())
	var fit := (_vp_size.y - 128.0) / float(data.size)
	# 1) 整图适配（控制器 open() 口径：视口高 − 上下海洋边距）
	cam.set_zoom(fit)
	cam.set_offset(_vp_size * 0.5 - Vector2(data.size, data.size) * fit * 0.5)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l3_political_fit")
	# 2) 2x：陆地中心取景
	var z2 := fit * 2.0
	cam.set_zoom(z2)
	cam.set_offset(_vp_size * 0.5 - mid * z2)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l3_political_2x")
	# 3) 4x：首都取景（星标 + 国界实线 + 地区虚线同框）
	var z4 := fit * 4.0
	var c4: Vector2 = stars[0]["pos"] if not stars.is_empty() else mid
	cam.set_zoom(z4)
	cam.set_offset(_vp_size * 0.5 - c4 * z4)
	for i in 8:
		await get_tree().process_frame
	await _capture("feedback1_l3_political_4x")
	await _teardown([renderer, cam])
